import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r6_coach/app_state.dart';
import 'package:r6_coach/core/replay_charts.dart';
import 'package:r6_coach/core/theme.dart';
import 'package:r6_coach/features/replays/coach_screen.dart';
import 'package:r6_coach/features/replays/replay_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/synthetic_replays.dart';

Future<AppState> app(List<Object> rounds) async {
  SharedPreferences.setMockInitialValues({'apiKey': 'k', 'username': 'cyruson1001', 'platform': 'uplay', 'replays': jsonEncode(rounds)});
  return AppState(await SharedPreferences.getInstance());
}

Future<void> show(WidgetTester tester, Widget w) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: w));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).first, maxScrolls: 60);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> tapText(WidgetTester tester, String t) async {
  await scrollTo(tester, find.text(t));
  await tester.tap(find.text(t).first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<AppState> richState() async => app([for (final r in asPlayer(richSet(), 'cyruson1001')) r.toJson()]);

void main() {
  testWidgets('the Replays tab is short: a coach card and the matches, not a wall of cards', (tester) async {
    final s = await richState();
    await show(tester, Scaffold(body: Builder(builder: (c) => ListView(padding: const EdgeInsets.all(16), children: replaysSection(c, s)))));
    expect(find.text('Match Coach'), findsOneWidget);
    for (final gone in ['Attack and defense', 'What to work on', 'Operators', 'Clutches and multi-kills']) {
      expect(find.text(gone), findsNothing, reason: '$gone lives inside the coach now');
    }
    await scrollTo(tester, find.text('Matches'));
    expect(find.textContaining('Score '), findsWidgets, reason: 'match cards carry their score');
  });

  testWidgets('the Overview page says what you are doing, what to work on first, and a plan', (tester) async {
    final s = await richState();
    await show(tester, MatchCoachScreen(state: s));
    expect(find.text('Overview'), findsOneWidget);
    expect(find.textContaining('You are improving'), findsOneWidget);
    for (final t in ['Work on this first', 'Plan for your next session', 'Best and worst match', 'Your score over time']) {
      await scrollTo(tester, find.text(t));
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('Attack and defense'), findsNothing, reason: 'the numbers are on the Details page');
  });

  testWidgets('the Matches page scores every match and explains it', (tester) async {
    final s = await richState();
    await show(tester, MatchCoachScreen(state: s));
    await tester.tap(find.text('Matches'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('8 matches'), findsOneWidget);
    expect(find.textContaining('Strong win'), findsWidgets);
    await scrollTo(tester, find.textContaining('Rough game'));
    expect(find.textContaining('usually'), findsWidgets, reason: 'reasons show your usual number next to this match');
    expect(find.textContaining('vs usual'), findsWidgets);
    // Opening a match goes to its round-by-round screen.
    await tester.tap(find.textContaining('Rough game').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Match score'), findsOneWidget);
  });

  testWidgets('the Details page keeps sections closed until you open them', (tester) async {
    final s = await richState();
    await show(tester, MatchCoachScreen(state: s));
    await tester.tap(find.text('Details'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (final t in ['Your numbers', 'How the score is made', 'Attack and defense', 'The first fight', 'Clutches and multi-kills', 'When things happen', 'Operators', 'Maps', 'By bombsite', 'All findings']) {
      await scrollTo(tester, find.text(t));
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('Attack'), findsNothing, reason: 'closed: the attack/defense chart is not built yet');
    await tapText(tester, 'Attack and defense');
    expect(find.textContaining(RegExp(r'^Attack · \d+ rounds$')), findsOneWidget);
    await tapText(tester, 'Attack and defense');
    expect(find.textContaining(RegExp(r'^Attack · \d+ rounds$')), findsNothing, reason: 'tapping again closes it');
  });

  testWidgets('KOST is explained and the score info sheet explains the weights', (tester) async {
    final s = await richState();
    await show(tester, MatchCoachScreen(state: s));
    await tester.tap(find.text('Details'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tapText(tester, 'Your numbers');
    await scrollTo(tester, find.text('What is KOST?'));
    await tester.tap(find.text('What is KOST?'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('Traded: you died'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // dismiss the sheet
    await tester.pump(const Duration(milliseconds: 600));
    await tapText(tester, 'How the score is made');
    await scrollTo(tester, find.text('How is this scored?'));
    await tester.tap(find.text('How is this scored?'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('Impact (KOST) 30%'), findsOneWidget);
    expect(find.textContaining('assumptions'), findsOneWidget);
  });

  testWidgets('with too few matches the coach says how many more are needed', (tester) async {
    final s = await app([for (final r in asPlayer(series(2, 5, (_) => true), 'cyruson1001')) r.toJson()]);
    await show(tester, MatchCoachScreen(state: s));
    await scrollTo(tester, find.text('Your score over time'));
    expect(find.text('Not enough data yet'), findsOneWidget);
    expect(find.textContaining('Save 2 more matches'), findsOneWidget);
  });

  testWidgets('a player who is not in the replays gets a clear message, not a score', (tester) async {
    final s = await app([for (final r in series(1, 5, (_) => true)) r.toJson()]); // one match, and the configured user is not in it: nobody can be picked out of ten equal players
    await show(tester, Scaffold(body: Builder(builder: (c) => ListView(padding: const EdgeInsets.all(16), children: replaysSection(c, s)))));
    await scrollTo(tester, find.textContaining('is not in these replays'));
    expect(find.text('Match Coach'), findsNothing);
    await show(tester, MatchCoachScreen(state: s));
    expect(find.text('We could not find you in these replays'), findsOneWidget, reason: 'the coach says what is wrong and how to fix it');
    expect(find.text('Check my name'), findsOneWidget);
  });

  testWidgets('the match screen shows the match score and a tile for every round', (tester) async {
    final rounds = asPlayer(series(1, 6, (_) => true), 'cyruson1001');
    final s = await app([for (final r in rounds) r.toJson()]);
    await show(tester, ReplayMatchScreen(state: s, matchId: rounds.first.matchId));
    expect(find.text('Match score'), findsOneWidget);
    await scrollTo(tester, find.text('Round by round'));
    final tiles = find.descendant(of: find.byType(RoundFlow), matching: find.byWidgetPredicate((w) => w is Semantics && RegExp(r'^Round \d, (attack|defense), won, 2 kills$').hasMatch(w.properties.label ?? '')));
    expect(tiles, findsNWidgets(6));
  });

  testWidgets('touching the trend chart reads out a match', (tester) async {
    await show(tester, const Scaffold(body: Padding(padding: EdgeInsets.all(16), child: TrendChart(points: [TrendPoint(40, 'Bank · older'), TrendPoint(55, 'Villa · middle'), TrendPoint(70, 'Oregon · newest')]))));
    expect(find.text('Touch the chart to inspect a match'), findsOneWidget);
    await tester.tapAt(tester.getTopRight(find.byType(CustomPaint).last) + const Offset(-4, 60));
    await tester.pump();
    expect(find.textContaining('70 · Oregon · newest'), findsOneWidget);
  });
}
