import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:r6_coach/analytics/context.dart';
import 'package:r6_coach/analytics/insights.dart';
import 'package:r6_coach/analytics/patterns.dart';
import 'package:r6_coach/analytics/recap.dart';
import 'package:r6_coach/analytics/rp.dart';
import 'package:r6_coach/app_state.dart';
import 'package:r6_coach/data/match_notes.dart';
import 'package:r6_coach/data/models.dart';
import 'package:r6_coach/data/snapshots.dart';
import 'package:shared_preferences/shared_preferences.dart';

String raw(String n) => File('test/fixtures/$n.json').readAsStringSync();

/// A single exact match record.
MatchRecord rec(int i, {bool win = true, int kills = 5, int deaths = 4, int hs = 2, int fb = 1, int fd = 1}) {
  final at = DateTime(2026, 10, 1).add(Duration(hours: i * 3));
  return MatchRecord(
    at: at.add(const Duration(minutes: 40)),
    since: at,
    mode: 'ranked',
    matches: 1,
    wins: win ? 1 : 0,
    losses: win ? 0 : 1,
    rpDelta: win ? 45 : -30,
    rpAfter: 2000,
    rank: 'Silver 5',
    totals: {'r': 8, 'rw': win ? 5 : 3, 'k': kills, 'd': deaths, 'hs': hs, 'fb': fb, 'fd': fd},
    ops: const [],
  );
}

void main() {
  group('context analysis', () {
    test('only annotated exact matches count', () {
      final log = [for (var i = 0; i < 4; i++) rec(i)];
      final notes = {log[0].since.toIso8601String(): const MatchNote(map: 'Bank'), log[1].since.toIso8601String(): const MatchNote()};
      MatchNote? look(MatchRecord r) => notes[r.since.toIso8601String()];
      expect(annotatedExact(log, look).length, 1);
      expect(byMap(log, look).single.label, 'Bank');
    });

    test('merged entries are never assigned to a map', () {
      final merged = MatchRecord(at: DateTime(2026), since: DateTime(2025), mode: 'ranked', matches: 2, wins: 1, losses: 1, rpDelta: 0, rpAfter: 0, rank: null, totals: const {}, ops: const []);
      expect(annotatedExact([merged], (_) => const MatchNote(map: 'Bank')), isEmpty);
    });

    test('weak map and solo-vs-stack findings need enough games and a real gap', () {
      final log = <MatchRecord>[];
      final notes = <String, MatchNote>{};
      void add(int n, String map, String party, bool win) {
        for (var i = 0; i < n; i++) {
          final r = rec(log.length, win: win);
          log.add(r);
          notes[r.since.toIso8601String()] = MatchNote(map: map, party: party);
        }
      }

      add(6, 'Bank', 'solo', true);
      add(1, 'Bank', 'solo', false);
      add(2, 'Oregon', 'squad', true);
      add(6, 'Oregon', 'squad', false);
      MatchNote? look(MatchRecord r) => notes[r.since.toIso8601String()];
      final ids = contextInsights(log, look).map((i) => i.id).toList();
      expect(ids, contains('party-gap'));
      expect(contextInsights(log, look).firstWhere((i) => i.id == 'party-gap').title, contains('solo'));
      final weak = contextInsights(log, look).firstWhere((i) => i.id == 'map-gap');
      expect(weak.title, contains('Oregon')); // Bank 6 of 7 wins vs Oregon 2 of 8: both have 5+ games and a large gap
    });

    test('too few games produce no findings', () {
      final log = [for (var i = 0; i < 3; i++) rec(i)];
      expect(contextInsights(log, (_) => const MatchNote(map: 'Bank', party: 'solo', feeling: 1)), isEmpty);
    });

    test('mood groups', () {
      final log = [rec(0), rec(1), rec(2)];
      final feel = [1, 3, 5];
      MatchNote? look(MatchRecord r) => MatchNote(feeling: feel[log.indexOf(r)]);
      expect(byFeeling(log, look).map((g) => g.label), ['Tilted or tired', 'Okay', 'Locked in']);
    });
  });

  group('time of day', () {
    RpDelta g(int hour, bool win) => RpDelta(DateTime(2026, 10, 5, hour), win ? 45 : -30, 2000, 'Silver 5');

    test('blocks cover the clock and late night wraps', () {
      final b = byTimeOfDay([g(8, true), g(14, true), g(20, false), g(23, false), g(2, false)]);
      expect(b.map((x) => x.games), [1, 1, 1, 2]);
      expect(b.last.label, 'Night');
    });

    test('a gap is reported only when both blocks have enough games', () {
      final games = [for (var i = 0; i < 9; i++) g(20, i < 7), for (var i = 0; i < 9; i++) g(23, i < 2)];
      final gap = timeGap(byTimeOfDay(games))!;
      expect(gap.best.label, 'Evening');
      expect(gap.worst.label, 'Night');
      expect(timeGap(byTimeOfDay([g(20, true), g(23, false)])), isNull);
    });
  });

  group('week recap and recent form', () {
    test('recap counts the last seven days only', () {
      final now = DateTime(2026, 10, 30, 12);
      final games = [
        RpDelta(now.subtract(const Duration(days: 1)), 45, 2000, null),
        RpDelta(now.subtract(const Duration(days: 2)), -30, 2000, null),
        RpDelta(now.subtract(const Duration(days: 3)), 40, 2000, null),
        RpDelta(now.subtract(const Duration(days: 20)), 40, 2000, null),
      ];
      final w = weekRecap(games, now: now)!;
      expect(w.games, 3);
      expect(w.net, 55);
      expect(weekRecap(games.take(2).toList(), now: now), isNull);
    });

    test('recent form needs 3 exact matches and compares correctly', () {
      expect(recentForm([rec(0), rec(1)]), isNull);
      final f = recentForm([rec(0), rec(1, win: false), rec(2)])!;
      expect(f.matches, 3);
      expect(f.kd, closeTo(15 / 12, 1e-9));
      expect(f.winRate, closeTo(2 / 3, 1e-9));
    });
  });

  group('ledger, notes and backup', () {
    Future<(AppState, SharedPreferences)> make({String profileBody = '', String key = 'secret-key-123'}) async {
      SharedPreferences.setMockInitialValues({'apiKey': key, 'username': 'cyruson1001', 'platform': 'uplay'});
      final body = profileBody.isEmpty ? raw('profile') : profileBody;
      final client = MockClient((req) async => http.Response.bytes(utf8.encode(req.url.path.endsWith('v2/profile') ? body : raw('operators')), 200));
      final prefs = await SharedPreferences.getInstance();
      final s = AppState(prefs, httpClient: client);
      await s.refresh(force: true);
      return (s, prefs);
    }

    test('the ledger keeps readings the API later drops', () async {
      final (s, _) = await make();
      final first = s.rpHistory.length;
      expect(first, 16);
      // A later refresh returns only the newest 10 readings plus one brand-new reading.
      final j = jsonDecode(raw('profile')) as Map<String, dynamic>;
      final rows = (((j['history'] as Map)['data'] as Map)['history'] as Map)['data'] as List;
      final newest = [
        [DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String(), Map<String, dynamic>.from(rows.first[1] as Map)..['value'] = 2100],
        ...rows.take(10),
      ];
      (((j['history'] as Map)['data'] as Map)['history'] as Map)['data'] = newest;
      final client2 = MockClient((req) async => http.Response.bytes(utf8.encode(req.url.path.endsWith('v2/profile') ? jsonEncode(j) : raw('operators')), 200));
      final again = AppState(await SharedPreferences.getInstance(), httpClient: client2);
      await again.refresh(force: true, bypassGap: true);
      expect(again.rpHistory.length, 17, reason: '16 remembered + 1 new; the API returned only 11');
      expect(again.rpHistory.first.rp, 2100);
    });

    test('notes persist per match and clearing the match log clears notes', () async {
      final (s, prefs) = await make();
      final r = rec(0);
      await s.saveNote(r, const MatchNote(map: 'Bank', party: 'solo', text: 'dc on site'));
      expect(s.noteFor(r)!.map, 'Bank');
      final again = AppState(prefs, httpClient: MockClient((_) async => http.Response('{}', 500)));
      expect(again.noteFor(r)!.text, 'dc on site');
      await s.saveNote(r, const MatchNote());
      expect(s.noteFor(r), isNull, reason: 'an empty note removes the entry');
    });

    test('backup round trip restores notes, goals, snapshots and ledger', () async {
      final (s, _) = await make();
      await s.saveNote(rec(0), const MatchNote(map: 'Oregon', feeling: 4));
      final text = s.exportBackup();
      expect(text.toLowerCase(), isNot(contains('apikey')));
      expect(text, isNot(contains(s.apiKey)));

      final (fresh, _) = await make();
      expect(fresh.notes, isEmpty);
      expect(await fresh.importBackup(text), isNull);
      expect(fresh.noteFor(rec(0))!.map, 'Oregon');
      expect(fresh.snapshots.length, s.snapshots.length);
    });

    test('bad or foreign backups are rejected and change nothing', () async {
      final (s, _) = await make();
      await s.saveNote(rec(0), const MatchNote(map: 'Bank'));
      expect(await s.importBackup('not json'), contains('Could not read'));
      expect(await s.importBackup('{"v":2}'), contains('not an R6 Coach backup'));
      final other = jsonEncode({'v': 1, 'player': 'someoneelse', 'snapshots': [], 'goals': [], 'notes': {}, 'ledger': []});
      expect(await s.importBackup(other), contains('belongs to someoneelse'));
      expect(s.noteFor(rec(0))!.map, 'Bank');
    });
  });

  test('insights still work with all new inputs on real data', () {
    final ops = OperatorStat.listFromResponse(jsonDecode(raw('operators')) as Map<String, dynamic>);
    final profile = PlayerProfile.fromJson(jsonDecode(raw('profile')) as Map<String, dynamic>);
    final items = buildInsights(ops, rp: RpAnalysis.from(profile.rpHistory), profile: profile);
    expect(items.where((i) => i.drill != null), isNotEmpty);
  });
}
