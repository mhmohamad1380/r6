import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:r6_coach/app_state.dart';
import 'package:r6_coach/data/counters.dart';
import 'package:r6_coach/data/match_notes.dart';
import 'package:r6_coach/data/models.dart';
import 'package:r6_coach/data/ranks.dart';
import 'package:r6_coach/data/replay.dart';
import 'support/synthetic_replays.dart';
import 'package:r6_coach/data/snapshots.dart';
import 'package:r6_coach/analytics/match_coach.dart';
import 'package:r6_coach/features/replays/coach_screen.dart';
import 'package:r6_coach/features/replays/replay_insights_ui.dart';
import 'package:r6_coach/features/replays/replay_ui.dart';
import 'package:r6_coach/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

String raw(String n) => File('test/fixtures/$n.json').readAsStringSync();

/// Real replay rounds, with the test player's name put in place of one real player.
String replaysJson() {
  String r(String n) => File('test/fixtures/replays/$n').readAsStringSync().replaceAll('Hellcat352020', 'cyruson1001');
  final rounds = [for (final n in ['ranked_2.rec.json', 'ranked_1.rec.json', 'quick_1.rec.json']) ...parseReplayJson(r(n)).rounds, ...asPlayer(richSet(), 'cyruson1001')];
  return jsonEncode([for (final x in rounds) x.toJson()]);
}
Finder nav(String l) => find.byType(NavigationDestination).at(const ['Home', 'Coach', 'Matches', 'Stats', 'Profile'].indexOf(l));

/// Two snapshots that differ by one ranked win on Kapkan, so the match log has an entry.
String snapshotsJson() {
  final p = PlayerProfile.fromJson(jsonDecode(raw('profile')) as Map<String, dynamic>);
  final o = OperatorStat.listFromResponse(jsonDecode(raw('operators')) as Map<String, dynamic>);
  final a = Snapshot.from(p, o, at: DateTime.now().subtract(const Duration(hours: 2)));
  final modes = {for (final e in a.modes.entries) e.key: e.value};
  modes['ranked'] = ModeCounts(wins: modes['ranked']!.wins + 1, losses: modes['ranked']!.losses, kills: modes['ranked']!.kills + 6, deaths: modes['ranked']!.deaths + 4, rp: (modes['ranked']!.rp ?? 0) + 47);
  final ops = {for (final e in a.ops.entries) e.key: Map<String, int>.from(e.value)};
  for (final e in {'r': 8, 'rw': 5, 'rl': 3, 'k': 6, 'd': 4, 'hs': 3, 'fb': 1, 'fd': 1, 'm': 1, 'mw': 1}.entries) {
    ops['Kapkan']![e.key] = ops['Kapkan']![e.key]! + e.value;
  }
  final b = Snapshot(at: DateTime.now().subtract(const Duration(minutes: 10)), modes: modes, ops: ops, rank: a.rank, rankColor: a.rankColor);
  return jsonEncode([a.toJson(), b.toJson()]);
}

void main() {
  final game = GameOperator.listFromResponse(jsonDecode(File('assets/game_operators.json').readAsStringSync()));
  final counters = CounterBook.parse(File('assets/counters.json').readAsStringSync());
  final ladder = RankLadder.parse(File('assets/ranks.json').readAsStringSync());

  for (final cfg in [(320.0, 640.0, 1.0), (360.0, 740.0, 1.3), (411.0, 891.0, 1.0)]) {
    final label = '${cfg.$1.toInt()}dp wide, text x${cfg.$3}';

    /// Fresh app per flow, so one flow's navigation state cannot affect another.
    Future<(AppState, void Function(String), Future<void> Function(), Future<void> Function())> boot(WidgetTester tester) async {
      tester.view.physicalSize = Size(cfg.$1 * 3, cfg.$2 * 3);
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = cfg.$3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      SharedPreferences.setMockInitialValues({
        'apiKey': 'k',
        'username': 'cyruson1001',
        'platform': 'uplay',
        'cache.profile': raw('profile'),
        'cache.operators': raw('operators'),
        'cache.at': DateTime.now().toIso8601String(),
        'snapshots': snapshotsJson(),
        'replays': replaysJson(),
        'rs.url': 'https://188-121-118-79.sslip.io',
        'rs.token': 'read-token-for-layout',
      });
      final client = MockClient((req) async => http.Response.bytes(utf8.encode(req.url.path.endsWith('v2/profile') ? raw('profile') : raw('operators')), 200));
      final state = AppState(await SharedPreferences.getInstance(), httpClient: client, game: game, counters: counters, ranks: ladder, maps: parseMaps(File('assets/maps.json').readAsStringSync()));
      await tester.pumpWidget(R6CoachApp(state: state));
      await tester.pump(const Duration(seconds: 2));
      var where = 'start';
      void check() {
        final e = tester.takeException();
        if (e != null) {
          final text = e is FlutterError ? e.toStringDeep() : '$e';
          final all = text.split('\n');
          final i = all.indexWhere((l) => l.contains('relevant error-causing'));
          fail('[$where] ${[all.firstWhere((l) => l.contains('overflowed'), orElse: () => text.split('\n').first), if (i >= 0) ...all.skip(i + 1).take(14)].join('\n')}');
        }
      }

      Future<void> settle() async {
        await tester.pump(); // builds a newly pushed route or sheet
        await tester.pump(const Duration(milliseconds: 1200)); // then lets its animation run
        check();
      }

      Future<void> scrollThrough() async {
        final sc = find.byType(Scrollable);
        if (sc.evaluate().isEmpty) return;
        for (var i = 0; i < 6; i++) {
          await tester.drag(sc.first, const Offset(0, -500), warnIfMissed: false);
          await tester.pump(const Duration(milliseconds: 300));
          check();
        }
        for (var i = 0; i < 8; i++) {
          await tester.drag(sc.first, const Offset(0, 700), warnIfMissed: false);
          await tester.pump(const Duration(milliseconds: 100));
        }
        check();
      }

      return (state, (String w) => where = w, settle, scrollThrough);
    }

    testWidgets('Home, Matches, Sessions, RP, detail: $label', (tester) async {
      final (state, at, settle, scroll) = await boot(tester);
      await settle();
      await scroll();
      at('Matches');
      await tester.tap(nav('Matches'));
      await settle();
      await scroll();
      for (final t in ['Sessions', 'RP', 'Replays']) {
        at('Matches/$t');
        await tester.tap(find.text(t).first);
        await settle();
        await scroll();
      }
      at('Match Coach');
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 6000, warnIfMissed: false); // top of the tab, then down to the card
      await tester.pump(const Duration(milliseconds: 600));
      await tester.scrollUntilVisible(find.text('Match Coach'), 200, scrollable: find.byType(Scrollable).first, maxScrolls: 40);
      await tester.ensureVisible(find.text('Match Coach').first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Match Coach').first);
      await settle();
      await scroll();
      // The coach is a pushed screen: its segmented control and sections are found inside it, not in the tab below.
      final coach = find.byType(MatchCoachScreen);
      expect(coach, findsOneWidget);
      Finder inCoach(String t) => find.descendant(of: coach, matching: find.text(t));
      // Scroll the coach's list by dragging until the thing is on screen (it may be above or below).
      Future<void> reach(Finder f) async {
        final list = find.descendant(of: coach, matching: find.byType(ListView)).first;
        for (var i = 0; i < 120 && f.evaluate().isEmpty; i++) {
          await tester.drag(list, Offset(0, i < 60 ? -300 : 300), warnIfMissed: false);
          await tester.pump(const Duration(milliseconds: 60));
        }
        expect(f, findsWidgets, reason: 'the coach should have this');
        await tester.ensureVisible(f.first);
        await tester.pump(const Duration(milliseconds: 250));
      }

      for (final page in ['Matches', 'Details']) {
        at('Match Coach/$page');
        await tester.tap(inCoach(page).first);
        await settle();
        await scroll();
      }
      final offered = [for (final d in detailSections(tester.element(coach), buildMatchCoach(state.replays, replayPlayerName(state)).report)) d.title];
      expect(offered.length, greaterThanOrEqualTo(6), reason: 'the test data should exercise most sections');
      for (final section in offered) {
        at('Match Coach/Details/$section');
        await reach(inCoach(section));
        await tester.tap(inCoach(section).first);
        await settle();
      }
      await scroll();
      at('Match Coach/Matches/open');
      await tester.drag(find.descendant(of: coach, matching: find.byType(Scrollable)).first, const Offset(0, 4000), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(inCoach('Matches').first);
      await settle();
      await reach(find.descendant(of: coach, matching: find.textContaining(RegExp(r'^(Won|Lost) \d–\d$'))));
      await tester.tap(find.descendant(of: coach, matching: find.textContaining(RegExp(r'^(Won|Lost) \d–\d$'))).first);
      await settle();
      expect(find.text('Match score'), findsOneWidget);
      await tester.pageBack();
      await settle();
      await tester.pageBack(); // out of the coach, back to the tab
      await settle();
      at('Match detail');
      for (var i = 0; i < 40 && find.text('Log').evaluate().isEmpty; i++) {
        await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 6000, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 600));
      }
      await tester.tap(find.text('Log'));
      await settle();
      await tester.tap(find.text('Victory').first);
      await settle();
      await scroll();
      // Add context: party size and a map, then check both were saved.
      Future<void> reveal(Finder f) async {
        for (var i = 0; i < 40 && f.evaluate().isEmpty; i++) {
          await tester.drag(find.byType(Scrollable).first, const Offset(0, -300), warnIfMissed: false);
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.ensureVisible(f.first);
        await tester.pump(const Duration(milliseconds: 300));
      }

      at('Replay screen');
      await tester.pageBack();
      await settle();
      await tester.tap(find.text('Replays').first);
      await settle();
      await scroll();
      await reveal(find.textContaining('exact timing'));
      await tester.tap(find.textContaining('exact timing').first);
      await settle();
      await scroll();
      await reveal(find.textContaining(RegExp(r'^Round \d+$')));
      await tester.tap(find.textContaining(RegExp(r'^Round \d+$')).first);
      await settle();
      await scroll();
      await tester.pageBack();
      await settle();
      for (var i = 0; i < 40 && find.text('Log').evaluate().isEmpty; i++) {
        await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 6000, warnIfMissed: false); // back to the top; the tab is long
        await tester.pump(const Duration(milliseconds: 600));
      }
      await tester.tap(find.text('Log').first);
      await settle();
      await tester.tap(find.text('Victory').first);
      await settle();
      at('Context card');
      await tester.scrollUntilVisible(find.text('Duo'), 300, scrollable: find.byType(Scrollable).first, maxScrolls: 30);
      await tester.ensureVisible(find.text('Duo'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Duo'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.ensureVisible(find.text('Choose map'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Choose map'));
      await settle();
      await tester.tap(find.text('Bank').first);
      await settle();
      expect(state.notes.length, 1);
      final saved = state.notes.values.single;
      expect(saved.party, 'duo');
      expect(saved.map, 'Bank');
      await tester.pageBack();
      await settle();
      expect(find.text('Bank'), findsWidgets, reason: 'the match card shows the map');
    });

    testWidgets('Analytics, sheet, sides, modes, compare: $label', (tester) async {
      final (state, at, settle, scroll) = await boot(tester);
      at('Analytics');
      await tester.tap(nav('Stats'));
      await settle();
      await tester.tap(find.text('Lifetime').first); // Patterns is the first page; lifetime numbers are the second
      await settle();
      await scroll();
      at('Operator sheet');
      for (var i = 0; i < 40 && find.text('Kapkan').evaluate().length < 2; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -300), warnIfMissed: false); // until the list row is built
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -250), warnIfMissed: false); // keep the row clear of the nav bar
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Kapkan').last, warnIfMissed: false);
      await settle();
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -600), warnIfMissed: false);
      await settle();
      if (find.byType(BottomSheet).evaluate().isNotEmpty) Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await settle();
      for (final t in ['Sides', 'Modes', 'Maps']) {
        at('Analytics/$t');
        await tester.fling(find.byType(Scrollable).first, const Offset(0, 4000), 6000, warnIfMissed: false);
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.text(t).first);
        await settle();
        await scroll();
      }
      at('Compare');
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 4000), 6000, warnIfMissed: false);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Operators').first);
      await settle();
      await tester.tap(find.text('Compare with a friend'));
      await settle();
      await state.compareWith('rival', 'uplay');
      await settle();
      await scroll();
    });

    testWidgets('Improve and Profile: $label', (tester) async {
      final (_, at, settle, scroll) = await boot(tester);
      at('Improve');
      await tester.tap(nav('Stats'));
      await settle();
      await tester.tap(find.text('Improve').first);
      await settle();
      await scroll();
      at('Profile');
      await tester.tap(nav('Profile'));
      await settle();
      await scroll();
    });
  }
}
