import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r6_coach/analytics/replay_stats.dart';
import 'package:r6_coach/data/replay.dart';

String raw(String n) => File('test/fixtures/replays/$n').readAsStringSync();
ReplayRound dissect(String n) => parseReplayJson(raw(n)).rounds.single;

void main() {
  final names = ['ranked_1.rec.json', 'ranked_2.rec.json', 'quick_1.rec.json', 'attacker_recorder_site_test.rec.json', 'defender_recorder_site_test_1.rec.json', 'custom_1.rec.json'];

  group('parsing real r6-dissect output', () {
    test('every fixture parses with players, teams and kills', () {
      for (final n in names) {
        final res = parseReplayJson(raw(n));
        expect(res.errors, 0, reason: n);
        final r = res.rounds.single;
        expect(r.players.length, 10, reason: n);
        expect(r.teams.length, 2, reason: n);
        expect(r.teams.where((t) => t.won).length, 1, reason: '$n has exactly one winning team');
        expect(r.events.where((e) => e.isKill), isNotEmpty, reason: n);
        expect(r.timed, isTrue, reason: 'dissect timings are real');
        final expected = (jsonDecode(raw(n)) as Map)['matchFeedback'] as List;
        expect(r.events.where((e) => e.isKill).length, expected.where((e) => (e as Map)['type']['name'] == 'Kill').length, reason: n);
      }
    });

    test('kill timer counts down in event order', () {
      for (final n in names) {
        final t = [for (final e in dissect(n).events) if (e.isKill) e.remaining!];
        for (var i = 1; i < t.length; i++) {
          expect(t[i] <= t[i - 1], isTrue, reason: '$n: kill $i at ${t[i]} after ${t[i - 1]}');
        }
      }
    });

    test('ranked_2 header facts', () {
      final r = dissect('ranked_2.rec.json');
      expect(r.map, 'Bank');
      expect(r.matchType, 'Ranked');
      expect(r.number, 5);
      expect(r.site, '1F Staff Room, 1F Open Area');
      expect(r.matchId, '86bff96d-ce91-481c-95d7-41bb7eb0a940');
      expect(r.teams[0].role, 'Defense');
      expect(r.teams[0].won, isTrue);
      expect(r.teams[0].winCondition, 'KilledOpponents');
      expect(r.players.firstWhere((p) => p.name == 'Hibana'.replaceAll('Hibana', 'Knoblauch.SOOS')).operator, 'Hibana');
    });

    test('the oldest flat format still parses', () {
      final res = parseReplayJson(raw('unranked_R01_flat.json'));
      expect(res.rounds, hasLength(1));
      expect(res.rounds.single.map, isNotEmpty);
    });
  });

  group('round analysis (ranked_2, read off the file)', () {
    final r = dissect('ranked_2.rec.json');

    test('opening duel: first kill is SZIATEBUZI3156 on Metaxa.SOOS', () {
      expect(analyzeRound(r, 'SZIATEBUZI3156').opening, Opening.kill);
      expect(analyzeRound(r, 'Metaxa.SOOS').opening, Opening.death);
      expect(analyzeRound(r, 'Hellcat352020').opening, Opening.none);
    });

    test('kills and headshots', () {
      final h = analyzeRound(r, 'Hellcat352020');
      expect(h.kills, 2);
      expect(h.headshots, 1);
      expect(h.survived, isTrue);
      expect(h.kost, isTrue);
    });

    test('strict trades: both defenders who died were avenged within 5 seconds', () {
      final s = analyzeRound(r, 'SZIATEBUZI3156'); // killed by Vanille at 0:37, Vanille killed by Luckeyleader at 0:35
      expect(s.died, isTrue);
      expect(s.traded, isTrue);
      expect(analyzeRound(r, 'DejaVu_BTW').traded, isTrue); // killer Knoblauch died at the same second
      expect(analyzeRound(r, 'Metaxa.SOOS').traded, isFalse); // nobody avenged the first attacker
    });

    test('KOST: a dead player with no kill and no trade has none', () {
      final m = analyzeRound(r, 'Metaxa.SOOS');
      expect(m.kills, 0);
      expect(m.survived, isFalse);
      expect(m.kost, isFalse);
    });

    test('side and result come from the player\'s team', () {
      final d = analyzeRound(r, 'Luckeyleader');
      expect(d.role, 'Defense');
      expect(d.won, isTrue);
      final a = analyzeRound(r, 'Chili.SOOS');
      expect(a.role, 'Attack');
      expect(a.won, isFalse);
    });

    test('a name that is not in the round is reported as absent, case-insensitively matched otherwise', () {
      expect(analyzeRound(r, 'nobody').present, isFalse);
      expect(analyzeRound(r, 'hellcat352020').present, isTrue);
    });

    test('team sums agree with the kill list', () {
      final board = leaderboard([r]);
      final totalKills = board.fold<int>(0, (s, p) => s + p.kills);
      expect(totalKills, r.events.where((e) => e.isKill).length);
      expect(board.fold<int>(0, (s, p) => s + p.deaths), totalKills);
    });
  });

  group('Arenyze upload of the same replay', () {
    final upload = jsonDecode(raw('arenyze_upload_quick_1.json')) as Map<String, dynamic>;
    final a = parseReplayJson(raw('arenyze_upload_quick_1.json')).rounds.single;
    final d = dissect('quick_1.rec.json');

    test('same kills in the same order with the same headshots as dissect', () {
      List<String> seq(ReplayRound r) => [for (final e in r.events) if (e.isKill) '${e.actor}>${e.target}${e.headshot ? '!' : ''}'];
      expect(seq(a), seq(d));
      expect(a.matchId, d.matchId);
      expect(a.map, d.map);
      expect(a.site, d.site);
    });

    test('its event times are dropped because they are all the end of the round', () {
      expect(a.timed, isFalse);
      expect(a.events.every((e) => e.remaining == null), isTrue);
      expect(d.timed, isTrue);
    });

    test('untimed rounds give a KOST lower bound and avenged-by-order instead of strict trades', () {
      final s = summarize([analyzeRound(a, 'A-._')]); // died to itsrafaelgotu, who was then killed by a teammate
      expect(s.deaths, 1);
      expect(s.avengedDeaths, 1);
      expect(s.tradedDeaths, 0);
      expect(s.kostIsLowerBound, isTrue);
      expect(summarize([analyzeRound(d, 'A-._')]).kostIsLowerBound, isFalse);
    });

    test('per-player assists come from Arenyze stats and kills agree with the event list', () {
      final kab = analyzeRound(a, 'Kabelband');
      expect(kab.player!.assists, 1);
      expect(kab.kills, kab.player!.kills);
      expect(summarize([kab]).assists, 1);
      expect(summarize([analyzeRound(d, 'Kabelband')]).assists, isNull);
    });

    test('quota and match fields are present in the response', () {
      expect((upload['quota'] as Map)['limit'], 15);
      expect((upload['match'] as Map)['replay_match_id'], d.matchId);
    });
  });

  group('robustness', () {
    test('bad input is counted, not thrown', () {
      expect(parseReplayJson('not json').errors, 1);
      expect(parseReplayJson('{}').rounds, isEmpty);
      final mixed = parseReplayJson('[${raw('ranked_1.rec.json')}, {"x": 1}, 5]');
      expect(mixed.rounds, hasLength(1));
      expect(mixed.errors, 2);
    });

    test('storage round trip keeps everything the analysis needs', () {
      for (final n in names) {
        final r = dissect(n);
        final back = ReplayRound.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
        expect(back.key, r.key);
        expect(back.timed, r.timed);
        expect(back.events.length, r.events.length);
        expect(summarize([analyzeRound(back, r.players.first.name)]).kills, summarize([analyzeRound(r, r.players.first.name)]).kills);
      }
    });

    test('team kills are not kills or openings', () {
      const ev = [ReplayEvent(type: 'Kill', actor: 'A', target: 'B'), ReplayEvent(type: 'Kill', actor: 'C', target: 'A')];
      const r = ReplayRound(
        matchId: 'm', number: 1, map: 'Bank', matchType: 'Ranked', source: 'dissect',
        teams: [ReplayTeam(role: 'Attack', score: 0, won: false), ReplayTeam(role: 'Defense', score: 1, won: true)],
        players: [ReplayPlayer(name: 'A', team: 0), ReplayPlayer(name: 'B', team: 0), ReplayPlayer(name: 'C', team: 1)],
        events: ev,
      );
      final a = analyzeRound(r, 'A');
      expect(a.kills, 0);
      expect(a.teamKills, 1);
      expect(a.opening, Opening.death, reason: 'the team kill is skipped; C killing A is the opening duel');
    });

    test('site stats group by map, site and side', () {
      final mine = [for (final n in names) analyzeRound(dissect(n), dissect(n).players.first.name)];
      final sites = siteStats(mine);
      expect(sites.fold<int>(0, (s, x) => s + x.rounds), mine.where((m) => m.present && m.round.site != null).length);
      expect(sites.every((s) => s.wins <= s.rounds), isTrue);
    });

    test('matches group by id with rounds in order', () {
      final all = [for (final n in names) dissect(n)];
      final groups = groupMatches(all);
      expect(groups.fold<int>(0, (s, g) => s + g.length), all.length);
      for (final g in groups) {
        for (var i = 1; i < g.length; i++) {
          expect(g[i].number >= g[i - 1].number, isTrue);
        }
      }
    });
  });
}
