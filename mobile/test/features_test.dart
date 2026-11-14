import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:r6_coach/analytics/insights.dart';
import 'package:r6_coach/analytics/picks.dart';
import 'package:r6_coach/analytics/rank_progress.dart';
import 'package:r6_coach/analytics/rp.dart';
import 'package:r6_coach/analytics/sessions.dart';
import 'package:r6_coach/analytics/summary.dart';
import 'package:r6_coach/app_state.dart';
import 'package:r6_coach/data/counters.dart';
import 'package:r6_coach/data/models.dart';
import 'package:r6_coach/data/ranks.dart';
import 'package:r6_coach/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> load(String n) => jsonDecode(File('test/fixtures/$n.json').readAsStringSync()) as Map<String, dynamic>;
String raw(String n) => File('test/fixtures/$n.json').readAsStringSync();

void main() {
  final ladder = RankLadder.parse(File('assets/ranks.json').readAsStringSync());
  final profile = PlayerProfile.fromJson(load('profile'));
  final ops = OperatorStat.listFromResponse(load('operators'));
  final game = GameOperator.listFromResponse(jsonDecode(File('assets/game_operators.json').readAsStringSync()));
  final rp = RpAnalysis.from(profile.rpHistory);

  group('rank ladder and progress', () {
    test('bands are contiguous and match the real account', () {
      expect(ladder.bands.length, 42);
      for (var i = 1; i < ladder.bands.length; i++) {
        expect(ladder.bands[i].min, ladder.bands[i - 1].max + 1, reason: ladder.bands[i].name);
      }
      expect(ladder.bandFor(2058)!.name, 'Silver 5'); // matches the API's own label for this player
      expect(ladder.bandFor(1999)!.name, 'Bronze 1');
      expect(ladder.bandFor(7000)!.name, 'Legend Division');
      expect(ladder.bandFor(7000)!.isTop, isTrue);
    });

    test('progress inside a division', () {
      final p = rankProgress(2058, ladder, rp)!;
      expect(p.band.name, 'Silver 5');
      expect(p.toNext, 42);
      expect(p.toDrop, 58);
      expect(p.nextName, 'Silver 4');
      expect(p.fraction, closeTo(0.58, 1e-9));
    });

    test('games estimate only appears with a real sample and a real trend', () {
      expect(rankProgress(2058, ladder, RpAnalysis.from(const [])) !.expectedPerGame, isNull);
      final p = rankProgress(2058, ladder, rp)!;
      if (p.expectedPerGame != null && p.expectedPerGame! > 1) {
        expect(p.gamesToNext, greaterThan(0));
      }
      expect(rankProgress(null, ladder, rp), isNull);
      expect(rankProgress(2058, RankLadder.empty, rp), isNull);
    });

    test('top rank has nothing to climb', () {
      final p = rankProgress(5200, ladder, rp)!;
      expect(p.toNext, isNull);
      expect(p.fraction, 1.0);
    });
  });

  group('sessions', () {
    RpDelta g(DateTime t, int d) => RpDelta(t, d, 2000, 'Silver 5');
    final t0 = DateTime(2026, 10, 30, 12);

    test('a long break splits sessions, newest first', () {
      final newestFirst = [
        g(t0.add(const Duration(hours: 6)), -30),
        g(t0.add(const Duration(hours: 5, minutes: 30)), 45),
        g(t0.add(const Duration(hours: 1)), 40),
        g(t0, -25),
      ];
      final s = sessionsFromRp(newestFirst);
      expect(s.length, 2);
      expect(s.first.games.length, 2);
      expect(s.first.start.isAfter(s.last.start), isTrue);
      expect(s.last.net, 15);
    });

    test('fatigue note needs a long session and a clear drop', () {
      final tired = [for (var i = 0; i < 8; i++) g(t0.add(Duration(minutes: i * 30)), i < 4 ? 40 : -35)];
      final s = sessionsFromRp(tired.reversed.toList()).single;
      expect(s.halves, isNotNull);
      expect(s.note, contains('first half'));
      expect(s.note, contains('second'));
      final short = sessionsFromRp([g(t0, 30), g(t0.subtract(const Duration(minutes: 20)), -20)]).single;
      expect(short.note, isNull);
    });

    test('real RP history forms at least one session', () {
      final s = sessionsFromRp(rp.deltas);
      expect(s, isNotEmpty);
      expect(s.fold<int>(0, (a, x) => a + x.games.length), rp.deltas.length);
    });
  });

  group('operator picks', () {
    test('small lucky samples cannot beat long records', () {
      const lucky = OperatorStat(name: 'Lucky', side: 'Attacker', roundsPlayed: 12, roundsWon: 12);
      const solid = OperatorStat(name: 'Solid', side: 'Attacker', roundsPlayed: 200, roundsWon: 130);
      const mid = OperatorStat(name: 'Mid', side: 'Attacker', roundsPlayed: 100, roundsWon: 50);
      final picks = operatorPicks([lucky, solid, mid], attacker: true);
      expect(picks.map((p) => p.op.name), ['Solid', 'Mid']); // Lucky is under the 40-round minimum
      final loose = operatorPicks([lucky, solid, mid], attacker: true, minRounds: 5);
      final l = loose.firstWhere((p) => p.op.name == 'Lucky');
      expect(l.winRate, 1.0);
      expect(l.score, lessThan(0.8)); // pulled well below its raw 100%
    });

    test('sides are separated and empty input is safe', () {
      expect(operatorPicks(const [], attacker: true), isEmpty);
      final p = operatorPicks(ops, attacker: false);
      expect(p.every((x) => !x.op.isAttacker), isTrue);
    });
  });

  group('role-aware insight and summary', () {
    test('a passive pool softens the opening-duel warning', () {
      final passive = [
        const OperatorStat(name: 'Kapkan', side: 'Defender', roundsPlayed: 300, roundsWon: 150, kills: 150, deaths: 250, firstBloods: 10, firstDeaths: 30, headshots: 60),
      ];
      final item = buildInsights(passive, game: game).firstWhere((i) => i.id == 'opening');
      expect(item.tone, Tone.info);
      expect(item.evidence, contains('entry-style'));
    });

    test('without game data the original warning stays', () {
      final plain = [const OperatorStat(name: 'Kapkan', side: 'Defender', roundsPlayed: 300, roundsWon: 150, kills: 150, deaths: 250, firstBloods: 10, firstDeaths: 30)];
      expect(buildInsights(plain).firstWhere((i) => i.id == 'opening').tone, Tone.warn);
    });

    test('summary is short, plain text and has no key', () {
      final t = buildSummary(profile, ops, rp, game: game);
      expect(t, contains('cyruson1001'));
      expect(t, contains('Silver 5'));
      expect(t.split('\n').length, lessThan(9));
      expect(t.toLowerCase(), isNot(contains('api')));
    });
  });

  testWidgets('compare costs exactly 2 calls and shows both players', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'apiKey': 'k', 'username': 'me', 'platform': 'uplay'});
    final calls = <Uri>[];
    final client = MockClient((req) async {
      calls.add(req.url);
      return http.Response.bytes(utf8.encode(req.url.path.endsWith('v2/profile') ? raw('profile') : raw('operators')), 200);
    });
    final state = AppState(await SharedPreferences.getInstance(), httpClient: client, game: game, counters: CounterBook.empty, ranks: ladder);
    await state.refresh(force: true);
    final before = calls.length;
    await tester.pumpWidget(R6CoachApp(state: state));
    await state.compareWith('rival', 'uplay');
    expect(calls.length - before, 2);
    expect(calls.skip(before).every((u) => u.queryParameters['nameOnPlatform'] == 'rival'), isTrue);
    expect(state.other, isNotNull);
    expect(state.callsThisMonth, 4);
    state.clearOther();
    expect(state.other, isNull);
  });
}
