import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:r6_coach/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> fx(String n) => jsonDecode(File('test/fixtures/replays/$n').readAsStringSync()) as Map<String, dynamic>;

/// A stand-in for the replay server that follows the real API: a feed ordered by `seq`, paging, and ack.
class FakeServer {
  FakeServer({this.readToken = 'read-tok'});
  final String readToken;
  final items = <Map<String, dynamic>>[];
  final log = <String>[];
  int ackStatus = 200;
  bool down = false;
  List<int> acked = [];

  void add(int id, Map<String, dynamic> data, {String status = 'parsed'}) =>
      items.add({'id': id, 'seq': id, 'status': status, 'data': status == 'failed' ? null : data, 'recAvailable': true, 'filename': 'r$id.rec', 'size': 9000000});

  Future<http.Response> handle(http.Request r) async {
    if (down) throw const SocketException('unreachable');
    log.add('${r.method} ${r.url.path}');
    if (r.url.path == '/health') return http.Response('{"ok":true,"version":"0.1.0"}', 200);
    final tok = r.headers['Authorization'];
    if (tok == 'Bearer upload-tok') return http.Response('{"detail":"no"}', 403);
    if (tok != 'Bearer $readToken') return http.Response('{"detail":"no"}', 401);
    if (r.url.path == '/v1/stats') return http.Response('{"parsed":${items.where((i) => i['status'] == 'parsed').length},"recs":${items.length}}', 200);
    if (r.url.path == '/v1/rounds') {
      final after = int.parse(r.url.queryParameters['after'] ?? '0');
      final limit = int.parse(r.url.queryParameters['limit'] ?? '25');
      final rows = items.where((i) => (i['seq'] as int) > after).toList();
      final page = rows.take(limit).toList();
      return http.Response(jsonEncode({'rounds': page, 'nextCursor': page.isEmpty ? after : page.last['seq'], 'hasMore': rows.length > limit}), 200);
    }
    if (r.url.path == '/v1/ack') {
      if (ackStatus != 200) return http.Response('{}', ackStatus);
      final ids = [for (final i in (jsonDecode(r.body)['ids'] as List)) i as int];
      acked.addAll(ids);
      return http.Response(jsonEncode({'freedBytes': 9000000 * ids.length, 'results': []}), 200);
    }
    return http.Response('{}', 404);
  }
}

Future<(AppState, FakeServer)> make({String token = 'read-tok', Map<String, Object> prefs = const {}}) async {
  final s = FakeServer();
  SharedPreferences.setMockInitialValues({'apiKey': 'k', 'username': 'x', ...prefs});
  final st = AppState(await SharedPreferences.getInstance(), httpClient: MockClient(s.handle));
  await st.saveReplayServer('replays.example.com/', token);
  return (st, s);
}

void main() {
  final ranked = fx('ranked_2.rec.json'), quick = fx('quick_1.server_flat.json'), arenyze = fx('arenyze_upload_quick_1.json');
  // A different match from the other fixtures, so it is not a duplicate of the dissect round.
  final arenyzeRound = jsonDecode(jsonEncode((arenyze['rounds'] as List).first)) as Map<String, dynamic>..['header']['matchID'] = 'arenyze-only-match';

  test('server addresses are tidied', () {
    expect(AppState.normalizeServerUrl(' replays.example.com/ '), 'https://replays.example.com');
    expect(AppState.normalizeServerUrl('http://10.0.0.5:8090///'), 'http://10.0.0.5:8090');
    expect(AppState.normalizeServerUrl(''), '');
  });

  group('connection test', () {
    test('succeeds and says what is waiting', () async {
      final (s, srv) = await make();
      srv.add(1, ranked);
      final c = await s.testReplayServer();
      expect(c.ok, isTrue);
      expect(c.message, contains('1 round'));
    });

    test('wrong, upload and missing tokens, and a dead server, each get a clear message', () async {
      var (s, _) = await make(token: 'nope');
      expect((await s.testReplayServer()).message, contains('rejected the token'));
      (s, _) = await make(token: 'upload-tok');
      expect((await s.testReplayServer()).message, contains('read token'));
      (s, _) = await make(token: '');
      expect((await s.testReplayServer()).message, contains('Enter the server address'));
      final (d, srv) = await make();
      srv.down = true;
      expect((await d.testReplayServer()).message, contains('Could not reach'));
    });

    test('a plain http address explains why it fails', () async {
      final (s, srv) = await make();
      await s.saveReplayServer('http://10.0.0.5:8090', 'read-tok');
      srv.down = true;
      expect((await s.testReplayServer()).message, contains('https://'));
    });
  });

  group('sync', () {
    test('downloads rounds in both parser formats, saves them, then deletes the .rec files', () async {
      final (s, srv) = await make();
      srv.add(1, ranked); // r6-dissect output wrapped in a header
      srv.add(2, quick); // the real flat output of the server's parser
      srv.add(3, arenyzeRound); // the Arenyze fallback format
      final r = await s.syncReplayServer();
      expect(r.message, isNull);
      expect(r.added, 3);
      expect(s.replays.length, 3);
      expect(s.replays.map((x) => x.source).toSet(), {'dissect', 'arenyze'});
      expect(srv.acked, [1, 2, 3]);
      expect(r.freedBytes, 27000000);
      expect(r.summary, contains('freed 25.7 MB'));
      expect(s.pendingAcks, isEmpty);
      // The delete call comes after every round was saved; only read-only requests (population table, clips) follow it.
      expect(srv.log.where((l) => l != 'GET /v1/population' && l != 'GET /v1/highlights').last, 'POST /v1/ack');
      expect(srv.log.indexOf('POST /v1/ack'), greaterThan(srv.log.lastIndexOf(srv.log.lastWhere((l) => l.startsWith('GET /v1/rounds')))));
    });

    test('exact kill times survive the trip from the real parser', () async {
      final (s, srv) = await make();
      srv.add(1, quick);
      await s.syncReplayServer();
      expect(s.replays.single.timed, isTrue);
      expect(s.replays.single.events.where((e) => e.isKill).length, 8);
    });

    test('rounds are saved on the phone before the server is told to delete', () async {
      final (s, srv) = await make();
      srv.add(1, ranked);
      var savedWhenAcked = -1;
      final prefs = await SharedPreferences.getInstance();
      final inner = MockClient((r) async {
        if (r.url.path == '/v1/ack') savedWhenAcked = (jsonDecode(prefs.getString('replays') ?? '[]') as List).length;
        return srv.handle(r);
      });
      final s2 = AppState(prefs, httpClient: inner);
      await s2.saveReplayServer('replays.example.com', 'read-tok');
      await s2.syncReplayServer();
      expect(savedWhenAcked, 1, reason: 'the data must already be on disk when the delete is requested');
    });

    test('a second sync asks only for what is new', () async {
      final (s, srv) = await make();
      srv.add(1, ranked);
      await s.syncReplayServer();
      srv.log.clear();
      srv.add(2, quick);
      final r = await s.syncReplayServer();
      expect(r.added, 1);
      expect(srv.log.where((l) => l == 'GET /v1/rounds').length, 1);
      expect(srv.acked, [1, 2]);
      expect((await s.syncReplayServer()).summary, 'Nothing new on the server.');
    });

    test('many rounds are fetched across pages', () async {
      final (s, srv) = await make();
      for (var i = 1; i <= 60; i++) {
        final j = jsonDecode(jsonEncode(ranked)) as Map<String, dynamic>;
        (j['header'] as Map)['roundNumber'] = i;
        srv.add(i, j);
      }
      final r = await s.syncReplayServer();
      expect(r.added, 60);
      expect(srv.log.where((l) => l == 'GET /v1/rounds').length, 3, reason: '25 + 25 + 10');
      expect(srv.acked.length, 60);
    });

    test('rounds already on the phone are still acknowledged so the server can free the space', () async {
      final (s, srv) = await make();
      await s.importReplayJson(jsonEncode(ranked));
      srv.add(1, ranked);
      final r = await s.syncReplayServer();
      expect([r.added, r.duplicates], [0, 1]);
      expect(srv.acked, [1]);
    });

    test('files the server could not parse are reported and never acknowledged', () async {
      final (s, srv) = await make();
      srv.add(1, ranked);
      srv.add(2, {}, status: 'failed');
      srv.add(3, {'garbage': true});
      final r = await s.syncReplayServer();
      expect([r.added, r.failedOnServer, r.unreadable], [1, 1, 1]);
      expect(srv.acked, [1], reason: 'the failed and unreadable ones keep their .rec on the server');
      expect(r.summary, contains('could not read'));
    });

    test('if the delete call fails the data is kept and the delete is retried next time', () async {
      final (s, srv) = await make();
      srv.add(1, ranked);
      srv.ackStatus = 500;
      final first = await s.syncReplayServer();
      expect(first.added, 1);
      expect(first.pendingAcks, 1);
      expect(s.replays.length, 1, reason: 'no data is lost');
      expect(srv.acked, isEmpty);
      srv.ackStatus = 200;
      final again = await s.syncReplayServer();
      expect(srv.acked, [1]);
      expect(again.pendingAcks, 0);
      expect(again.freedBytes, 9000000);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('rs.acks'), isNull);
    });

    test('pending deletes survive a restart', () async {
      final (s, srv) = await make();
      srv.add(1, ranked);
      srv.ackStatus = 500;
      await s.syncReplayServer();
      final restarted = AppState(await SharedPreferences.getInstance(), httpClient: MockClient(srv.handle));
      expect(restarted.pendingAcks, [1]);
      expect(restarted.replayCursor, 1);
      expect(restarted.replays.length, 1);
    });

    test('errors stop the sync with a clear message and change nothing', () async {
      var (s, srv) = await make(token: 'nope');
      srv.add(1, ranked);
      var r = await s.syncReplayServer();
      expect(r.message, contains('rejected the token'));
      expect(s.replays, isEmpty);
      (s, srv) = await make();
      srv.down = true;
      r = await s.syncReplayServer();
      expect(r.message, contains('Could not reach'));
    });

    test('not configured, and automatic syncs are throttled', () async {
      SharedPreferences.setMockInitialValues({});
      final blank = AppState(await SharedPreferences.getInstance());
      expect((await blank.syncReplayServer()).message, contains('Set up'));
      final (s, srv) = await make();
      await s.syncReplayServer();
      srv.log.clear();
      expect((await s.syncReplayServer(auto: true)).skipped, isTrue);
      expect(srv.log, isEmpty, reason: 'an automatic sync within 3 minutes makes no request');
      expect((await s.syncReplayServer()).skipped, isFalse, reason: 'a manual sync always runs');
    });

    test('a different server starts from the beginning', () async {
      final (s, srv) = await make();
      srv.add(1, ranked);
      await s.syncReplayServer();
      expect(s.replayCursor, 1);
      await s.saveReplayServer('other.example.com', 'read-tok');
      expect(s.replayCursor, 0);
    });
  });

  // Runs against a real deployed server only when R6_LIVE_URL and R6_LIVE_READ are set.
  test('live server', () async {
    final url = Platform.environment['R6_LIVE_URL'], tok = Platform.environment['R6_LIVE_READ'];
    if (url == null || tok == null) return;
    SharedPreferences.setMockInitialValues({'apiKey': 'k', 'username': 'x'});
    final s = AppState(await SharedPreferences.getInstance());
    await s.saveReplayServer(url, tok);
    final c = await s.testReplayServer();
    // ignore: avoid_print
    print('LIVE connection: ${c.message}');
    expect(c.ok, isTrue, reason: c.message);
    final r = await s.syncReplayServer();
    // ignore: avoid_print
    print('LIVE sync: ${r.summary} | rounds on phone: ${s.replays.length} | timed: ${s.replays.where((x) => x.timed).length}');
    expect(r.message, isNull);
  });
}
