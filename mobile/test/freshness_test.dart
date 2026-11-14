import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:r6_coach/app_state.dart';
import 'package:r6_coach/data/arenyze_client.dart';
import 'package:r6_coach/data/models.dart';
import 'package:r6_coach/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

String raw(String n) => File('test/fixtures/$n.json').readAsStringSync();

/// The real profile fixture, with every server cache stamp set to [fetched].
String profileFetchedAt(DateTime fetched) {
  final j = jsonDecode(raw('profile')) as Map<String, dynamic>;
  for (final k in ['stats', 'account', 'banned', 'seasons', 'history']) {
    ((j[k] as Map)['_cache'] as Map)['fetchedAt'] = fetched.toUtc().toIso8601String();
  }
  return jsonEncode(j);
}

Future<AppState> loaded(String profileBody, {Map<String, String> headers = const {}, int status = 200}) async {
  SharedPreferences.setMockInitialValues({'apiKey': 'k', 'username': 'cyruson1001', 'platform': 'uplay'});
  final client = MockClient((req) async => http.Response.bytes(utf8.encode(req.url.path.endsWith('v2/profile') ? profileBody : raw('operators')), status, headers: headers));
  final s = AppState(await SharedPreferences.getInstance(), httpClient: client);
  await s.refresh(force: true);
  return s;
}

void main() {
  test('the real fixture carries the server cache time, and the newest block wins', () {
    final p = PlayerProfile.fromJson(jsonDecode(raw('profile')) as Map<String, dynamic>);
    expect(p.serverFetchedAt, DateTime.parse('2026-10-30T17:02:24.332Z'));
    expect(PlayerProfile.fromJson(const {}).serverFetchedAt, isNull);
  });

  group('stale detection', () {
    test('a copy that is hours old is stale, and its age is reported', () async {
      final s = await loaded(profileFetchedAt(DateTime.now().subtract(const Duration(hours: 13))));
      expect(s.serverStale, isTrue);
      expect(s.serverAge!.inHours, 13);
    });

    test('a copy from a few minutes ago is not stale', () async {
      final s = await loaded(profileFetchedAt(DateTime.now().subtract(const Duration(minutes: 10))));
      expect(s.serverStale, isFalse);
    });

    test('a response without a timestamp is never called stale', () async {
      final j = jsonDecode(raw('profile')) as Map<String, dynamic>;
      for (final k in ['stats', 'account', 'banned', 'seasons', 'history']) {
        (j[k] as Map).remove('_cache');
      }
      final s = await loaded(jsonEncode(j));
      expect(s.serverAge, isNull);
      expect(s.serverStale, isFalse);
    });

    test('refreshing again does not make an unchanged server copy look new', () async {
      final s = await loaded(profileFetchedAt(DateTime.now().subtract(const Duration(hours: 13))));
      await s.refresh(force: true, bypassGap: true);
      expect(s.serverStale, isTrue, reason: 'our own fetch time must not hide the server\'s age');
    });
  });

  group('rate limit headers', () {
    const h = {
      'x-ratelimit-day-limit': '400',
      'x-ratelimit-day-remaining': '390',
      'x-ratelimit-hour-limit': '200',
      'x-ratelimit-hour-remaining': '190',
      'x-ratelimit-minute-limit': '40',
      'x-ratelimit-minute-remaining': '39',
    };

    test('are parsed and exposed by the state', () async {
      final s = await loaded(raw('profile'), headers: h);
      expect([s.rate!.dayRemaining, s.rate!.dayLimit, s.rate!.hourRemaining, s.rate!.minuteLimit], [390, 400, 190, 40]);
    });

    test('missing headers give no limits rather than zeros', () {
      expect(RateLimits.fromHeaders(const {}), isNull);
    });

    test('a 429 explains which limit was hit', () async {
      for (final c in [('x-ratelimit-minute-remaining', 'minute'), ('x-ratelimit-hour-remaining', 'Hourly'), ('x-ratelimit-day-remaining', 'Daily')]) {
        final s = await loaded('{}', status: 429, headers: {...h, c.$1: '0'});
        expect(s.error, contains(c.$2), reason: c.$1);
      }
    });
  });

  group('the banner', () {
    Future<void> pump(WidgetTester t, AppState s) async {
      t.view.physicalSize = const Size(1080, 2340);
      t.view.devicePixelRatio = 2.6;
      addTearDown(t.view.reset);
      await t.pumpWidget(R6CoachApp(state: s));
      await t.pump(const Duration(seconds: 2));
    }

    testWidgets('appears for an old copy and says why', (t) async {
      final s = await loaded(profileFetchedAt(DateTime.now().subtract(const Duration(hours: 13))));
      await pump(t, s);
      expect(find.textContaining('copy of your stats is 13 h old'), findsOneWidget);
      await t.tap(find.text('Why?'));
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      expect(find.textContaining('does not talk to Ubisoft directly'), findsOneWidget);
    });

    testWidgets('is absent for fresh data', (t) async {
      final s = await loaded(profileFetchedAt(DateTime.now().subtract(const Duration(minutes: 5))));
      await pump(t, s);
      expect(find.textContaining('copy of your stats'), findsNothing);
    });
  });
}
