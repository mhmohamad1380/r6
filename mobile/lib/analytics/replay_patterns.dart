import '../data/replay.dart';
import 'insights.dart' show Tone;
import 'replay_report.dart' show ReplayFinding;
import 'replay_stats.dart';

// Patterns that need many rounds side by side: who you play with, what kills you, how rounds end, how you handle
// pressure, where you spawn, and when you play. Each one says how many rounds it rests on, and the findings only
// speak once there is enough to go on.

bool _same(String? a, String? b) => a != null && b != null && a.trim().toLowerCase() == b.trim().toLowerCase();
String _p(double v) => '${(v * 100).round()}%';
double? _rate(int a, int n) => n == 0 ? null : a / n;

/// Rounds won and played, the unit most of these patterns count in.
class WinCount {
  WinCount([this.wins = 0, this.rounds = 0]);
  int wins, rounds;
  double? get rate => _rate(wins, rounds);
  void add(bool? won) {
    if (won == null) return;
    rounds++;
    if (won) wins++;
  }
}

// ---------------------------------------------------------------- 1. your squad

class Mate {
  Mate(this.key, this.name);
  final String key;
  String name; // the newest name seen, in case they renamed
  final matches = <String>{};
  final rec = WinCount();
  int avengedMe = 0, iAvenged = 0; // trade partners: they killed my killer, I killed theirs
}

class SquadReport {
  const SquadReport({required this.regulars, required this.withSquad, required this.solo, required this.withKost, required this.soloKost, required this.matches});
  final List<Mate> regulars; // teammates in at least two of your matches
  final WinCount withSquad, solo; // rounds with at least one regular on your team, and rounds without
  final double? withKost, soloKost;
  final int matches;
}

String _key(ReplayPlayer p) => p.profileId?.isNotEmpty == true ? p.profileId! : 'name:${p.name.toLowerCase()}';

SquadReport squad(List<MyRound> mine) {
  final rs = mine.where((m) => m.present).toList()..sort((a, b) => (a.round.at ?? DateTime(2000)).compareTo(b.round.at ?? DateTime(2000)));
  final mates = <String, Mate>{};
  for (final m in rs) {
    for (final p in m.round.players) {
      if (p.team != m.player!.team || _same(p.name, m.name)) continue;
      final mate = mates.putIfAbsent(_key(p), () => Mate(_key(p), p.name))..name = p.name;
      mate.matches.add(m.round.matchId);
      mate.rec.add(m.won);
    }
    // Trade partners: who answered my death, and whose death I answered.
    final kills = m.round.events.where((e) => e.isKill).toList();
    final teamOf = {for (final p in m.round.players) p.name.toLowerCase(): p};
    for (var i = 0; i < kills.length; i++) {
      final victim = teamOf[kills[i].target?.toLowerCase()];
      if (victim == null || victim.team != m.player!.team) continue;
      for (final e in kills.skip(i + 1)) {
        if (!_same(e.target, kills[i].actor)) continue;
        final avenger = teamOf[e.actor?.toLowerCase()];
        if (avenger == null || avenger.team != m.player!.team) break;
        if (_same(victim.name, m.name) && !_same(avenger.name, m.name)) mates[_key(avenger)]?.avengedMe++;
        if (_same(avenger.name, m.name) && !_same(victim.name, m.name)) mates[_key(victim)]?.iAvenged++;
        break;
      }
    }
  }
  final regulars = mates.values.where((x) => x.matches.length >= 2).toList()..sort((a, b) => b.matches.length.compareTo(a.matches.length));
  final ids = {for (final x in regulars) x.key};
  final withSquad = WinCount(), solo = WinCount();
  final withRounds = <MyRound>[], soloRounds = <MyRound>[];
  for (final m in rs) {
    final squadUp = m.round.players.any((p) => p.team == m.player!.team && ids.contains(_key(p)) && !_same(p.name, m.name));
    (squadUp ? withSquad : solo).add(m.won);
    (squadUp ? withRounds : soloRounds).add(m);
  }
  return SquadReport(
    regulars: regulars, withSquad: withSquad, solo: solo,
    withKost: summarize(withRounds).kost, soloKost: summarize(soloRounds).kost,
    matches: rs.map((m) => m.round.matchId).toSet().length,
  );
}

// ---------------------------------------------------------------- 2. enemy operators

/// Unknown operator ids ("Operator(444310693746)") are a newer operator the reader does not know by name yet.
bool unknownOperator(String op) => op.startsWith('Operator(');
String operatorLabel(String op) => unknownOperator(op) ? 'New operator (${op.length > 6 ? op.substring(op.length - 5, op.length - 1) : op})' : op;

class OpDuel {
  OpDuel(this.op);
  final String op;
  int kills = 0, deaths = 0; // you killed this operator / this operator killed you
  int get fights => kills + deaths;
  double? get winRate => _rate(kills, fights);
}

/// Your fights against each enemy operator: who you beat and who beats you.
List<OpDuel> enemyOperators(List<MyRound> mine) {
  final by = <String, OpDuel>{};
  for (final m in mine.where((m) => m.present)) {
    final players = {for (final p in m.round.players) p.name.toLowerCase(): p};
    for (final e in m.round.events.where((e) => e.isKill)) {
      final a = players[e.actor?.toLowerCase()], t = players[e.target?.toLowerCase()];
      if (a == null || t == null || a.team == t.team) continue;
      if (_same(a.name, m.name) && t.operator != null) by.putIfAbsent(t.operator!, () => OpDuel(t.operator!)).kills++;
      if (_same(t.name, m.name) && a.operator != null) by.putIfAbsent(a.operator!, () => OpDuel(a.operator!)).deaths++;
    }
  }
  return by.values.toList()..sort((a, b) => b.fights.compareTo(a.fights));
}

// ---------------------------------------------------------------- 3. how rounds end

enum RoundEnd { elimination, defused, detonated, time, unknown }

String endLabel(RoundEnd e) => switch (e) {
      RoundEnd.elimination => 'A team was wiped out',
      RoundEnd.defused => 'Defuser disabled',
      RoundEnd.detonated => 'Defuser held to the end',
      RoundEnd.time => 'Time ran out',
      RoundEnd.unknown => 'Not clear',
    };

/// How a round ended, worked out from what happened in it. The file's own reason is often blank, so it is not relied on.
RoundEnd roundEnd(ReplayRound r) {
  if (r.teams.length != 2) return RoundEnd.unknown;
  final atk = r.teams.indexWhere((t) => t.attack);
  if (atk < 0) return RoundEnd.unknown;
  final winner = r.teams.indexWhere((t) => t.won);
  final cond = r.teams.firstWhere((t) => t.won, orElse: () => r.teams.first).winCondition?.toLowerCase() ?? '';
  // The file's "DefusedBomb" shows up far more often than actual disable events, so only the events decide a defuse.
  if (cond.contains('time')) return RoundEnd.time;
  final size = <int, int>{}, dead = <int, int>{};
  for (final p in r.players) {
    size[p.team] = (size[p.team] ?? 0) + 1;
  }
  final teamOf = {for (final p in r.players) p.name.toLowerCase(): p.team};
  for (final e in r.events) {
    final victim = e.isKill ? e.target : (e.isDeath ? e.actor : null);
    final t = teamOf[victim?.toLowerCase()];
    if (t != null) dead[t] = (dead[t] ?? 0) + 1;
  }
  final wiped = [for (final t in size.keys) if ((dead[t] ?? 0) >= size[t]!) t];
  if (r.defused) return RoundEnd.defused;
  if (r.planted && winner == atk) return wiped.contains(1 - atk) ? RoundEnd.elimination : RoundEnd.detonated;
  if (wiped.isNotEmpty) return RoundEnd.elimination;
  if (winner >= 0 && winner != atk && !r.planted) return RoundEnd.time;
  return RoundEnd.unknown;
}

class EndReport {
  const EndReport(this.attackWins, this.attackLosses, this.defenseWins, this.defenseLosses);
  final Map<RoundEnd, int> attackWins, attackLosses, defenseWins, defenseLosses;
  int total(Map<RoundEnd, int> m) => m.values.fold(0, (a, b) => a + b);
}

EndReport roundEnds(List<MyRound> mine) {
  Map<RoundEnd, int> m() => {};
  final aw = m(), al = m(), dw = m(), dl = m();
  for (final x in mine.where((x) => x.present && x.won != null)) {
    final target = x.attack ? (x.won! ? aw : al) : (x.won! ? dw : dl);
    final e = roundEnd(x.round);
    target[e] = (target[e] ?? 0) + 1;
  }
  return EndReport(aw, al, dw, dl);
}

// ---------------------------------------------------------------- 4. the plant

class PlantReport {
  const PlantReport({required this.planted, required this.notPlanted, required this.myPlants, required this.againstPlanted, required this.defusedByUs});
  final WinCount planted, notPlanted; // your attack rounds, with and without a plant
  final int myPlants; // plants you made yourself
  final int againstPlanted, defusedByUs; // defense rounds where the attackers planted, and how many your team defused
}

PlantReport plants(List<MyRound> mine) {
  final p = WinCount(), n = WinCount();
  var mineP = 0, against = 0, defused = 0;
  for (final x in mine.where((x) => x.present && x.won != null)) {
    if (x.attack) {
      (x.round.planted ? p : n).add(x.won);
      if (x.round.events.any((e) => e.isPlant && _same(e.actor, x.name))) mineP++;
    } else if (x.round.planted) {
      against++;
      if (x.round.defused) defused++;
    }
  }
  return PlantReport(planted: p, notPlanted: n, myPlants: mineP, againstPlanted: against, defusedByUs: defused);
}

// ---------------------------------------------------------------- 5. pressure

class PressureReport {
  const PressureReport({required this.firstRound, required this.ourMatchPoint, required this.theirMatchPoint, required this.overtime, required this.afterWin, required this.afterLoss, required this.afterWinKost, required this.afterLossKost, required this.downTwo, required this.downTwoWon});
  final WinCount firstRound, ourMatchPoint, theirMatchPoint, overtime, afterWin, afterLoss;
  final double? afterWinKost, afterLossKost;
  final int downTwo, downTwoWon; // matches where you lost the first two rounds, and how many of them you still won
}

PressureReport pressure(List<MyRound> mine) {
  final first = WinCount(), ours = WinCount(), theirs = WinCount(), ot = WinCount(), aw = WinCount(), al = WinCount();
  final awR = <MyRound>[], alR = <MyRound>[];
  var down = 0, downWon = 0;
  final byMatch = <String, List<MyRound>>{};
  for (final m in mine.where((m) => m.present)) {
    byMatch.putIfAbsent(m.round.matchId, () => []).add(m);
  }
  for (final list in byMatch.values) {
    list.sort((a, b) => a.round.number.compareTo(b.round.number));
    for (var i = 0; i < list.length; i++) {
      final m = list[i], r = m.round;
      if (m.won == null || m.team == null) continue;
      // The score before this round: the file has the score after it.
      final my = m.team!.score - (m.won! ? 1 : 0);
      final otherTeam = r.teams.length == 2 ? r.teams[1 - m.player!.team.clamp(0, 1)] : null;
      final their = otherTeam == null ? null : otherTeam.score - (otherTeam.won ? 1 : 0);
      if (r.number == 0) first.add(m.won);
      if (r.overtime) {
        ot.add(m.won);
      } else if (their != null) {
        if (my == r.winTarget - 1) ours.add(m.won);
        if (their == r.winTarget - 1) theirs.add(m.won);
      }
      // The round before, only when it is really the one before (a missing file breaks the chain).
      if (i > 0 && list[i - 1].round.number == r.number - 1 && list[i - 1].won != null) {
        (list[i - 1].won! ? aw : al).add(m.won);
        (list[i - 1].won! ? awR : alR).add(m);
      }
    }
    final start = [for (final m in list.take(2)) m];
    if (start.length == 2 && start[0].round.number == 0 && start[1].round.number == 1 && start.every((m) => m.won == false)) {
      down++;
      final wins = list.where((m) => m.won == true).length, losses = list.where((m) => m.won == false).length;
      if (wins > losses) downWon++;
    }
  }
  return PressureReport(
    firstRound: first, ourMatchPoint: ours, theirMatchPoint: theirs, overtime: ot, afterWin: aw, afterLoss: al,
    afterWinKost: summarize(awR).kost, afterLossKost: summarize(alR).kost, downTwo: down, downTwoWon: downWon,
  );
}

// ---------------------------------------------------------------- 6. a player short

class ShortReport {
  const ShortReport(this.full, this.short, this.leaverRounds);
  final WinCount full, short; // your team had as many players as the enemy, or fewer
  final int leaverRounds; // rounds where one of your teammates quit
}

ShortReport shorthanded(List<MyRound> mine) {
  final full = WinCount(), short = WinCount();
  var leavers = 0;
  for (final m in mine.where((m) => m.present)) {
    final mineN = m.round.players.where((p) => p.team == m.player!.team).length;
    final theirs = m.round.players.length - mineN;
    final quit = m.round.events.any((e) => e.type == 'PlayerLeave' && m.round.players.any((p) => p.team == m.player!.team && _same(p.name, e.actor) && !_same(p.name, m.name)));
    if (quit) leavers++;
    (mineN < theirs || quit ? short : full).add(m.won);
  }
  return ShortReport(full, short, leavers);
}

// ---------------------------------------------------------------- 7. spawns

class SpawnLine {
  SpawnLine(this.map, this.spawn);
  final String map, spawn;
  final rec = WinCount();
  int kills = 0, deaths = 0, openingDeaths = 0;
}

/// Your attack rounds by map and spawn point. Only replays read by uploader 1.3.0 or the server keep the spawn.
List<SpawnLine> spawns(List<MyRound> mine) {
  final by = <String, SpawnLine>{};
  for (final m in mine.where((m) => m.present && m.attack && m.player!.spawn != null)) {
    final s = m.player!.spawn!;
    final label = s.toUpperCase() == 'RANDOM' ? 'Random spawn' : s;
    final line = by.putIfAbsent('${m.round.map}|$label', () => SpawnLine(m.round.map, label));
    line.rec.add(m.won);
    line.kills += m.kills;
    if (m.died) line.deaths++;
    if (m.opening == Opening.death) line.openingDeaths++;
  }
  return by.values.toList()..sort((a, b) => b.rec.rounds.compareTo(a.rec.rounds));
}

// ---------------------------------------------------------------- 8. when you play

class PlayTimeLine {
  PlayTimeLine(this.label);
  final String label;
  final rec = WinCount();
  final rounds = <MyRound>[];
  double? get kost => summarize(rounds).kost;
}

class WhenReport {
  const WhenReport({required this.byMatchInSession, required this.byTimeOfDay, required this.sessions});
  final List<PlayTimeLine> byMatchInSession; // 1st match of a sitting, 2nd, 3rd, 4th or later
  final List<PlayTimeLine> byTimeOfDay;
  final int sessions;
}

String _dayPart(int h) => h < 6 ? 'Night (0–6)' : h < 12 ? 'Morning (6–12)' : h < 18 ? 'Afternoon (12–18)' : 'Evening (18–24)';

WhenReport whenYouPlay(List<MyRound> mine, {Duration gap = const Duration(hours: 2)}) {
  final rs = mine.where((m) => m.present && m.round.at != null).toList();
  final starts = <String, DateTime>{};
  for (final m in rs) {
    final t = starts[m.round.matchId];
    if (t == null || m.round.at!.isBefore(t)) starts[m.round.matchId] = m.round.at!;
  }
  final order = starts.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
  final position = <String, int>{};
  var sessions = 0, inSession = 0;
  DateTime? last;
  for (final e in order) {
    if (last == null || e.value.difference(last) > gap) {
      sessions++;
      inSession = 0;
    }
    inSession++;
    position[e.key] = inSession;
    last = e.value;
  }
  final slots = {for (final l in const ['1st match', '2nd match', '3rd match', '4th or later']) l: PlayTimeLine(l)};
  final parts = {for (final l in const ['Morning (6–12)', 'Afternoon (12–18)', 'Evening (18–24)', 'Night (0–6)']) l: PlayTimeLine(l)};
  for (final m in rs) {
    final pos = position[m.round.matchId]!;
    final slot = slots.values.elementAt(pos >= 4 ? 3 : pos - 1);
    final part = parts[_dayPart(m.round.at!.toLocal().hour)]!;
    for (final l in [slot, part]) {
      l.rec.add(m.won);
      l.rounds.add(m);
    }
  }
  return WhenReport(byMatchInSession: [for (final l in slots.values) if (l.rounds.isNotEmpty) l], byTimeOfDay: [for (final l in parts.values) if (l.rounds.isNotEmpty) l], sessions: sessions);
}

// ---------------------------------------------------------------- 9. seasons

class SeasonLine {
  const SeasonLine(this.season, this.summary);
  final String season;
  final ReplaySummary summary;
}

List<SeasonLine> seasons(List<MyRound> mine) {
  final by = <String, List<MyRound>>{};
  for (final m in mine.where((m) => m.present && m.round.season != null)) {
    by.putIfAbsent(_season(m.round.season!), () => []).add(m);
  }
  return [for (final e in by.entries) SeasonLine(e.key, summarize(e.value))]..sort((a, b) => b.season.compareTo(a.season));
}

/// "Y11S3_Alpha04" -> "Y11S3".
String _season(String v) => RegExp(r'^Y\d+S\d+').firstMatch(v)?.group(0) ?? v;

// ---------------------------------------------------------------- 10. against everyone else

/// Percentile tables of the other players in the stored replays, from the replay server (/v1/population).
class Population {
  const Population({required this.players, required this.rounds, required this.quantiles});
  final int players, rounds;
  final Map<String, List<double>> quantiles; // metric -> 21 values: the 0th, 5th ... 100th percentile

  static Population? fromJson(Map<String, dynamic> j) {
    final m = j['metrics'];
    if (m is! Map) return null;
    return Population(
      players: (j['players'] as num?)?.toInt() ?? 0,
      rounds: (j['rounds'] as num?)?.toInt() ?? 0,
      quantiles: {for (final e in m.entries) if (e.value is Map && (e.value as Map)['quantiles'] is List) e.key as String: [for (final v in (e.value as Map)['quantiles'] as List) (v as num).toDouble()]},
    );
  }

  /// What share of players are below [value], from 0 to 1. Null when the server has no table for the metric.
  double? percentile(String metric, double? value) {
    final q = quantiles[metric];
    if (q == null || q.length < 2 || value == null) return null;
    if (value <= q.first) return 0;
    if (value >= q.last) return 1;
    for (var i = 1; i < q.length; i++) {
      if (value <= q[i]) {
        final lo = q[i - 1], hi = q[i];
        final within = hi == lo ? 0.5 : (value - lo) / (hi - lo);
        return ((i - 1) + within) / (q.length - 1);
      }
    }
    return 1;
  }
}

class Standing {
  const Standing(this.metric, this.label, this.value, this.percentile, {this.higherIsBetter = true});
  final String metric, label;
  final double value, percentile;
  final bool higherIsBetter;
}

/// Where you stand among the players you met, on each metric the server has a table for.
List<Standing> standings(ReplaySummary s, Population? pop) {
  if (pop == null || s.rounds < 10) return const [];
  final out = <Standing>[];
  void add(String key, String label, double? v) {
    final p = pop.percentile(key, v);
    if (p != null && v != null) out.add(Standing(key, label, v, p));
  }
  add('kost', 'KOST', s.kost);
  add('kd', 'K/D', s.deaths == 0 ? s.kills.toDouble() : s.kd);
  add('killsPerRound', 'Kills per round', s.rounds == 0 ? null : s.kills / s.rounds);
  add('headshotRate', 'Headshots', s.headshotRate);
  add('openingRate', 'Opening duels won', s.openingRate);
  add('survival', 'Rounds survived', s.survival);
  add('winRate', 'Rounds won', s.rounds == 0 ? null : s.wins / s.rounds);
  return out;
}

// ---------------------------------------------------------------- everything, plus what it says

class Patterns {
  const Patterns({
    required this.rounds, required this.squad, required this.enemyOps, required this.ends, required this.plants, required this.pressure,
    required this.short, required this.spawns, required this.when, required this.seasons, required this.standings, required this.population, required this.findings,
  });
  final int rounds;
  final SquadReport squad;
  final List<OpDuel> enemyOps;
  final EndReport ends;
  final PlantReport plants;
  final PressureReport pressure;
  final ShortReport short;
  final List<SpawnLine> spawns;
  final WhenReport when;
  final List<SeasonLine> seasons;
  final List<Standing> standings;
  final Population? population;
  final List<ReplayFinding> findings;
}

Patterns buildPatterns(List<ReplayRound> rounds, String me, {Population? population}) {
  final mine = [for (final r in rounds) analyzeRound(r, me)].where((m) => m.present).toList();
  final sq = squad(mine), ops = enemyOperators(mine), ends = roundEnds(mine), pl = plants(mine), pr = pressure(mine), sh = shorthanded(mine);
  final sp = spawns(mine), wh = whenYouPlay(mine), se = seasons(mine);
  final st = standings(summarize(mine), population);
  final f = <ReplayFinding>[];

  // Squad: a clear gap between playing with your regulars and without them.
  final a = sq.withSquad, b = sq.solo;
  if (a.rounds >= 12 && b.rounds >= 12 && (a.rate! - b.rate!).abs() >= 0.12) {
    final better = a.rate! > b.rate!;
    f.add(ReplayFinding(
      id: 'pat-squad', tone: better ? Tone.good : Tone.warn, sample: a.rounds + b.rounds,
      title: better ? 'You win more with your regular teammates' : 'You win more without your regular teammates',
      evidence: 'With ${sq.regulars.take(3).map((m) => m.name).join(', ')}${sq.regulars.length > 3 ? ' and others' : ''}: ${_p(a.rate!)} of ${a.rounds} rounds. Without them: ${_p(b.rate!)} of ${b.rounds}.',
      action: better ? 'Queue with them when you want to climb. When you play alone, copy what works together: call out, stay in pairs.' : 'Your squad sessions go worse. Look at who takes the first fights and whether you split up too much.',
    ));
  }

  // Your own play with and without them, when the team result does not differ.
  if (sq.withKost != null && sq.soloKost != null && a.rounds >= 15 && b.rounds >= 15 && (sq.withKost! - sq.soloKost!).abs() >= 0.1 && !f.any((x) => x.id == 'pat-squad')) {
    final alone = sq.soloKost! > sq.withKost!;
    f.add(ReplayFinding(
      id: 'pat-squad-kost', tone: Tone.info, sample: a.rounds + b.rounds,
      title: alone ? 'You play bigger when you queue alone' : 'You play better with your regular teammates',
      evidence: 'Your KOST with a regular teammate: ${_p(sq.withKost!)} over ${a.rounds} rounds. Without: ${_p(sq.soloKost!)} over ${b.rounds}. Your team wins about as often either way.',
      action: alone ? 'With your squad you may be leaving the fights to them. Take your share of entries and trades.' : 'Alone you get caught out more. Stick closer to whoever is on your team, the way you do with your squad.',
    ));
  }

  // The operator that beats you.
  final nemesis = ops.where((o) => !unknownOperator(o.op) && o.fights >= 5 && o.deaths >= 4 && o.winRate! <= 0.35).toList()..sort((x, y) => y.deaths.compareTo(x.deaths));
  if (nemesis.isNotEmpty) {
    final o = nemesis.first;
    f.add(ReplayFinding(
      id: 'pat-nemesis', tone: Tone.warn, sample: o.fights,
      title: '${o.op} beats you more than any other operator',
      evidence: 'In fights with ${o.op} you won ${o.kills} and lost ${o.deaths}.',
      action: 'Think about how ${o.op} plays: where they set up, what gadget they rely on, and take those fights on your terms.',
      drill: 'Next time ${o.op} is on the other team, droning or checking for them first before you peek.',
    ));
  }
  final prey = ops.where((o) => !unknownOperator(o.op) && o.fights >= 5 && o.winRate! >= 0.7).toList();
  if (prey.isNotEmpty) {
    final o = prey.first;
    f.add(ReplayFinding(id: 'pat-prey', tone: Tone.good, sample: o.fights, title: 'You win your fights against ${o.op}', evidence: 'You won ${o.kills} of ${o.fights} fights against ${o.op}.', action: 'Whatever you do against ${o.op} works. Keep doing it.'));
  }

  // Attack rounds lost on time: a plant problem.
  final atkLost = ends.total(ends.attackLosses), timeLost = ends.attackLosses[RoundEnd.time] ?? 0;
  if (atkLost >= 8 && timeLost / atkLost >= 0.3) {
    f.add(ReplayFinding(
      id: 'pat-time', tone: Tone.warn, sample: atkLost,
      title: 'Your attacks run out of time',
      evidence: '$timeLost of your $atkLost lost attack rounds ended with the timer, not with a fight.',
      action: 'Decide on the plant spot earlier and start your execute with about a minute left, not thirty seconds.',
      drill: 'In your next three attack rounds, say out loud when there is 1:00 left and move in on that call.',
    ));
  }

  // The plant.
  if (pl.planted.rounds >= 5 && pl.notPlanted.rounds >= 5 && pl.planted.rate! - pl.notPlanted.rate! >= 0.25) {
    f.add(ReplayFinding(
      id: 'pat-plant', tone: Tone.info, sample: pl.planted.rounds + pl.notPlanted.rounds,
      title: 'Getting the plant down wins your attacks',
      evidence: 'Attack rounds with a plant: ${_p(pl.planted.rate!)} won (${pl.planted.rounds}). Without: ${_p(pl.notPlanted.rate!)} (${pl.notPlanted.rounds}).${pl.myPlants > 0 ? ' You planted ${pl.myPlants} of them yourself.' : ' You did not plant in any of them yourself.'}',
      action: 'Play for the plant, not for kills. Bring the defuser to the site with a teammate covering.',
    ));
  }

  // Tilt: a lost round makes the next one worse.
  if (pr.afterLoss.rounds >= 10 && pr.afterWin.rounds >= 10 && pr.afterWinKost != null && pr.afterLossKost != null && pr.afterWinKost! - pr.afterLossKost! >= 0.12) {
    f.add(ReplayFinding(
      id: 'pat-tilt', tone: Tone.warn, sample: pr.afterLoss.rounds + pr.afterWin.rounds,
      title: 'A lost round drags down the next one',
      evidence: 'Your KOST is ${_p(pr.afterWinKost!)} after a won round and ${_p(pr.afterLossKost!)} after a lost one.',
      action: 'Between rounds, reset: one breath, one plan for the next round, no talk about the last one.',
    ));
  }
  if (pr.theirMatchPoint.rounds >= 5 && pr.theirMatchPoint.rate! >= 0.5) {
    f.add(ReplayFinding(id: 'pat-clutchmp', tone: Tone.good, sample: pr.theirMatchPoint.rounds, title: 'You fight back at their match point', evidence: 'With the other team one round from winning, your team won ${pr.theirMatchPoint.wins} of ${pr.theirMatchPoint.rounds}.', action: 'Your team does not give up. Bring that focus into the earlier rounds too.'));
  }

  // Playing tired.
  final slots = wh.byMatchInSession;
  if (slots.length >= 2 && slots.first.rounds.length >= 12 && slots.last.rounds.length >= 12 && slots.first != slots.last) {
    final k1 = slots.first.kost, kn = slots.last.kost;
    if (k1 != null && kn != null && k1 - kn >= 0.12) {
      f.add(ReplayFinding(
        id: 'pat-fatigue', tone: Tone.warn, sample: slots.first.rounds.length + slots.last.rounds.length,
        title: 'You play worse the longer you sit',
        evidence: 'KOST in the ${slots.first.label} of a sitting: ${_p(k1)}. In the ${slots.last.label}: ${_p(kn)}.',
        action: 'Stop after ${slots.length - 1 <= 1 ? 'two' : '${slots.length - 1}'} matches, or take a 10-minute break before the next one.',
      ));
    }
  }

  // A spawn that keeps failing.
  final badSpawn = sp.where((x) => x.rec.rounds >= 4 && x.rec.rate! <= 0.25).toList();
  if (badSpawn.isNotEmpty) {
    final x = badSpawn.first;
    f.add(ReplayFinding(id: 'pat-spawn', tone: Tone.warn, sample: x.rec.rounds, title: '${x.spawn} on ${x.map} rarely works', evidence: 'Your team won ${x.rec.wins} of ${x.rec.rounds} attack rounds when you spawned there.', action: 'Try another spawn on ${x.map}, or come from ${x.spawn} with a teammate instead of alone.'));
  }

  // Standing among the players you met.
  final top = st.where((x) => x.percentile >= 0.8).toList()..sort((p, q) => q.percentile.compareTo(p.percentile));
  if (top.isNotEmpty) {
    final x = top.first;
    f.add(ReplayFinding(id: 'pat-best', tone: Tone.good, sample: population?.players ?? 0, title: 'Your ${x.label.toLowerCase()} is in the top ${(100 - x.percentile * 100).clamp(1, 100).round()}%', evidence: 'Among the ${population!.players} players in your replays, you are ahead of ${_p(x.percentile)}.', action: 'That is your strength. Pick roles and operators that use it.'));
  }
  final low = st.where((x) => x.percentile <= 0.25).toList()..sort((p, q) => p.percentile.compareTo(q.percentile));
  if (low.isNotEmpty) {
    final x = low.first;
    f.add(ReplayFinding(id: 'pat-worst', tone: Tone.warn, sample: population?.players ?? 0, title: 'Your ${x.label.toLowerCase()} is below most players you meet', evidence: 'Among the ${population!.players} players in your replays, ${_p(1 - x.percentile)} do better.', action: 'This is the gap to close first. The Coach tab has a drill for it.'));
  }

  // Warnings before good news.
  f.sort((x, y) => (x.tone == Tone.warn ? 0 : 1).compareTo(y.tone == Tone.warn ? 0 : 1));
  return Patterns(rounds: mine.length, squad: sq, enemyOps: ops, ends: ends, plants: pl, pressure: pr, short: sh, spawns: sp, when: wh, seasons: se, standings: st, population: population, findings: f);
}

Patterns? _memo;
Object? _memoKey;

/// [buildPatterns], computed again only when the rounds, the player or the population table change.
Patterns cachedPatterns(List<ReplayRound> rounds, String me, {Population? population}) {
  final key = (rounds, rounds.length, me, population);
  if (_memo == null || _memoKey != key) {
    _memo = buildPatterns(rounds, me, population: population);
    _memoKey = key;
  }
  return _memo!;
}
