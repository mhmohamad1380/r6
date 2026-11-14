import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:r6_coach/app_state.dart';
import 'package:r6_coach/data/counters.dart';
import 'package:r6_coach/data/models.dart';
import 'package:r6_coach/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

String fixture(String n) => File('test/fixtures/$n.json').readAsStringSync();
Finder nav(String label) => find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

List<GameOperator> game() => GameOperator.listFromResponse(jsonDecode(File('assets/game_operators.json').readAsStringSync()));
CounterBook counters() => CounterBook.parse(File('assets/counters.json').readAsStringSync());

void phone(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 2340);
  t.view.devicePixelRatio = 2.6;
  addTearDown(t.view.reset);
}

void main() {
  testWidgets('first run shows the welcome guide, not an empty app', (tester) async {
    phone(tester);
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SharedPreferences.getInstance());
    await tester.pumpWidget(R6CoachApp(state: state));
    expect(find.text('Welcome to R6 Coach'), findsOneWidget);
    expect(find.textContaining('Nothing to sign up for'), findsOneWidget);
  });

  testWidgets('loads real fixtures, shows every tab, and spends exactly 2 calls', (tester) async {
    phone(tester);
    SharedPreferences.setMockInitialValues({'apiKey': 'test-key', 'username': 'cyruson1001', 'platform': 'uplay'});
    final calls = <Uri>[];
    final client = MockClient((req) async {
      calls.add(req.url);
      expect(req.headers['api-key'], 'test-key');
      final body = req.url.path.endsWith('v2/profile') ? fixture('profile') : fixture('operators');
      return http.Response.bytes(utf8.encode(body), 200);
    });
    final state = AppState(await SharedPreferences.getInstance(), httpClient: client, game: game(), counters: counters());
    await tester.pumpWidget(R6CoachApp(state: state));
    await state.refresh(force: true);
    await tester.pump(const Duration(seconds: 2));

    expect(calls.length, 2, reason: 'one refresh = profile + operators');
    expect(state.callsThisMonth, 2);
    expect(find.text('cyruson1001'), findsOneWidget);
    expect(find.text('Silver 5'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Skill profile'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Skill profile'), findsOneWidget);

    await tester.tap(nav('Matches'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Your match log starts here'), findsOneWidget);

    await tester.tap(nav('Stats'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Patterns across all your replays.'), findsOneWidget, reason: 'replay patterns come first, even with a key');
    await tester.tap(find.text('Lifetime'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Kapkan'), findsWidgets);
    await tester.tap(find.text('Sides'));
    await tester.pump(const Duration(seconds: 1));
    await tester.scrollUntilVisible(find.text('Operator pool'), 400, scrollable: find.byType(Scrollable).first);
    expect(find.text('Operator pool'), findsOneWidget);

    await tester.tap(nav('Stats'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Improve'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Fix first'), findsOneWidget);

    await tester.tap(nav('Profile'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300)); // the fade removes the old page one frame after it ends
    expect(find.text('Connect your PC'), findsWidgets, reason: 'setup comes first on Profile');
    for (final t in ['Your account', 'Lifetime stats (optional)']) {
      await tester.scrollUntilVisible(find.text(t), 300, scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(calls.length, 2, reason: 'browsing tabs must not call the API');
  });

  testWidgets('a second refresh inside a minute is blocked and costs nothing', (tester) async {
    phone(tester);
    SharedPreferences.setMockInitialValues({'apiKey': 'k', 'username': 'x', 'platform': 'uplay'});
    var n = 0;
    final client = MockClient((req) async {
      n++;
      return http.Response.bytes(utf8.encode(req.url.path.endsWith('v2/profile') ? fixture('profile') : fixture('operators')), 200);
    });
    final state = AppState(await SharedPreferences.getInstance(), httpClient: client);
    await state.refresh(force: true);
    await state.refresh(force: true);
    await state.refresh();
    expect(n, 2);
    expect(state.notice, isNotNull);
  });

  testWidgets('bad key shows a clear error', (tester) async {
    phone(tester);
    SharedPreferences.setMockInitialValues({'apiKey': 'bad', 'username': 'x', 'platform': 'uplay'});
    final state = AppState(await SharedPreferences.getInstance(), httpClient: MockClient((_) async => http.Response('{}', 401)));
    await tester.pumpWidget(R6CoachApp(state: state));
    await state.refresh(force: true);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('API key rejected'), findsOneWidget);
  });
}
