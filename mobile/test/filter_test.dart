import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:r6_coach/analytics/insights.dart';
import 'package:r6_coach/analytics/scoring.dart';
import 'package:r6_coach/app_state.dart';
import 'package:r6_coach/data/models.dart';
import 'package:r6_coach/data/scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

String raw(String n) => File('test/fixtures/$n.json').readAsStringSync();

void main() {
  final all = OperatorStat.listFromResponse(jsonDecode(raw('operators')) as Map<String, dynamic>);
  final ranked = OperatorStat.listFromResponse(jsonDecode(raw('operators_ranked')) as Map<String, dynamic>);

  group('subtractOps', () {
    test('unranked = all minus ranked, round for round', () {
      final un = subtractOps(all, ranked);
      int rounds(List<OperatorStat> l) => l.fold(0, (s, o) => s + (o.roundsPlayed ?? 0));
      expect(rounds(un) + rounds(ranked), rounds(all));
      final kills = un.fold<int>(0, (s, o) => s + (o.kills ?? 0)) + ranked.fold<int>(0, (s, o) => s + (o.kills ?? 0));
      expect(kills, all.fold<int>(0, (s, o) => s + (o.kills ?? 0)));
      expect(un.every((o) => (o.roundsPlayed ?? 0) > 0), isTrue);
    });

    test('an operator only played in ranked disappears from unranked', () {
      const a = OperatorStat(name: 'X', side: 'Attacker', roundsPlayed: 10, kills: 5);
      const b = OperatorStat(name: 'X', side: 'Attacker', roundsPlayed: 10, kills: 5);
      expect(subtractOps([a], [b]), isEmpty);
    });

    test('mismatched fetch times never go negative and null stays null', () {
      const a = OperatorStat(name: 'X', side: 'Attacker', roundsPlayed: 10, kills: 3);
      const b = OperatorStat(name: 'X', side: 'Attacker', roundsPlayed: 4, kills: 9);
      final r = subtractOps([a], [b]).single;
      expect(r.kills, 0);
      expect(r.roundsPlayed, 6);
      expect(r.headshots, isNull);
    });
  });

  test('mode filter maps to API modes and request needs', () {
    expect(ModeFilter.quick.apiMode, 'quick-match');
    expect(ModeFilter.unranked.apiMode, isNull);
    expect(keysNeeded(ModeFilter.unranked, Period.lifetime), ['all|lifetime', 'ranked|lifetime']);
    expect(keysNeeded(ModeFilter.standard, Period.season), ['standard|season']);
    expect(scoringMode(ModeFilter.quick), 'quick_match');
  });

  group('AppState filters and request cost', () {
    late List<Uri> calls;
    late AppState state;

    Future<AppState> make() async {
      SharedPreferences.setMockInitialValues({'apiKey': 'k', 'username': 'cyruson1001', 'platform': 'uplay'});
      calls = [];
      final client = MockClient((req) async {
        calls.add(req.url);
        if (req.url.path.endsWith('v2/profile')) return http.Response.bytes(utf8.encode(raw('profile')), 200);
        final mode = req.url.queryParameters['modes'];
        final season = req.url.queryParameters['seasonYear'];
        final body = mode == 'ranked' ? raw('operators_ranked') : raw('operators');
        // The season response is a copy tagged so the test can tell it apart.
        return http.Response.bytes(utf8.encode(season != null && season != 'all' ? body.replaceAll('"seasonYear": "all"', '"seasonYear": "$season"') : body), 200);
      });
      state = AppState(await SharedPreferences.getInstance(), httpClient: client);
      await state.refresh(force: true);
      return state;
    }

    test('refresh is 2 calls; All view needs nothing else', () async {
      await make();
      expect(calls.length, 2);
      expect(state.activeReady, isTrue);
    });

    test('ranked costs 1 call once; unranked is then free', () async {
      await make();
      await state.setFilter(mode: ModeFilter.ranked);
      expect(calls.length, 3);
      expect(calls.last.queryParameters['modes'], 'ranked');
      await state.setFilter(mode: ModeFilter.all);
      await state.setFilter(mode: ModeFilter.ranked);
      expect(calls.length, 3, reason: 'cached');
      await state.setFilter(mode: ModeFilter.unranked);
      expect(calls.length, 3, reason: 'unranked is derived from all and ranked');
      final un = state.activeOps;
      final allRounds = state.opsFor(ModeFilter.all, Period.lifetime).fold<int>(0, (s, o) => s + (o.roundsPlayed ?? 0));
      final rankedRounds = state.opsFor(ModeFilter.ranked, Period.lifetime).fold<int>(0, (s, o) => s + (o.roundsPlayed ?? 0));
      expect(un.fold<int>(0, (s, o) => s + (o.roundsPlayed ?? 0)), allRounds - rankedRounds);
    });

    test('standard and quick each cost 1 call with the right API mode', () async {
      await make();
      await state.setFilter(mode: ModeFilter.standard);
      await state.setFilter(mode: ModeFilter.quick);
      expect(calls.skip(2).map((u) => u.queryParameters['modes']), ['standard', 'quick-match']);
    });

    test('season period sends the season id and costs 1 call', () async {
      await make();
      expect(state.seasonId, 'Y11S3');
      await state.setFilter(period: Period.season);
      expect(calls.length, 3);
      expect(calls.last.queryParameters['seasonYear'], 'Y11S3');
      expect(state.filterLabel, 'All · Y11S3');
      await state.setFilter(period: Period.lifetime);
      expect(calls.length, 3);
    });

    test('the filter choice survives a restart and results are scoped', () async {
      await make();
      await state.setFilter(mode: ModeFilter.ranked);
      final prefs = await SharedPreferences.getInstance();
      final again = AppState(prefs, httpClient: MockClient((_) async => http.Response('{}', 500)));
      expect(again.mode, ModeFilter.ranked);
      expect(again.activeReady, isTrue, reason: 'cached sets load without a request');
      expect(aggregate(again.activeOps).roundsPlayed, lessThan(aggregate(again.opsFor(ModeFilter.all, Period.lifetime)).roundsPlayed!));
    });

    test('a failed fetch leaves the previous data and reports the error', () async {
      await make();
      final bad = AppState(await SharedPreferences.getInstance(), httpClient: MockClient((_) async => http.Response('{}', 429)));
      await bad.setFilter(mode: ModeFilter.standard);
      expect(bad.error, contains('quota'));
      expect(bad.opsFor(ModeFilter.all, Period.lifetime), isNotEmpty);
    });
  });
}
