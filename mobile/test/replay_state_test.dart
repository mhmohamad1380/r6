import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:r6_coach/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

String raw(String n) => File('test/fixtures/replays/$n').readAsStringSync();

Future<(AppState, List<http.Request>)> make({int status = 200, String? body, String key = 'secret-key-xyz'}) async {
  SharedPreferences.setMockInitialValues({'apiKey': key, 'username': 'cyruson1001', 'platform': 'uplay'});
  final seen = <http.Request>[];
  final client = MockClient((req) async {
    seen.add(req);
    return http.Response.bytes(utf8.encode(body ?? raw('arenyze_upload_quick_1.json')), status);
  });
  return (AppState(await SharedPreferences.getInstance(), httpClient: client), seen);
}

File tmpRec(String name) => File('${Directory.systemTemp.path}/$name')..writeAsBytesSync([0x28, 0xb5, 0x2f, 0xfd, 1, 2, 3]);

void main() {
  group('importing r6-dissect JSON', () {
    test('adds rounds, ignores repeats, and survives a restart', () async {
      final (s, _) = await make();
      final a = await s.importReplayJson(raw('ranked_1.rec.json'));
      final b = await s.importReplayJson('[${raw('ranked_2.rec.json')}, ${raw('quick_1.rec.json')}]');
      expect([a.added, b.added], [1, 2]);
      expect(s.replays.length, 3);
      final again = await s.importReplayJson(raw('ranked_1.rec.json'));
      expect([again.added, again.duplicates], [0, 1]);
      expect(s.replays.length, 3);
      final restarted = AppState(await SharedPreferences.getInstance());
      expect(restarted.replays.length, 3);
      expect(restarted.replays.every((r) => r.events.isNotEmpty), isTrue);
    });

    test('garbage is reported without changing anything', () async {
      final (s, seen) = await make();
      final r = await s.importReplayJson('definitely not json');
      expect(r.ok, isFalse);
      expect(r.message, isNotNull);
      expect(s.replays, isEmpty);
      expect(seen, isEmpty, reason: 'pasting JSON makes no request');
    });

    test('a round with real times replaces the same round without them', () async {
      final (s, _) = await make();
      await s.importReplayJson(raw('arenyze_upload_quick_1.json'));
      expect(s.replays.single.timed, isFalse);
      await s.importReplayJson(raw('quick_1.rec.json'));
      expect(s.replays, hasLength(1));
      expect(s.replays.single.timed, isTrue);
      await s.importReplayJson(raw('arenyze_upload_quick_1.json'));
      expect(s.replays.single.timed, isTrue, reason: 'an untimed copy never overwrites a timed one');
    });
  });

  group('uploading .rec files to Arenyze', () {
    test('sends a multipart POST with the key and the replayFiles field', () async {
      final (s, seen) = await make();
      final f = tmpRec('round1.rec');
      final r = await s.uploadReplays([f.path]);
      expect(r.ok, isTrue);
      expect(r.added, 1);
      final req = seen.single;
      expect(req.method, 'POST');
      expect(req.url.toString(), 'https://r6.arenyze.com/api/replays/api/upload');
      expect(req.headers['api-key'], 'secret-key-xyz');
      expect(req.headers['content-type'], startsWith('multipart/form-data'));
      final body = latin1.decode(req.bodyBytes); // the file part is raw binary, so it is not valid UTF-8
      expect(body, contains('name="replayFiles"'));
      expect(body, contains('filename="round1.rec"'));
      expect(s.replays.single.source, 'arenyze');
    });

    test('credits are read from the response and remembered', () async {
      final (s, _) = await make();
      await s.uploadReplays([tmpRec('a.rec').path]);
      expect([s.replayQuota!.limit, s.replayQuota!.used, s.replayQuota!.remaining], [15, 1, 14]);
      final restarted = AppState(await SharedPreferences.getInstance());
      expect(restarted.replayQuota!.remaining, 14);
    });

    test('an upload is not counted as an API call', () async {
      final (s, _) = await make();
      await s.uploadReplays([tmpRec('a.rec').path]);
      expect(s.callsThisMonth, 0);
    });

    test('asking for more files than credits left makes no request', () async {
      final (s, seen) = await make();
      await s.uploadReplays([tmpRec('a.rec').path]); // leaves 14
      seen.clear();
      final paths = [for (var i = 0; i < 15; i++) tmpRec('f$i.rec').path];
      final r = await s.uploadReplays(paths);
      expect(r.ok, isFalse);
      expect(r.message, contains('14 replay credits left'));
      expect(seen, isEmpty);
    });

    test('too many files, no files and no key are refused locally', () async {
      final (s, seen) = await make();
      expect((await s.uploadReplays([])).ok, isFalse);
      expect((await s.uploadReplays([for (var i = 0; i < 21; i++) 'x$i.rec'])).message, contains('at most 20'));
      SharedPreferences.setMockInitialValues({});
      final nokey = AppState(await SharedPreferences.getInstance());
      expect((await nokey.uploadReplays(['a.rec'])).message, contains('API key'));
      expect(seen, isEmpty);
    });

    test('server errors become clear messages and change nothing', () async {
      for (final c in [(401, 'API key'), (429, 'credits'), (413, 'too large'), (400, 'single match'), (500, 'Server returned 500')]) {
        final (s, _) = await make(status: c.$1, body: '{}');
        final r = await s.uploadReplays([tmpRec('a.rec').path]);
        expect(r.ok, isFalse, reason: '${c.$1}');
        expect(r.message, contains(c.$2), reason: '${c.$1}');
        expect(s.replays, isEmpty);
        expect(s.replayBusy, isFalse);
      }
    });

    test('a server message is shown when it gives one', () async {
      final (s, _) = await make(status: 429, body: '{"error":"Monthly replay limit reached"}');
      expect((await s.uploadReplays([tmpRec('a.rec').path])).message, 'Monthly replay limit reached');
    });
  });

  group('managing replays', () {
    test('deleting a match removes all of its rounds', () async {
      final (s, _) = await make();
      await s.importReplayJson('[${raw('ranked_1.rec.json')}, ${raw('ranked_2.rec.json')}]');
      final id = s.replays.first.matchId;
      await s.deleteReplayMatch(id);
      expect(s.replays.every((r) => r.matchId != id), isTrue);
    });

    test('backups carry replays and never the key', () async {
      final (s, _) = await make();
      await s.importReplayJson(raw('ranked_2.rec.json'));
      final text = s.exportBackup();
      expect(text, isNot(contains('secret-key-xyz')));
      final (fresh, _) = await make();
      expect(await fresh.importBackup(text), isNull);
      expect(fresh.replays.single.map, 'Bank');
    });

    test('old backups without replays still restore', () async {
      final (s, _) = await make();
      final old = jsonEncode({'v': 1, 'player': 'cyruson1001', 'snapshots': [], 'goals': [], 'notes': {}, 'ledger': []});
      expect(await s.importBackup(old), isNull);
    });
  });
}
