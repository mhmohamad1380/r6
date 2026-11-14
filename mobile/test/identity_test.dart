import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:r6_coach/analytics/identity.dart';
import 'package:r6_coach/app_state.dart';
import 'package:r6_coach/data/replay.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/synthetic_replays.dart';

Future<AppState> app(List<Object> rounds, {Map<String, Object> prefs = const {}}) async {
  SharedPreferences.setMockInitialValues({'replays': jsonEncode(rounds), ...prefs});
  return AppState(await SharedPreferences.getInstance());
}

void main() {
  final base = asPlayer(richSet(), 'cyruson1001');

  group('who the replays belong to', () {
    test('the recording profile names you, with no name typed and no key', () {
      final d = detectPlayer(recordedBy(base, 'cyruson1001'));
      expect(d?.name, 'cyruson1001');
      expect(d?.how, 'recorded');
    });

    test('it works from a single match, where ten players are equally present', () {
      final one = recordedBy(asPlayer(series(1, 6, (_) => true), 'cyruson1001'), 'cyruson1001');
      expect(detectPlayer(one)?.name, 'cyruson1001');
    });

    test('without a recording profile (older saved rounds) the one person in every round of several matches is you', () {
      // Real matches have different opponents and teammates each time; only you are in all of them.
      final varied = [
        for (final r in base)
          () {
            final j = Map<String, dynamic>.from(r.toJson());
            j['pl'] = [for (final p in j['pl'] as List) [...(p as List)]..[0] = p[0] == 'cyruson1001' ? p[0] : '${p[0]}-${r.matchId}'];
            return ReplayRound.fromJson(j);
          }(),
      ];
      final d = detectPlayer(varied);
      expect(d?.name, 'cyruson1001');
      expect(d?.how, 'common');
    });

    test('it will not guess when it cannot tell', () {
      expect(detectPlayer(recordedBy(asPlayer(series(1, 6, (_) => true), 'x'), 'x', withRecorder: false)), isNull, reason: 'one match, no recorder: ten equal candidates');
      expect(detectPlayer(recordedBy(base, 'cyruson1001', withRecorder: false)), isNull, reason: 'the same ten players in every match: a party that always plays together');
      expect(detectPlayer(const []), isNull);
    });

    test('a rename follows the newest replay', () {
      final old = recordedBy(asPlayer(series(2, 6, (_) => true), 'OldName'), 'OldName');
      // Same profile id, new name in the newest rounds.
      final j = [for (final r in old) Map<String, dynamic>.from(r.toJson())];
      for (final m in j) {
        m['pl'] = [for (final p in m['pl'] as List) [...(p as List)]..[0] = (p[3] == 'profile-${'OldName'.hashCode.toUnsigned(32)}' ? 'NewName' : p[0])];
      }
      final renamed = recordedBy(old, 'OldName');
      expect(detectPlayer(renamed)?.name, 'OldName');
    });

    test('appearsIn ignores case and blanks', () {
      expect(appearsIn(base, 'CYRUSON1001'), isTrue);
      expect(appearsIn(base, 'nobody'), isFalse);
      expect(appearsIn(base, '  '), isFalse);
    });
  });

  group('the app with replays only', () {
    test('no name and no key: the replays say who you are, and the app is usable', () async {
      final s = await app([for (final r in recordedBy(base, 'cyruson1001')) r.toJson()]);
      expect(s.hasStatsKey, isFalse);
      expect(s.hasAccount, isTrue, reason: 'identified by the replays');
      expect(s.playerName, 'cyruson1001');
      expect(s.username, 'cyruson1001', reason: 'kept, so Profile shows it and it survives a restart');
      expect(s.nameFromReplays, isFalse, reason: 'it is the saved name now');
    });

    test('a name that is not in the replays is not used for the analysis; the recorder is', () async {
      final s = await app([for (final r in recordedBy(base, 'cyruson1001')) r.toJson()], prefs: {'username': 'someone_else'});
      expect(s.playerName, 'cyruson1001');
      expect(s.username, 'someone_else', reason: 'the saved setting is not overwritten behind your back');
    });

    test('a name that is in the replays wins', () async {
      final s = await app([for (final r in recordedBy(base, 'cyruson1001')) r.toJson()], prefs: {'username': 'cyruson1001'});
      expect(s.playerName, 'cyruson1001');
      expect(s.nameFromReplays, isFalse);
    });

    test('importing replays with no name set keeps the name that was found', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(await SharedPreferences.getInstance());
      expect(s.hasAccount, isFalse);
      // A real r6-dissect file: its header says which profile recorded it.
      final text = File('test/fixtures/replays/ranked_1.rec.json').readAsStringSync();
      final header = (jsonDecode(text) as Map<String, dynamic>)['header'] as Map<String, dynamic>? ?? jsonDecode(text) as Map<String, dynamic>;
      final expected = [for (final p in header['players'] as List) if ((p as Map)['profileID'] == header['recordingProfileID']) p['username'] as String].single;
      final res = await s.importReplayJson(text);
      expect(res.added, greaterThan(0));
      await Future<void>.delayed(Duration.zero);
      expect(s.username, expected);
      expect((await SharedPreferences.getInstance()).getString('username'), expected, reason: 'saved, so it survives a restart');
    });

    test('changing your name does not delete your replays', () async {
      final s = await app([for (final r in recordedBy(base, 'cyruson1001')) r.toJson()], prefs: {'username': 'cyruson1001'});
      final before = s.replays.length;
      expect(before, greaterThan(0));
      await s.saveSettings(key: '', name: 'another_name', plat: 'uplay');
      expect(s.replays.length, before, reason: 'a replay holds ten players, so it is not tied to one account');
    });

    test('nothing calls the network without a key', () async {
      var calls = 0;
      SharedPreferences.setMockInitialValues({'username': 'cyruson1001'});
      final s = AppState(await SharedPreferences.getInstance(), httpClient: MockClient((r) async {
        calls++;
        return http.Response('{}', 200);
      }));
      await s.refresh(force: true, bypassGap: true);
      expect(calls, 0);
    });
  });
}

