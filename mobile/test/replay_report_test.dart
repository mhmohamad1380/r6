import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r6_coach/analytics/insights.dart' show Tone;
import 'package:r6_coach/analytics/replay_report.dart';
import 'package:r6_coach/analytics/replay_stats.dart';
import 'package:r6_coach/data/replay.dart';

import 'support/synthetic_replays.dart';

ReplayReport report(List<ReplayRound> r, {String me = 'A'}) => buildReplayReport(r, me);
ReplaySummary sum(List<ReplayRound> r) => summarize([for (final x in r) analyzeRound(x, 'A')]);

void main() {
  group('clutches and timing of one round', () {
    // B, C, D, E die, then A is alone against three: F, G and H survive until A wins.
    final clutch = rd('c', 1, won: true, kills: const [
      K('F', 'B', 170),
      K('G', 'C', 160),
      K('H', 'D', 150),
      K('F', 'E', 140),
      K('A', 'F', 100),
      K('A', 'G', 80),
      K('A', 'H', 60),
      K('A', 'I', 40),
    ]);

    test('A becomes the last one alive against four, and wins', () {
      final x = extraFor(analyzeRound(clutch, 'A'));
      // After E dies only F, G, H, I, J are left, so it is a 1v5.
      expect(x.clutchVs, 5);
      expect(x.clutchWon, isTrue);
    });

    test('a teammate who dies is never in a clutch', () {
      expect(extraFor(analyzeRound(clutch, 'B')).clutch, isFalse);
    });

    test('a lost clutch is recorded as an attempt but not a win', () {
      final lost = rd('c', 2, won: false, kills: const [K('F', 'B', 170), K('G', 'C', 160), K('H', 'D', 150), K('F', 'E', 140), K('A', 'F', 100), K('G', 'A', 60)]);
      final x = extraFor(analyzeRound(lost, 'A'));
      expect(x.clutch, isTrue);
      expect(x.clutchWon, isFalse);
    });

    test('first kill and death are measured from the start of the clock', () {
      final x = extraFor(analyzeRound(rd('t', 1, won: false, kills: const [K('A', 'F', 150), K('G', 'A', 120)]), 'A'));
      expect(x.firstKillAt, 30);
      expect(x.deathAt, 60);
    });

    test('a team kill is not a first kill', () {
      final x = extraFor(analyzeRound(rd('t', 1, won: true, kills: const [K('A', 'B', 150), K('A', 'F', 100)]), 'A'));
      expect(x.firstKillAt, 80);
    });

    test('untimed rounds give no times', () {
      final x = extraFor(analyzeRound(rd('t', 1, won: true, kills: const [K('A', 'F', null)]), 'A'));
      expect(x.firstKillAt, isNull);
    });

    test('wasted death: died with nothing and nobody avenged', () {
      expect(extraFor(analyzeRound(badRound('w', 1), 'A')).wastedDeath, isTrue);
      expect(extraFor(analyzeRound(goodRound('w', 1), 'A')).wastedDeath, isFalse);
    });
  });

  group('replay score', () {
    test('needs at least 3 rounds', () {
      final s = scoreReplays(sum(series(1, 2, (_) => true)));
      expect(s.score, isNull);
      expect(s.label, 'Not enough data');
    });

    test('a strong run scores above a weak run, and both stay within 0-100', () {
      final good = scoreReplays(sum(series(2, 5, (_) => true))).score!;
      final bad = scoreReplays(sum(series(2, 5, (_) => false))).score!;
      expect(good, greaterThan(bad + 30));
      expect(good, lessThanOrEqualTo(100));
      expect(bad, greaterThanOrEqualTo(0));
    });

    test('parts without enough data are left out and the rest are renormalised', () {
      final all = series(1, 4, (_) => true); // A never dies, so there are no deaths for teamplay
      final s = scoreReplays(sum(all));
      expect(s.components['teamplay'], isNull);
      expect(s.score, isNotNull);
      expect(s.notes.join(' '), contains('Teamplay'));
    });

    test('each team kill costs 3 points, up to 10', () {
      final base = sum(series(2, 5, (_) => true));
      final a = scoreReplays(base).score!;
      expect(a - scoreReplays(base, teamKills: 1).score!, closeTo(3, 0.11));
      expect(a - scoreReplays(base, teamKills: 9).score!, closeTo(10, 0.11));
    });

    test('confidence rises with rounds', () {
      expect(scoreReplays(sum(series(1, 4, (_) => true))).confidence, 'low');
      expect(scoreReplays(sum(series(3, 6, (_) => true))).confidence, isNot('low'));
    });

    test('without kill times the notes say KOST is a minimum', () {
      final untimed = [for (var n = 1; n <= 6; n++) rd('u', n, won: true, kills: const [K('A', 'F', null), K('B', 'G', null)])];
      expect(scoreReplays(sum(untimed)).notes.join(' '), contains('minimum'));
    });
  });

  group('improvement', () {
    test('under 4 matches says how many more are needed', () {
      final i = improvement(series(2, 5, (_) => true), 'A');
      expect(i.trend, Trend.unknown);
      expect(i.matchesNeeded, 2);
      expect(i.series, hasLength(2));
    });

    test('newer matches better than older ones is improving, in oldest-first order', () {
      final i = improvement(series(6, 5, (m) => m >= 3), 'A');
      expect(i.matchesNeeded, 0);
      expect(i.trend, Trend.improving);
      expect(i.delta!, greaterThan(20));
      expect(i.series.first.score!, lessThan(i.series.last.score!));
      expect(i.better.map((m) => m.label), contains('KOST'));
      expect(i.worse, isEmpty);
    });

    test('the reverse is slipping', () {
      final i = improvement(series(6, 5, (m) => m < 3), 'A');
      expect(i.trend, Trend.slipping);
      expect(i.delta!, lessThan(-20));
      expect(i.worse, isNotEmpty);
    });

    test('equal halves are steady', () {
      final i = improvement(series(6, 5, (_) => true), 'A');
      expect(i.trend, Trend.steady);
      expect(i.delta!.abs(), lessThan(3));
    });

    test('too few rounds in a half makes no call', () {
      final i = improvement(series(4, 3, (m) => m >= 2), 'A'); // 6 rounds per half
      expect(i.matchesNeeded, 0);
      expect(i.trend, Trend.unknown);
    });

    test('matches the player barely played are ignored', () {
      final extra = [for (var n = 1; n <= 2; n++) goodRound('short', n, day: 20)];
      expect(matchSeries([...series(4, 5, (_) => true), ...extra], 'A'), hasLength(4));
    });
  });

  group('breakdowns', () {
    test('sides split rounds by attack and defense', () {
      final r = report(series(2, 6, (_) => true));
      expect(r.sides.map((s) => s.attack), [true, false]);
      expect(r.sides.every((s) => s.rounds == 6), isTrue);
      expect(r.sides.first.winRate, 1.0);
    });

    test('a side with no rounds is omitted', () {
      expect(report([goodRound('x', 1)]).sides.map((s) => s.attack), [false]);
    });

    test('opening impact counts the team result by how the first fight went', () {
      final r = report(series(2, 5, (m) => m == 0));
      expect(r.opening.killRounds, 5);
      expect(r.opening.afterKill, 1.0);
      expect(r.opening.deathRounds, 5);
      expect(r.opening.afterDeath, 0.0);
      expect(r.opening.noneRounds, 0);
    });

    test('multi-kills count rounds by kill number', () {
      final r = report(series(1, 4, (_) => true)); // A has 2 kills each round
      expect(r.multikills, {2: 4});
    });

    test('operator lines group by the operator played', () {
      final rounds = [...series(1, 4, (_) => true, op: 'Ash'), ...series(1, 3, (_) => false, op: 'Zero').map((x) => x)];
      final ops = report(rounds).operators;
      expect(ops.map((o) => o.operator).toSet(), {'Ash', 'Zero'});
      expect(ops.first.rounds, 4, reason: 'most played first');
    });

    test('maps group rounds and win rate', () {
      final r = report([...series(1, 4, (_) => true, map: 'Bank'), ...series(1, 2, (_) => false, map: 'Villa').map((x) => x)]);
      expect(r.maps.map((m) => m.map).toList(), ['Bank', 'Villa']);
      expect(r.maps.first.winRate, 1.0);
    });

    test('timing needs 5 timed rounds and buckets by the round clock', () {
      expect(report(series(1, 4, (_) => true)).timing, isNull);
      final t = report(series(2, 5, (_) => true)).timing!;
      // A kills at 170 (10 s in) and 150 (30 s in) every round.
      expect(t.kills, [10, 10, 0, 0, 0, 0]);
      expect(t.timedRounds, 10);
      expect(t.medianFirstKill, 10);
    });

    test('timing ignores rounds without real kill times', () {
      final untimed = [for (var n = 1; n <= 8; n++) rd('u', n, won: true, kills: const [K('A', 'F', null)])];
      expect(report(untimed).timing, isNull);
    });

    test('deaths land in the right bucket and team kills are not counted as kills', () {
      final rounds = [for (var n = 1; n <= 5; n++) rd('d', n, won: false, kills: const [K('A', 'B', 175), K('G', 'A', 25)])];
      final t = report(rounds).timing!;
      expect(t.kills.fold(0, (a, b) => a + b), 0, reason: 'a team kill is not a kill');
      expect(t.deaths[5], 5, reason: '25 s left falls in the last slice');
    });
  });

  group('findings', () {
    ReplayFinding? find(ReplayReport r, String id) => r.findings.where((f) => f.id == id).firstOrNull;

    test('nothing is said about fewer than 6 rounds', () {
      expect(report(series(1, 5, (_) => false)).findings, isEmpty);
    });

    test('losing every first fight is called out with its sample size', () {
      final f = find(report(series(2, 5, (_) => false)), 'opening-low')!;
      expect(f.tone, Tone.warn);
      expect(f.sample, 10);
      expect(f.evidence, contains('0 of 10'));
      expect(f.drill, isNotNull);
    });

    test('winning every first fight is praised, not warned about', () {
      final r = report(series(2, 5, (_) => true));
      expect(find(r, 'opening-high')!.tone, Tone.good);
      expect(find(r, 'opening-low'), isNull);
    });

    test('under 6 first fights gives no opening finding', () {
      expect(find(report(series(1, 5, (_) => false)), 'opening-low'), isNull);
    });

    test('deaths that gave nothing are counted', () {
      final f = find(report(series(2, 5, (_) => false)), 'wasted-deaths')!;
      expect(f.evidence, contains('10 of 10'));
    });

    test('the opening swing needs both kinds of rounds', () {
      expect(find(report(series(2, 5, (m) => m == 0)), 'opening-swing'), isNotNull);
      expect(find(report(series(2, 5, (_) => true)), 'opening-swing'), isNull);
    });

    test('improvement shows up as a finding', () {
      expect(find(report(series(6, 5, (m) => m >= 3)), 'trend')!.tone, Tone.good);
      expect(find(report(series(6, 5, (m) => m < 3)), 'trend')!.tone, Tone.warn);
    });

    test('team kills are reported', () {
      final rounds = [for (var n = 1; n <= 6; n++) rd('tk', n, won: true, kills: const [K('A', 'B', 150), K('A', 'F', 100)])];
      final r = report(rounds);
      expect(r.teamKills, 6);
      expect(find(r, 'team-kills'), isNotNull);
    });

    test('warnings come first and there are at most 8', () {
      final r = report(richSet());
      expect(r.findings.length, lessThanOrEqualTo(8));
      final firstNonWarn = r.findings.indexWhere((f) => f.tone != Tone.warn);
      if (firstNonWarn >= 0) expect(r.findings.skip(firstNonWarn).every((f) => f.tone != Tone.warn), isTrue);
    });

    test('every finding has text and a positive sample', () {
      for (final f in report(richSet()).findings) {
        expect(f.title, isNotEmpty);
        expect(f.evidence, isNotEmpty);
        expect(f.action, isNotEmpty);
        expect(f.sample, greaterThan(0), reason: f.id);
      }
    });
  });

  group('real r6-dissect rounds', () {
    final rounds = [
      for (final n in ['ranked_1', 'ranked_2', 'quick_1', 'custom_1', 'attacker_recorder_site_test', 'defender_recorder_site_test_1']) ...parseReplayJson(File('test/fixtures/replays/$n.rec.json').readAsStringSync()).rounds,
    ];

    test('every player in every round gets a consistent report', () {
      final names = {for (final r in rounds) for (final p in r.players) p.name};
      expect(names, isNotEmpty);
      for (final n in names) {
        final r = buildReplayReport(rounds, n);
        final s = r.summary;
        if (s.rounds >= 3) {
          expect(r.score.score, inInclusiveRange(0, 100), reason: n);
        }
        expect(r.clutch.wins, lessThanOrEqualTo(r.clutch.attempts), reason: n);
        expect(r.extras.length, s.rounds, reason: n);
        final t = r.timing;
        if (t != null) expect(t.totalKills, lessThanOrEqualTo(s.kills), reason: n);
        for (final f in r.findings) {
          expect(f.sample, greaterThan(0), reason: '$n ${f.id}');
        }
      }
    });

    test('a name that is not in the replays gives an empty report, not an error', () {
      final r = buildReplayReport(rounds, 'nobody-here');
      expect(r.hasRounds, isFalse);
      expect(r.score.score, isNull);
      expect(r.findings, isEmpty);
      expect(r.sides, isEmpty);
    });

    test('rounds survive a save and reload unchanged, so the report is the same', () {
      final again = [for (final r in rounds) ReplayRound.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>)];
      final n = rounds.first.players.first.name;
      expect(buildReplayReport(again, n).score.score, buildReplayReport(rounds, n).score.score);
    });
  });
}
