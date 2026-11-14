import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r6_coach/analytics/breakdowns.dart';
import 'package:r6_coach/analytics/goals.dart';
import 'package:r6_coach/analytics/insights.dart';
import 'package:r6_coach/analytics/rp.dart';
import 'package:r6_coach/analytics/skills.dart';
import 'package:r6_coach/data/counters.dart';
import 'package:r6_coach/data/models.dart';
import 'package:r6_coach/data/snapshots.dart';

Map<String, dynamic> load(String n) => jsonDecode(File('test/fixtures/$n.json').readAsStringSync()) as Map<String, dynamic>;

Snapshot snap(DateTime at, {int w = 8, int l = 12, int rp = 2058, Map<String, Map<String, int>>? ops}) => Snapshot(
      at: at,
      modes: {'ranked': ModeCounts(wins: w, losses: l, kills: 46, deaths: 83, rp: rp)},
      ops: ops ?? {'Kapkan': {'r': 100, 'rw': 50, 'rl': 50, 'k': 60, 'd': 70, 'a': 10, 'hs': 20, 'fb': 8, 'fd': 14, 'c': 1, 'cl': 5, 'k2': 6, 'k3': 1, 'k4': 0, 'k5': 0, 'tk': 0, 'm': 20, 'mw': 9, 'ms': 0, 'att': 0}},
    );

void main() {
  final profile = PlayerProfile.fromJson(load('profile'));
  final ops = OperatorStat.listFromResponse(load('operators'));
  final game = GameOperator.listFromResponse(jsonDecode(File('assets/game_operators.json').readAsStringSync()));

  group('snapshots', () {
    final t0 = DateTime(2026, 10, 30, 18);
    Map<String, Map<String, int>> played(Map<String, int> add) {
      final base = snap(t0).ops['Kapkan']!;
      return {'Kapkan': {for (final e in base.entries) e.key: e.value + (add[e.key] ?? 0)}};
    }

    test('one ranked win becomes an exact match with its own numbers', () {
      final cur = snap(t0.add(const Duration(hours: 1)), w: 9, rp: 2103, ops: played({'r': 7, 'rw': 4, 'rl': 3, 'k': 5, 'd': 4, 'hs': 2, 'fb': 1, 'fd': 1, 'm': 1, 'mw': 1}));
      final r = diffSnapshots(snap(t0), cur)!;
      expect(r.exact, isTrue);
      expect(r.won, isTrue);
      expect(r.mode, 'ranked');
      expect(r.rpDelta, 45);
      expect(r.kills, 5);
      expect(r.deaths, 4);
      expect(r.rounds, 7);
      expect(r.ops.single.name, 'Kapkan');
      expect(r.score.score, isNotNull);
    });

    test('two matches between refreshes are merged and flagged as not exact', () {
      final cur = snap(t0.add(const Duration(hours: 3)), w: 9, l: 13, rp: 2060, ops: played({'r': 14, 'k': 8, 'd': 9}));
      final r = diffSnapshots(snap(t0), cur)!;
      expect(r.exact, isFalse);
      expect(r.won, isNull);
      expect(r.matches, 2);
      expect(r.wins, 1);
      expect(r.losses, 1);
    });

    test('nothing played, or a counter that went backwards, gives no record', () {
      expect(diffSnapshots(snap(t0), snap(t0.add(const Duration(hours: 1)))), isNull);
      final reset = snap(t0.add(const Duration(hours: 1)), ops: played({'r': -50}));
      expect(diffSnapshots(snap(t0), reset), isNull);
    });

    test('snapshots survive a JSON round trip and detect equal counters', () {
      final s = Snapshot.from(profile, ops, at: t0);
      final back = Snapshot.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.sameCounters(s), isTrue);
      expect(back.modes['ranked']!.rp, 2058);
      expect(back.totalRounds, s.totalRounds);
    });

    test('match log is newest first', () {
      final a = snap(t0), b = snap(t0.add(const Duration(hours: 1)), w: 9, ops: played({'r': 5, 'k': 2, 'd': 3}));
      final c = snap(t0.add(const Duration(hours: 2)), w: 9, l: 13, ops: played({'r': 11, 'k': 5, 'd': 7}));
      final log = buildMatchLog([a, b, c]);
      expect(log.length, 2);
      expect(log.first.at.isAfter(log.last.at), isTrue);
    });
  });

  group('rp', () {
    test('real history gives consistent wins, losses and break-even', () {
      final rp = RpAnalysis.from(profile.rpHistory);
      expect(rp.games, greaterThan(5));
      expect(rp.wins + rp.losses, rp.deltas.length);
      expect(rp.avgWin, greaterThan(0));
      expect(rp.avgLoss, greaterThan(0));
      expect(rp.breakEvenWinRate, inExclusiveRange(0, 1));
      expect(rp.net, rp.deltas.fold<int>(0, (s, d) => s + d.delta));
    });

    test('empty history is safe', () {
      final rp = RpAnalysis.from(const []);
      expect(rp.hasData, isFalse);
      expect(rp.winRate, isNull);
    });
  });

  group('skills and breakdowns', () {
    test('seven axes, entry rated from real duels', () {
      final a = skillProfile(ops);
      expect(a.length, 7);
      expect(a.firstWhere((x) => x.id == 'entry').score, isNotNull);
    });

    test('tiny samples leave axes unrated instead of guessing', () {
      final a = skillProfile(const [OperatorStat(name: 'X', side: 'Attacker', roundsPlayed: 10, kills: 5, deaths: 5)]);
      expect(a.every((x) => x.score == null), isTrue);
    });

    test('roles resolve through game data and mixed spellings', () {
      expect(normalizeRole('CROWD CONTROL'), 'Crowd Control');
      expect(normalizeRole('Front line'), 'Front Line');
      final roles = roleTotals(ops, game);
      expect(roles, isNotEmpty);
      expect(roles.every((r) => r.rounds > 0), isTrue);
    });

    test('operator icons use the reachable host', () {
      expect(game.every((g) => g.iconUrl == null || !g.iconUrl!.contains('r6data.eu')), isTrue);
    });

    test('mode rows come from real boards', () {
      final rows = modeRows(profile);
      expect(rows.map((r) => r.id), containsAll(['ranked', 'standard']));
    });

    test('insights use rp, game and profile and stay sorted warn-first', () {
      final items = buildInsights(ops, game: game, rp: RpAnalysis.from(profile.rpHistory), profile: profile);
      expect(items.length, greaterThan(2));
      final firstGood = items.indexWhere((i) => i.tone == Tone.good);
      final lastWarn = items.lastIndexWhere((i) => i.tone == Tone.warn);
      if (firstGood >= 0 && lastWarn >= 0) expect(lastWarn, lessThan(firstGood));
    });
  });

  group('goals', () {
    final t0 = DateTime(2026, 10, 30, 18);
    Snapshot at(int h, int rounds, int fb, int fd) => snap(t0.add(Duration(hours: h)), ops: {
          'Kapkan': {'r': rounds, 'rw': 0, 'rl': 0, 'k': 0, 'd': 0, 'a': 0, 'hs': 0, 'fb': fb, 'fd': fd, 'c': 0, 'cl': 0, 'k2': 0, 'k3': 0, 'k4': 0, 'k5': 0, 'tk': 0, 'm': 0, 'mw': 0, 'ms': 0, 'att': 0}
        });

    test('progress is measured only on rounds after the start', () {
      final goal = Goal(metric: GoalMetric.opening, baseline: 0.3, target: 0.4, startedAt: t0);
      final p = progressFor(goal, [at(0, 100, 30, 70), at(2, 160, 60, 100)]);
      expect(p.rounds, 60);
      expect(p.value, closeTo(30 / 60, 1e-9)); // 30 wins of 60 new duels
    });

    test('too few rounds gives no value', () {
      final goal = Goal(metric: GoalMetric.opening, baseline: 0.3, target: 0.4, startedAt: t0);
      expect(progressFor(goal, [at(0, 100, 30, 70), at(1, 110, 35, 75)]).ready, isFalse);
    });

    test('goal JSON round trip', () {
      final g = Goal(metric: GoalMetric.kd, baseline: 0.55, target: 0.7, startedAt: t0);
      final back = Goal.fromJson(jsonDecode(jsonEncode(g.toJson())) as Map<String, dynamic>);
      expect(back.metric, GoalMetric.kd);
      expect(back.target, 0.7);
    });
  });

  group('counters', () {
    final book = CounterBook.parse(File('assets/counters.json').readAsStringSync());

    test('names with diacritics normalize', () {
      expect(opId('Jäger'), 'jager');
      expect(opId('Nøkk'), 'nokk');
      expect(opId('Capitão'), 'capitao');
    });

    test('known relationship is present from both sides', () {
      expect(book.all.length, greaterThan(250));
      expect(book.beats('Ash').any((c) => c.to == 'castle' && c.level == 'hard'), isTrue);
      expect(book.beatenBy('Castle').any((c) => c.from == 'ash'), isTrue);
      expect(book.beats('Ash').first.weight, greaterThanOrEqualTo(book.beats('Ash').last.weight));
    });
  });
}
