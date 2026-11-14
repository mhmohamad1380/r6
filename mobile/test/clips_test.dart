import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:r6_coach/app_state.dart';
import 'package:r6_coach/data/highlight.dart';
import 'package:r6_coach/features/clips/clips.dart';
import 'package:r6_coach/features/common/common.dart';
import 'package:r6_coach/core/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> clip(String id, int seq, {String type = 'multikill', int score = 7, int kills = 2, String? title, String visibility = 'private', bool thumb = false}) => {
      'id': id, 'match_id': 'm-1', 'round': 4, 'type': type, 'tags': [type], 'score': score, 'clutch_vs': type == 'clutch' ? 2 : 0, 'won': true,
      'side': 'Attack', 'operator': 'Ash', 'map': 'Bank', 'mode': 'Ranked', 'played_at': '2026-10-30T22:54:35Z',
      'kills': [for (var i = 0; i < kills; i++) {'t': 40.0 + i, 'clock': 140 - i, 'victim': 'E$i', 'victim_operator': 'Jager', 'headshot': i == 0, 'post_plant': false}],
      'clip': {'from': 35.0, 'to': 45.0, 'approx': false}, 'title': title, 'visibility': visibility, 'status': 'ready', 'size': 5 << 20, 'duration': 18.0,
      'createdAt': '2026-11-10T10:00:00Z', 'seq': seq, 'videoUrl': '/v1/highlights/$id/video', 'thumbnailUrl': thumb ? '/v1/highlights/$id/thumbnail' : null,
    };

/// The replay server's clip API, as the real one answers it: a feed by change number with deletions, edits, share, delete.
class ClipServer {
  final feed = <Map<String, dynamic>>[];
  final log = <String>[];
  int seq = 0;

  void add(Map<String, dynamic> c) => feed.add({...c, 'seq': ++seq});
  Map<String, dynamic>? find(String id) => feed.lastWhere((x) => x['id'] == id && x['deleted'] != true, orElse: () => {});

  Future<http.Response> handle(http.Request r) async {
    log.add('${r.method} ${r.url.path}${r.url.query.isEmpty ? '' : '?${r.url.query}'}');
    if (r.headers['Authorization'] != 'Bearer read-tok') return http.Response('{}', 401);
    final p = r.url.path;
    if (p == '/v1/rounds') return http.Response('{"rounds":[],"nextCursor":0,"hasMore":false}', 200);
    if (p == '/v1/highlights' && r.method == 'GET') {
      final after = int.parse(r.url.queryParameters['after'] ?? '0'), limit = int.parse(r.url.queryParameters['limit'] ?? '50');
      final rows = feed.where((x) => (x['seq'] as int) > after).toList();
      final page = rows.take(limit).toList();
      return http.Response(jsonEncode({'highlights': page, 'nextCursor': page.isEmpty ? after : page.last['seq'], 'hasMore': rows.length > limit, 'storage': {'usedBytes': 10 << 20, 'quotaBytes': 4 << 30}}), 200);
    }
    final m = RegExp(r'^/v1/highlights/([^/]+)(/share)?$').firstMatch(p);
    if (m != null) {
      final id = m.group(1)!;
      final cur = find(id);
      if (cur == null || cur.isEmpty) return http.Response('{"detail":"No such clip."}', 404);
      if (r.method == 'PATCH') {
        final b = jsonDecode(r.body) as Map<String, dynamic>;
        add({...cur, if (b.containsKey('title')) 'title': (b['title'] as String).isEmpty ? null : b['title'], if (b.containsKey('visibility')) 'visibility': b['visibility']});
        return http.Response(jsonEncode(feed.last), 200);
      }
      if (r.method == 'POST' && m.group(2) != null) {
        add({...cur, 'visibility': 'unlisted'});
        return http.Response(jsonEncode({'id': id, 'videoUrl': '/v1/highlights/$id/video?exp=1&sig=abc', 'thumbnailUrl': null}), 200);
      }
      if (r.method == 'DELETE') {
        feed.add({'id': id, 'deleted': true, 'seq': ++seq});
        return http.Response(jsonEncode({'id': id, 'deleted': true, 'freedBytes': 5 << 20}), 200);
      }
    }
    return http.Response('{}', 404);
  }
}

Future<(AppState, ClipServer)> make({Map<String, Object> prefs = const {}}) async {
  final server = ClipServer();
  SharedPreferences.setMockInitialValues({'username': 'cyruson1001', 'onboarded': true, ...prefs});
  final s = AppState(await SharedPreferences.getInstance(), httpClient: MockClient(server.handle));
  await s.saveReplayServer('https://r6.example.test', 'read-tok');
  return (s, server);
}

void main() {
  test('a clip reads the server JSON and names itself', () {
    expect(Highlight.fromJson(clip('a', 1)).label, '2K');
    expect(Highlight.fromJson(clip('a', 1, type: 'clutch', kills: 3)).label, 'Clutch 1v2 · 3K');
    expect(Highlight.fromJson(clip('a', 1, type: 'ace', kills: 5)).label, 'Ace');
    expect(Highlight.fromJson(clip('a', 1, type: 'entry', kills: 1)).label, 'Entry kill');
    expect(Highlight.fromJson(clip('a', 1)).displayTitle, '2K on Bank');
    expect(Highlight.fromJson(clip('a', 1, title: 'My best')).displayTitle, 'My best');
    final back = Highlight.fromJson(Highlight.fromJson(clip('a', 1, thumb: true)).toJson());
    expect(back.kills.length, 2);
    expect(back.thumbnailUrl, '/v1/highlights/a/thumbnail');
    expect(back.kills.first.headshot, isTrue);
  });

  test('sync follows the feed: new clips, edits and deletions, in pages, and keeps them for offline', () async {
    final (s, server) = await make();
    for (var i = 0; i < 120; i++) {
      server.add(clip('c$i', 0, score: i % 9));
    }
    await s.syncReplayServer();
    expect(s.highlights.length, 120, reason: 'two pages of 100');
    expect(s.highlights.first.id, 'c119', reason: 'newest upload first');
    expect(s.clipsQuotaBytes, 4 << 30);
    final calls = server.log.where((l) => l.startsWith('GET /v1/highlights')).length;
    expect(calls, 2);

    server.add({...clip('c5', 0), 'title': 'Renamed on the web'});
    server.feed.add({'id': 'c7', 'deleted': true, 'seq': ++server.seq});
    await s.syncReplayServer();
    expect(s.highlights.length, 119);
    expect(s.highlights.any((h) => h.id == 'c7'), isFalse);
    expect(s.highlights.firstWhere((h) => h.id == 'c5').title, 'Renamed on the web');
    expect(server.log.last, contains('after=120'), reason: 'only what changed since the last sync is asked for');
    expect(s.hlCursor, 122);

    // A new start of the app shows the same list before any network.
    final again = AppState(await SharedPreferences.getInstance(), httpClient: MockClient((_) async => throw Exception('offline')));
    expect(again.highlights.length, 119);
    expect(again.hlCursor, 122);
  });

  test('rename, share, make private and delete go to the server and update the list', () async {
    final (s, server) = await make();
    server.add(clip('a', 0));
    server.add(clip('b', 0));
    await s.syncReplayServer();
    expect(await s.renameHighlight('a', '  Clean 2K  '), isNull);
    expect(s.highlights.firstWhere((h) => h.id == 'a').title, 'Clean 2K');
    final link = await s.shareHighlight('a');
    expect(link.url, 'https://r6.example.test/v1/highlights/a/video?exp=1&sig=abc');
    expect(s.highlights.firstWhere((h) => h.id == 'a').shared, isTrue);
    expect(await s.setHighlightPrivate('a'), isNull);
    expect(s.highlights.firstWhere((h) => h.id == 'a').shared, isFalse);
    expect(await s.deleteHighlight('b'), isNull);
    expect(s.highlights.map((h) => h.id), ['a']);
    expect(server.log.where((l) => !l.startsWith('GET')).toList(), ['PATCH /v1/highlights/a', 'POST /v1/highlights/a/share', 'PATCH /v1/highlights/a', 'DELETE /v1/highlights/b']);
    expect(await s.renameHighlight('zzz', 'x'), 'That clip is no longer on the server.');
  });

  test('switching to another server forgets the old one\'s clips', () async {
    final (s, server) = await make();
    server.add(clip('a', 0));
    await s.syncReplayServer();
    expect(s.highlights, isNotEmpty);
    await s.saveReplayServer('https://other.example.test', 'read-tok');
    expect(s.highlights, isEmpty);
    expect(s.hlCursor, 0);
  });

  Future<void> pump(WidgetTester t, Widget w, {double width = 360, double scale = 1.0}) async {
    t.view.physicalSize = Size(width * 3, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 800), textScaler: TextScaler.linear(scale)),
        child: AppNav(goTab: (_) {}, child: Scaffold(body: w)),
      ),
    ));
    await t.pump(const Duration(milliseconds: 300));
  }

  for (final (w, sc) in [(320.0, 1.0), (360.0, 1.3), (411.0, 1.0)]) {
    testWidgets('the clip list: filters, sorting and storage, with no overflow (${w.toInt()}dp, text x$sc)', (t) async {
      final (s, server) = await make();
      server.add(clip('ace', 0, type: 'ace', kills: 5, score: 33, title: 'A very long name that someone gave this clip so it has to be cut short'));
      server.add(clip('k2', 0, score: 7));
      server.add(clip('hs', 0, type: 'headshot', kills: 1, score: 2));
      await t.runAsync(() => s.syncReplayServer());
      await pump(t, ListView(padding: const EdgeInsets.all(16), children: [ClipsSection(state: s)]), width: w, scale: sc);
      expect(t.takeException(), isNull);
      expect(find.text('3 clips'), findsOneWidget);
      expect(find.text('Aces'), findsOneWidget);
      expect(find.text('Clutches'), findsNothing, reason: 'only filters that have clips');
      await t.ensureVisible(find.text('Headshots'));
      await t.pump();
      await t.tap(find.text('Headshots'));
      await t.pump();
      expect(find.text('1 clip'), findsOneWidget);
      await t.ensureVisible(find.text('All'));
      await t.pump();
      await t.tap(find.text('All'));
      await t.pump();
      // Best first: the ace leads; newest first: the headshot (uploaded last) leads.
      final firstTitle = t.widgetList<Text>(find.byType(Text)).map((x) => x.data).firstWhere((d) => d != null && (d.contains(' on Bank') || d.startsWith('A very')));
      expect(firstTitle, startsWith('A very'));
      await t.tap(find.text('Best first'));
      await t.pump();
      expect(find.text('Newest first'), findsOneWidget);
      final newest = t.widgetList<Text>(find.byType(Text)).map((x) => x.data).firstWhere((d) => d != null && (d.contains(' on Bank') || d.startsWith('A very')));
      expect(newest, 'Headshot on Bank');
      expect(find.text('Server storage: 10 MB of 4.0 GB used'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('no server, and no clips yet: each says what to do', (t) async {
    SharedPreferences.setMockInitialValues({'username': 'x', 'onboarded': true});
    final bare = AppState(await SharedPreferences.getInstance());
    await pump(t, ListView(children: [ClipsSection(state: bare)]));
    expect(find.text('Connect to the server'), findsOneWidget);
    final (s, _) = await make();
    await pump(t, ListView(children: [ClipsSection(state: s)]));
    expect(find.text('No clips yet'), findsOneWidget);
    expect(find.textContaining('Record live clips while I play'), findsOneWidget);
  });

  testWidgets('the player screen: details, rename, share and delete (the video itself needs a phone)', (t) async {
    final (s, server) = await make();
    server.add(clip('a', 0));
    await t.runAsync(() => s.syncReplayServer());
    await pump(t, Builder(builder: (c) => Center(child: ElevatedButton(onPressed: () => openClip(c, s, s.highlights.first), child: const Text('open')))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('2K on Bank'), findsWidgets);
    expect(find.text('What happened'), findsOneWidget);
    expect(find.text('E0 (Jager)'), findsOneWidget);
    expect(find.text('headshot'), findsOneWidget);

    await t.tap(find.text('Rename'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'Clean 2K');
    await t.tap(find.text('Save'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pumpAndSettle();
    expect(find.text('Clean 2K'), findsWidgets);

    await t.tap(find.text('Copy share link'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pumpAndSettle();
    expect(find.text('Link copied'), findsOneWidget);
    Navigator.of(t.element(find.text('Link copied'))).pop();
    await t.pumpAndSettle();
    expect(find.text('Make private'), findsOneWidget);

    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, 'Delete'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pumpAndSettle();
    expect(find.text('open'), findsOneWidget, reason: 'back on the list after deleting');
    expect(s.highlights, isEmpty);
  });
}
