import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:r6_coach/app_state.dart';
import 'package:r6_coach/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/synthetic_replays.dart';

Finder nav(String l) => find.descendant(of: find.byType(NavigationBar), matching: find.text(l));

/// Boots the real app with only a replay set: no key, no network. Records every request so the tests can prove none are made.
Future<(AppState, List<Uri>)> boot(WidgetTester tester, Map<String, Object> prefs, {required double w, double scale = 1.0}) async {
  tester.view.physicalSize = Size(w * 3, 860 * 3);
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
  SharedPreferences.setMockInitialValues(prefs);
  final calls = <Uri>[];
  final client = MockClient((req) async {
    calls.add(req.url);
    return http.Response('{}', 404);
  });
  final state = AppState(await SharedPreferences.getInstance(), httpClient: client);
  await tester.pumpWidget(R6CoachApp(state: state));
  await tester.pump(const Duration(seconds: 1));
  return (state, calls);
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

Future<void> go(WidgetTester tester, String tab) async {
  await tester.tap(nav(tab));
  await settle(tester);
  await tester.pump(const Duration(milliseconds: 300));
}

Map<String, Object> replayOnly({bool name = true, bool server = false}) => {
      'replays': jsonEncode([for (final r in recordedBy(asPlayer(richSet(), 'cyruson1001'), 'cyruson1001')) r.toJson()]),
      if (name) 'username': 'cyruson1001',
      if (server) ...{'rs.url': 'https://example.test', 'rs.token': 'tok'},
    };

void main() {
  for (final cfg in [(320.0, 1.0), (360.0, 1.3), (411.0, 1.0)]) {
    final label = '${cfg.$1.toInt()}dp, text x${cfg.$2}';

    testWidgets('the first-run guide: three short steps, no key anywhere ($label)', (tester) async {
      final (state, calls) = await boot(tester, {}, w: cfg.$1, scale: cfg.$2);
      expect(find.text('Welcome to R6 Coach'), findsOneWidget);
      expect(find.textContaining('API key'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing, reason: 'nothing to get lost in yet');
      await tester.tap(find.text('Get started'));
      await settle(tester);
      expect(find.text('Who are you in the game?'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue')).onPressed, isNull, reason: 'a name is needed to continue');
      await tester.enterText(find.byType(TextField).first, 'cyruson1001');
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await settle(tester);
      expect(state.username, 'cyruson1001');
      expect(find.text('Connect your PC'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'no overflow on any step');
      await tester.tap(find.text("I'll do this later"));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Hi, cyruson1001'), findsOneWidget);
      expect(find.text('Your next step'), findsOneWidget);
      expect(calls, isEmpty);
    });

    testWidgets('typing a name can be skipped: the replays will say who you are ($label)', (tester) async {
      final (state, _) = await boot(tester, {}, w: cfg.$1, scale: cfg.$2);
      await tester.tap(find.text('Get started'));
      await settle(tester);
      await tester.tap(find.text('Skip: find me from my replays'));
      await settle(tester);
      expect(find.text('Connect your PC'), findsOneWidget);
      expect(state.username, isEmpty);
      await tester.tap(find.text("I'll do this later"));
      await settle(tester);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('replays only: every tab works with no key and makes no network call ($label)', (tester) async {
      final (_, calls) = await boot(tester, replayOnly(), w: cfg.$1, scale: cfg.$2);
      expect(find.text('Hi, cyruson1001'), findsOneWidget);
      expect(find.text('Match Coach'), findsWidgets, reason: 'the coach is on the home screen');
      expect(tester.takeException(), isNull);

      await go(tester, 'Coach');
      expect(find.text('Overview'), findsOneWidget);
      expect(find.textContaining('Playing as cyruson1001'), findsOneWidget);
      for (final page in ['Matches', 'Details']) {
        await tester.tap(find.text(page).first);
        await settle(tester);
        expect(tester.takeException(), isNull, reason: page);
      }

      await go(tester, 'Matches');
      expect(find.text('Replay analysis'), findsOneWidget, reason: 'replays are the default when there is no key');
      expect(find.text('Log'), findsNothing, reason: 'the stats-only tabs are not offered without the key: no dead ends');
      await tester.scrollUntilVisible(find.text('Rank history and match log (optional)'), 300, scrollable: find.byType(Scrollable).last);
      expect(find.text('Rank history and match log (optional)'), findsOneWidget, reason: 'one quiet way to the optional part');

      await go(tester, 'Stats');
      expect(find.text('Patterns across all your replays.'), findsOneWidget, reason: 'Stats works from replays alone');
      expect(find.text('Lifetime stats are optional'), findsNothing);
      expect(find.text('Lifetime'), findsNothing, reason: 'no tab that could only say "turn me on"');
      await tester.scrollUntilVisible(find.text('Lifetime stats (optional)'), 300, scrollable: find.byType(Scrollable).last);
      expect(find.text('Lifetime stats (optional)'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await go(tester, 'Profile');
      expect(find.text('Connect your PC'), findsWidgets);
      expect(tester.takeException(), isNull);
      expect(calls, isEmpty, reason: 'no key, so not a single request');
    });

    testWidgets('the replays alone identify you, with no name saved ($label)', (tester) async {
      final (state, _) = await boot(tester, replayOnly(name: false), w: cfg.$1, scale: cfg.$2);
      expect(state.playerName, 'cyruson1001');
      expect(state.username, 'cyruson1001', reason: 'saved from the replays at launch');
      expect(find.byType(NavigationBar), findsOneWidget, reason: 'a user with replays is never sent back to the guide');
      expect(find.text('Hi, cyruson1001'), findsOneWidget);
      await go(tester, 'Coach');
      expect(find.textContaining('You are improving'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the next step always says what to press, for every stage of getting set up', (tester) async {
    // 1. A name but nothing connected.
    var (state, _) = await boot(tester, {'username': 'cyruson1001'}, w: 411);
    expect(find.text('Connect your PC'), findsOneWidget);
    expect(find.text('Connect my PC'), findsOneWidget);
    expect(find.text('Or import a replay file by hand'), findsOneWidget);
    await tester.tap(find.text('Connect my PC'));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Profile'), findsWidgets);
    expect(find.text('Connect your PC'), findsNWidgets(2), reason: 'it took us to Profile, where the Connect your PC section is right under the card');
    expect(state.hasAccount, isTrue);

    // 2. Connected, nothing received yet.
    (state, _) = await boot(tester, {'username': 'cyruson1001', 'rs.url': 'https://example.test', 'rs.token': 'tok'}, w: 411);
    expect(find.text('Waiting for your first replays'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
    await go(tester, 'Coach');
    expect(find.text('Waiting for your first replays'), findsOneWidget, reason: 'the coach tab guides too');
  });
}
