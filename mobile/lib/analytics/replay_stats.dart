import '../data/replay.dart';

enum Opening { none, kill, death }

bool _same(String? a, String? b) => a != null && b != null && a.trim().toLowerCase() == b.trim().toLowerCase();

/// How one player's round went. All fields are derived from the round's kill order; strict trade
/// detection also needs real kill times, so it is only reported when [round].timed is true.
class MyRound {
  const MyRound._({
    required this.round,
    required this.name,
    required this.player,
    this.kills = 0,
    this.headshots = 0,
    this.died = false,
    this.left = false,
    this.opening = Opening.none,
    this.objective = false,
    this.traded,
    this.avenged = false,
    this.teamKills = 0,
  });

  final ReplayRound round;
  final String name;
  final ReplayPlayer? player;
  final int kills, headshots, teamKills;
  final bool died, left, objective, avenged;
  final Opening opening;
  final bool? traded; // null when kill times are unavailable

  bool get present => player != null;
  ReplayTeam? get team => (player == null || player!.team >= round.teams.length) ? null : round.teams[player!.team];
  String? get role => team?.role;
  bool get attack => team?.attack ?? false;
  bool? get won => team?.won;

  bool get survived => present && !died && !left;

  /// KOST: a Kill, an Objective play, Survival, or being Traded. Without kill times the Traded
  /// part cannot be judged, so the value is a lower bound (see [ReplaySummary.kostIsLowerBound]).
  bool get kost => kills > 0 || objective || survived || traded == true;
}

MyRound analyzeRound(ReplayRound r, String me) {
  ReplayPlayer? player;
  for (final p in r.players) {
    if (_same(p.name, me)) player = p;
  }
  if (player == null) return MyRound._(round: r, name: me, player: null);

  int? teamOf(String? n) {
    for (final p in r.players) {
      if (_same(p.name, n)) return p.team;
    }
    return null;
  }

  final kills = r.events.where((e) => e.isKill).toList();
  var k = 0, hs = 0, tk = 0;
  var died = false;
  int? deathIdx;
  for (var i = 0; i < kills.length; i++) {
    final e = kills[i];
    final sameTeam = teamOf(e.actor) != null && teamOf(e.actor) == teamOf(e.target);
    if (_same(e.actor, me)) {
      if (sameTeam) {
        tk++;
      } else {
        k++;
        if (e.headshot) hs++;
      }
    }
    if (_same(e.target, me) && !died) {
      died = true;
      deathIdx = i;
    }
  }
  // A death with no killer (a fall, the map, your own gadget) is still a death, with nobody to trade it.
  if (!died && r.events.any((e) => e.isDeath && _same(e.actor, me))) died = true;

  var opening = Opening.none;
  for (final e in kills) {
    final sameTeam = teamOf(e.actor) != null && teamOf(e.actor) == teamOf(e.target);
    if (sameTeam) continue; // a team kill is not an opening duel
    if (_same(e.actor, me)) opening = Opening.kill;
    if (_same(e.target, me)) opening = Opening.death;
    break;
  }

  var traded = false, avenged = false;
  if (died && deathIdx != null) {
    final killer = kills[deathIdx].actor;
    final myDeath = kills[deathIdx].remaining;
    for (var j = deathIdx + 1; j < kills.length; j++) {
      final e = kills[j];
      if (_same(e.target, killer) && teamOf(e.actor) == player.team && !_same(e.actor, me)) {
        avenged = true;
        if (myDeath != null && e.remaining != null && myDeath - e.remaining! <= 5) traded = true;
      }
    }
  }

  return MyRound._(
    round: r,
    name: me,
    player: player,
    kills: k,
    headshots: hs,
    teamKills: tk,
    died: died,
    left: r.events.any((e) => e.type == 'PlayerLeave' && _same(e.actor, me)),
    opening: opening,
    objective: r.events.any((e) => (e.isPlant || e.isDefuse) && _same(e.actor, me)),
    traded: r.timed ? (died ? traded : false) : null,
    avenged: avenged,
  );
}

class ReplaySummary {
  const ReplaySummary({
    required this.rounds,
    required this.wins,
    required this.kills,
    required this.headshots,
    required this.deaths,
    required this.openingKills,
    required this.openingDeaths,
    required this.kostRounds,
    required this.survivedRounds,
    required this.avengedDeaths,
    required this.tradedDeaths,
    required this.allTimed,
    required this.assists,
  });

  final int rounds, wins, kills, headshots, deaths, openingKills, openingDeaths, kostRounds, survivedRounds, avengedDeaths, tradedDeaths;
  final int? assists; // null when no round reported assists
  final bool allTimed;

  int get losses => rounds - wins;
  double? get kost => rounds == 0 ? null : kostRounds / rounds;
  double? get survival => rounds == 0 ? null : survivedRounds / rounds;
  double? get kd => deaths == 0 ? null : kills / deaths;
  double? get headshotRate => kills == 0 ? null : headshots / kills;
  double? get openingRate => (openingKills + openingDeaths) == 0 ? null : openingKills / (openingKills + openingDeaths);
  double? get avengedRate => deaths == 0 ? null : avengedDeaths / deaths;
  double? get tradedRate => (deaths == 0 || !allTimed) ? null : tradedDeaths / deaths;

  /// True when some rounds lack kill times, so Traded was not counted and KOST may be too low.
  bool get kostIsLowerBound => !allTimed;
}

ReplaySummary summarize(List<MyRound> all) {
  final rs = all.where((r) => r.present).toList();
  int count(bool Function(MyRound) f) => rs.where(f).length;
  final hasAssists = rs.any((r) => r.player!.assists != null);
  return ReplaySummary(
    rounds: rs.length,
    wins: count((r) => r.won == true),
    kills: rs.fold(0, (s, r) => s + r.kills),
    headshots: rs.fold(0, (s, r) => s + r.headshots),
    deaths: count((r) => r.died),
    openingKills: count((r) => r.opening == Opening.kill),
    openingDeaths: count((r) => r.opening == Opening.death),
    kostRounds: count((r) => r.kost),
    survivedRounds: count((r) => r.survived),
    avengedDeaths: count((r) => r.died && r.avenged),
    tradedDeaths: count((r) => r.died && r.traded == true),
    allTimed: rs.every((r) => r.round.timed),
    assists: hasAssists ? rs.fold<int>(0, (s, r) => s + (r.player!.assists ?? 0)) : null,
  );
}

class SiteStat {
  const SiteStat(this.map, this.site, this.attack, this.rounds, this.wins);
  final String map, site;
  final bool attack;
  final int rounds, wins;
  double get winRate => rounds == 0 ? 0 : wins / rounds;
}

/// Round results by map, bombsite and side, from the player's own rounds.
List<SiteStat> siteStats(List<MyRound> all) {
  final acc = <String, List<int>>{};
  final info = <String, (String, String, bool)>{};
  for (final r in all.where((r) => r.present && r.round.site != null && r.won != null)) {
    final key = '${r.round.map}|${r.round.site}|${r.attack}';
    info[key] = (r.round.map, r.round.site!, r.attack);
    final a = acc.putIfAbsent(key, () => [0, 0]);
    a[0]++;
    if (r.won == true) a[1]++;
  }
  return [for (final e in acc.entries) SiteStat(info[e.key]!.$1, info[e.key]!.$2, info[e.key]!.$3, e.value[0], e.value[1])]..sort((a, b) => b.rounds.compareTo(a.rounds));
}

class PlayerLine {
  const PlayerLine(this.name, this.team, this.rounds, this.kills, this.deaths, this.kostRounds, this.assists);
  final String name;
  final int team, rounds, kills, deaths, kostRounds;
  final int? assists;
  double get kost => rounds == 0 ? 0 : kostRounds / rounds;
}

/// Everyone's totals across a match's rounds, using the same rules as for the player.
List<PlayerLine> leaderboard(List<ReplayRound> rounds) {
  final names = <String, int>{};
  for (final r in rounds) {
    for (final p in r.players) {
      names.putIfAbsent(p.name, () => p.team);
    }
  }
  final out = <PlayerLine>[];
  for (final e in names.entries) {
    final mine = [for (final r in rounds) analyzeRound(r, e.key)].where((m) => m.present).toList();
    final s = summarize(mine);
    out.add(PlayerLine(e.key, e.value, s.rounds, s.kills, s.deaths, s.kostRounds, s.assists));
  }
  return out..sort((a, b) => b.kills.compareTo(a.kills));
}

/// Groups rounds by match, rounds in order, newest match first.
List<List<ReplayRound>> groupMatches(List<ReplayRound> rounds) {
  final by = <String, List<ReplayRound>>{};
  for (final r in rounds) {
    by.putIfAbsent(r.matchId, () => []).add(r);
  }
  final out = [for (final l in by.values) l..sort((a, b) => a.number.compareTo(b.number))];
  out.sort((a, b) => (b.first.at ?? DateTime(2000)).compareTo(a.first.at ?? DateTime(2000)));
  return out;
}
