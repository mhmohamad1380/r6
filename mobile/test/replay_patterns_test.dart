import 'package:flutter_test/flutter_test.dart';
import 'package:r6_coach/analytics/insights.dart' show Tone;
import 'package:r6_coach/analytics/replay_patterns.dart';
import 'package:r6_coach/analytics/replay_stats.dart';
import 'package:r6_coach/data/replay.dart';

// A tiny round builder: me on team 0 with four mates, five enemies on team 1.
ReplayRound round({
  String match = 'm1',
  int n = 0,
  bool attack = true,
  bool won = true,
  int myScore = 1,
  int theirScore = 0,
  List<ReplayEvent> events = const [],
  List<String> mates = const ['a1', 'a2', 'a3', 'a4'],
  List<String> enemyOps = const ['Jager', 'Mute', 'Smoke', 'Bandit', 'Kapkan'],
  String? spawn,
  DateTime? at,
  int rpm = 6,
  String? season,
  int? overtimeAt,
}) =>
    ReplayRound(
      matchId: match,
      number: n,
      at: at ?? DateTime.utc(2026, 10, 1, 20, n),
      map: 'Bank',
      matchType: 'Ranked',
      roundsPerMatch: rpm,
      overtimeAt: overtimeAt,
      season: season,
      teams: [
        ReplayTeam(role: attack ? 'Attack' : 'Defense', score: myScore, won: won),
        ReplayTeam(role: attack ? 'Defense' : 'Attack', score: theirScore, won: !won),
      ],
      players: [
        ReplayPlayer(name: 'me', team: 0, operator: 'Ash', profileId: 'me-id', spawn: spawn),
        for (final m in mates) ReplayPlayer(name: m, team: 0, profileId: 'id-$m'),
        for (var i = 0; i < 5; i++) ReplayPlayer(name: 'e$i', team: 1, operator: enemyOps[i], profileId: 'id-e$i'),
      ],
      events: events,
      source: 'dissect',
      planted: events.any((e) => e.isPlant),
      defused: events.any((e) => e.isDefuse),
    );

ReplayEvent kill(String a, String t, {int? at, bool hs = false}) => ReplayEvent(type: 'Kill', actor: a, target: t, remaining: at, headshot: hs);
List<MyRound> mine(List<ReplayRound> rs) => [for (final r in rs) analyzeRound(r, 'me')];

void main() {
  test('a plant is not a defuse: DefuserPlantComplete contains "Defus" too', () {
    const plant = ReplayEvent(type: 'DefuserPlantComplete', actor: 'me');
    const disable = ReplayEvent(type: 'DefuserDisableComplete', actor: 'e1');
    expect(plant.isPlant, isTrue);
    expect(plant.isDefuse, isFalse);
    expect(disable.isDefuse, isTrue);
    expect(disable.isPlant, isFalse);
  });

  test('a death with no killer counts as a death', () {
    final m = analyzeRound(round(events: const [ReplayEvent(type: 'Death', actor: 'me', remaining: 40)]), 'me');
    expect(m.died, isTrue);
    expect(m.survived, isFalse);
  });

  test('regular teammates are the ones in two or more matches, and rounds are split by them', () {
    final rs = [
      for (var n = 0; n < 4; n++) round(match: 'm1', n: n, won: n < 3),
      for (var n = 0; n < 4; n++) round(match: 'm2', n: n, won: n < 3),
      for (var n = 0; n < 4; n++) round(match: 'm3', n: n, won: false, mates: const ['x1', 'x2', 'x3', 'x4']),
    ];
    final q = squad(mine(rs));
    expect(q.regulars.map((m) => m.name).toSet(), {'a1', 'a2', 'a3', 'a4'});
    expect(q.withSquad.rounds, 8);
    expect(q.withSquad.wins, 6);
    expect(q.solo.rounds, 4);
    expect(q.solo.wins, 0);
  });

  test('trade partners: who killed my killer, and whose killer I killed', () {
    final rs = [
      round(events: [kill('e1', 'me', at: 100), kill('a1', 'e1', at: 98), kill('e2', 'a2', at: 90), kill('me', 'e2', at: 88)]),
      round(match: 'm2', events: [kill('e1', 'me'), kill('a1', 'e1')]),
    ];
    final q = squad(mine(rs));
    expect(q.regulars.firstWhere((m) => m.name == 'a1').avengedMe, 2);
    expect(q.regulars.firstWhere((m) => m.name == 'a2').iAvenged, 1);
  });

  test('fights by enemy operator count kills both ways and ignore team kills', () {
    final r = round(events: [kill('me', 'e0'), kill('e0', 'me'), kill('e1', 'me'), kill('me', 'a1')]);
    final ops = {for (final o in enemyOperators(mine([r]))) o.op: o};
    expect(ops['Jager']!.kills, 1);
    expect(ops['Jager']!.deaths, 1);
    expect(ops['Mute']!.deaths, 1);
    expect(ops.length, 2);
  });

  test('how a round ended is worked out from what happened', () {
    expect(roundEnd(round(events: [for (var i = 0; i < 5; i++) kill('me', 'e$i')])), RoundEnd.elimination);
    expect(roundEnd(round(won: false, events: [kill('e0', 'a1')])), RoundEnd.time);
    expect(roundEnd(round(events: const [ReplayEvent(type: 'DefuserPlantComplete', actor: 'me')])), RoundEnd.detonated);
    expect(roundEnd(round(won: false, events: const [ReplayEvent(type: 'DefuserPlantComplete', actor: 'me'), ReplayEvent(type: 'DefuserDisableComplete', actor: 'e1')])), RoundEnd.defused);
    // The file's "DefusedBomb" alone does not make a defuse: real files say it far more often than a defuser is disabled.
    const noDisable = ReplayRound(matchId: 'x', number: 0, map: 'Bank', matchType: 'Ranked', source: 'dissect', players: [], events: [], teams: [ReplayTeam(role: 'Attack', score: 0, won: false), ReplayTeam(role: 'Defense', score: 1, won: true, winCondition: 'DefusedBomb')]);
    expect(roundEnd(noDisable), isNot(RoundEnd.defused));
  });

  test('plants: attack rounds with and without, and plants against you', () {
    final p = plants(mine([
      round(events: const [ReplayEvent(type: 'DefuserPlantComplete', actor: 'me')]),
      round(won: false),
      round(attack: false, events: const [ReplayEvent(type: 'DefuserPlantComplete', actor: 'e1'), ReplayEvent(type: 'DefuserDisableComplete', actor: 'a1')]),
    ]));
    expect(p.planted.wins, 1);
    expect(p.notPlanted.rounds, 1);
    expect(p.myPlants, 1);
    expect(p.againstPlanted, 1);
    expect(p.defusedByUs, 1);
  });

  test('pressure: the score before a round, match points, overtime, after a loss', () {
    // First to 4 in a 6-round match. Scores in the file are after the round.
    final rs = [
      round(n: 0, won: false, myScore: 0, theirScore: 1),
      round(n: 1, won: false, myScore: 0, theirScore: 2),
      round(n: 2, won: true, myScore: 1, theirScore: 2),
      round(n: 3, won: true, myScore: 2, theirScore: 2),
      round(n: 4, won: true, myScore: 3, theirScore: 2),
      round(n: 5, won: false, myScore: 3, theirScore: 3),
      round(n: 6, won: true, myScore: 4, theirScore: 3, overtimeAt: 6),
    ];
    final p = pressure(mine(rs));
    expect(p.firstRound.rounds, 1);
    expect(p.firstRound.wins, 0);
    expect(p.ourMatchPoint.rounds, 1, reason: 'round 6 only: 3–2 going in. Round 7 is overtime');
    expect(p.theirMatchPoint.rounds, 0);
    expect(p.overtime.rounds, 1);
    expect(p.overtime.wins, 1);
    expect(p.afterLoss.rounds, 3);
    expect(p.afterLoss.wins, 2);
    expect(p.downTwo, 1);
    expect(p.downTwoWon, 1, reason: '4 rounds won to 3 lost: a comeback');
  });

  test('spawns are counted on attack only, and random spawn gets a readable name', () {
    final s = spawns(mine([round(spawn: 'Main Gate'), round(spawn: 'RANDOM', won: false), round(attack: false, spawn: '1F Lobby')]));
    expect(s.map((x) => x.spawn).toSet(), {'Main Gate', 'Random spawn'});
  });

  test('sittings: matches less than 2 hours apart, and the position of each match in it', () {
    DateTime t(int h, int m) => DateTime.utc(2026, 10, 1, h, m);
    final w = whenYouPlay(mine([round(match: 'a', at: t(18, 0)), round(match: 'b', at: t(18, 40)), round(match: 'c', at: t(19, 20)), round(match: 'd', at: t(23, 0))]));
    expect(w.sessions, 2);
    expect({for (final l in w.byMatchInSession) l.label: l.rounds.length}, {'1st match': 2, '2nd match': 1, '3rd match': 1});
  });

  test('a population table places a value between its percentiles', () {
    final p = Population.fromJson({
      'players': 100,
      'rounds': 300,
      'metrics': {
        'kost': {'n': 100, 'quantiles': [for (var i = 0; i <= 20; i++) i / 20]},
      },
    })!;
    expect(p.percentile('kost', 0.5), closeTo(0.5, 1e-9));
    expect(p.percentile('kost', 0.725), closeTo(0.725, 1e-9));
    expect(p.percentile('kost', -1), 0);
    expect(p.percentile('kost', 2), 1);
    expect(p.percentile('kd', 1), isNull, reason: 'no table, no claim');
  });

  test('findings need enough rounds and never name an operator the reader does not know', () {
    expect(buildPatterns([round()], 'me').findings, isEmpty);
    final rs = [
      for (var i = 0; i < 8; i++) round(match: 'm$i', events: [kill('e0', 'me')], enemyOps: const ['Operator(444310693746)', 'Mute', 'Smoke', 'Bandit', 'Kapkan']),
      for (var i = 0; i < 8; i++) round(match: 'n$i', events: [kill('e0', 'me')], enemyOps: const ['Thorn', 'Mute', 'Smoke', 'Bandit', 'Kapkan']),
    ];
    final p = buildPatterns(rs, 'me');
    expect(p.findings.where((f) => f.id == 'pat-nemesis').map((f) => f.title), ['Thorn beats you more than any other operator']);
    expect(operatorLabel('Operator(444310693746)'), 'New operator (3746)');
    expect(p.findings.every((f) => !f.title.contains('Operator(')), isTrue);
    expect(p.findings.first.tone, Tone.warn, reason: 'what to fix comes before good news');
  });

  test('saved rounds keep the new fields, and old saves still load', () {
    final r = round(spawn: 'Main Gate', season: 'Y11S3_Alpha04', overtimeAt: 6);
    final back = ReplayRound.fromJson(r.toJson());
    expect(back.players.first.spawn, 'Main Gate');
    expect(back.season, 'Y11S3_Alpha04');
    expect(back.overtimeAt, 6);
    final old = r.toJson()
      ..remove('ot')
      ..remove('gv');
    old['pl'] = [for (final p in old['pl'] as List) (p as List).sublist(0, 8)];
    final legacy = ReplayRound.fromJson(old);
    expect(legacy.players.first.spawn, isNull);
    expect(legacy.season, isNull);
  });

  test('dissect JSON with spawn, overtime and season is read', () {
    final r = parseDissectRound({
      'matchID': 'abc', 'roundNumber': 6, 'map': {'name': 'Map(409325881472)'}, 'matchType': {'name': 'Ranked'}, 'overtimeRoundNumber': 6, 'gameVersion': 'Y11S3_Alpha04',
      'teams': [{'role': 'Attack', 'score': 4, 'won': true}, {'role': 'Defense', 'score': 3, 'won': false}],
      'players': [{'username': 'me', 'teamIndex': 0, 'spawn': 'Fountain'}],
      'matchFeedback': [{'type': {'name': 'Death'}, 'username': 'me', 'timeInSeconds': 20}],
    })!;
    expect(r.map, 'Villa');
    expect(r.overtime, isTrue);
    expect(r.season, 'Y11S3_Alpha04');
    expect(r.players.first.spawn, 'Fountain');
    expect(r.events.single.isDeath, isTrue);
  });
}
