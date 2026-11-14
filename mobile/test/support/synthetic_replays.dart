import 'package:r6_coach/data/replay.dart';

/// One scripted kill: [actor] kills [target] with [remaining] seconds left on the round clock.
class K {
  const K(this.actor, this.target, this.remaining, {this.hs = false});
  final String actor, target;
  final int? remaining;
  final bool hs;
}

const mine = 'A';
const _team0 = ['A', 'B', 'C', 'D', 'E'];
const _team1 = ['F', 'G', 'H', 'I', 'J'];

/// A 5v5 round. Team 0 is the player's team (A is the player); [attack] is that team's side.
ReplayRound rd(
  String match,
  int n, {
  required bool won,
  List<K> kills = const [],
  bool attack = false,
  int day = 1,
  String map = 'Bank',
  String op = 'Ash',
  List<String>? names,
  bool objective = false,
}) {
  final t0 = names ?? _team0;
  return ReplayRound(
    matchId: match,
    number: n,
    at: DateTime.utc(2026, 1, day, 12, n),
    map: map,
    matchType: 'Ranked',
    site: 'Main Site',
    teams: [
      ReplayTeam(role: attack ? 'Attack' : 'Defense', score: won ? 1 : 0, won: won),
      ReplayTeam(role: attack ? 'Defense' : 'Attack', score: won ? 0 : 1, won: !won),
    ],
    players: [
      for (var i = 0; i < 5; i++) ReplayPlayer(name: t0[i], team: 0, operator: i == 0 ? op : 'Thatcher'),
      for (final p in _team1) ReplayPlayer(name: p, team: 1, operator: 'Jager'),
    ],
    events: [
      for (final k in kills) ReplayEvent(type: 'Kill', actor: k.actor, target: k.target, headshot: k.hs, remaining: k.remaining),
      if (objective) const ReplayEvent(type: 'DefuserPlantComplete', actor: 'A', remaining: 60),
    ],
    source: 'dissect',
  );
}

/// A round where A opens with a kill, survives, and the team wins.
ReplayRound goodRound(String m, int n, {int day = 1, String map = 'Bank', String op = 'Ash', bool attack = false}) => rd(m, n, won: true, day: day, map: map, op: op, attack: attack, kills: const [
      K('A', 'F', 170, hs: true),
      K('A', 'G', 150),
      K('B', 'H', 120),
      K('C', 'I', 90),
      K('D', 'J', 60),
    ]);

/// A round where A is the first to die, gets nothing, and the team loses.
ReplayRound badRound(String m, int n, {int day = 1, String map = 'Bank', String op = 'Ash', bool attack = false}) => rd(m, n, won: false, day: day, map: map, op: op, attack: attack, kills: const [
      K('F', 'A', 170),
      K('G', 'B', 120),
      K('H', 'C', 100),
      K('I', 'D', 80),
      K('J', 'E', 60),
    ]);

/// [good] matches' worth of wins first or last, in [count] matches of [perMatch] rounds, oldest first by date.
List<ReplayRound> series(int count, int perMatch, bool Function(int match) goodMatch, {String map = 'Bank', String op = 'Ash'}) => [
      for (var m = 0; m < count; m++)
        for (var n = 1; n <= perMatch; n++)
          (goodMatch(m) ? goodRound : badRound)('m$m', n, day: m + 1, map: map, op: op, attack: n.isEven),
    ];

/// A varied set of matches that fills every card, with long names to stress layouts.
List<ReplayRound> richSet() {
  final out = <ReplayRound>[];
  for (var m = 0; m < 8; m++) {
    final good = m >= 4;
    for (var n = 1; n <= 6; n++) {
      final r = n % 3 == 0
          ? rd('rich$m', n, won: false, day: m + 1, map: m.isEven ? 'Nighthaven Labs' : 'Consulate', op: 'Zero', attack: n.isEven, kills: const [
              K('F', 'B', 175),
              K('G', 'C', 150),
              K('H', 'D', 120),
              K('A', 'F', 100),
              K('A', 'G', 90),
              K('I', 'A', 40),
            ])
          : (good ? goodRound : badRound)('rich$m', n, day: m + 1, map: m.isEven ? 'Nighthaven Labs' : 'Consulate', op: n.isEven ? 'Ash' : 'Mozzie', attack: n.isEven);
      out.add(r);
    }
  }
  return out;
}

/// The same rounds with the player [mine] renamed to [name], so tests can use the app's configured username.
List<ReplayRound> asPlayer(List<ReplayRound> rounds, String name) {
  Object? swap(Object? x) => x is String ? (x == mine ? name : x) : (x is List ? [for (final e in x) swap(e)] : (x is Map ? {for (final e in x.entries) e.key: swap(e.value)} : x));
  return [for (final r in rounds) ReplayRound.fromJson(Map<String, dynamic>.from(swap(r.toJson()) as Map))];
}

/// The same rounds as if [name]'s game had recorded them: each file carries that player's profile id,
/// the way a real replay says whose it is. Every player gets a profile id so the recorder can be looked up.
List<ReplayRound> recordedBy(List<ReplayRound> rounds, String name, {bool withRecorder = true}) {
  String pid(String n) => 'profile-${n.hashCode.toUnsigned(32)}';
  return [
    for (final r in rounds)
      () {
        final j = Map<String, dynamic>.from(r.toJson());
        j['pl'] = [for (final p in j['pl'] as List) [...(p as List)]..[3] = pid(p[0] as String)];
        j['rc'] = withRecorder ? pid(name) : null;
        return ReplayRound.fromJson(j);
      }(),
  ];
}
