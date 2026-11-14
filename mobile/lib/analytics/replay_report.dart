import 'dart:math' as math;

import '../data/replay.dart';
import 'insights.dart' show Tone;
import 'replay_stats.dart';
import 'stats.dart';

/// Reference values and weights are design assumptions, not measured constants (same as scoring.dart).
const replayScoreVersion = '0.1.0';

bool _same(String? a, String? b) => a != null && b != null && a.trim().toLowerCase() == b.trim().toLowerCase();

double _r1(double v) => (v * 10).round() / 10;

/// Seconds since the round clock started (the clock counts down from 3:00). Null without real times.
int? _elapsed(ReplayEvent e) => e.remaining == null ? null : (180 - e.remaining!).clamp(0, 180);

// ---------- per-round extras ----------

/// What [MyRound] does not track: clutch situations and when things happened.
class RoundExtra {
  const RoundExtra({required this.my, this.clutchVs, this.firstKillAt, this.deathAt});
  final MyRound my;
  final int? clutchVs; // enemies alive when this player became the last one alive on their team
  final int? firstKillAt, deathAt; // seconds into the round, null without real kill times

  bool get clutch => clutchVs != null;
  bool get clutchWon => clutch && my.won == true;

  /// Died without a kill, an objective play, or anyone avenging them.
  bool get wastedDeath => my.died && my.kills == 0 && !my.objective && !(my.traded == true || my.avenged);
}

RoundExtra extraFor(MyRound m) {
  final r = m.round;
  final me = m.player!;
  final teamOf = {for (final p in r.players) p.name.trim().toLowerCase(): p.team};
  final alive = <int, int>{};
  for (final p in r.players) {
    alive[p.team] = (alive[p.team] ?? 0) + 1;
  }
  final startedWithTeam = alive[me.team] ?? 0;
  var meAlive = true;
  int? clutchVs, firstKill, death;
  for (final e in r.events.where((e) => e.isKill || e.isDeath)) {
    final victim = e.isDeath ? e.actor : e.target; // a death with no killer names the one who died
    final tt = teamOf[victim?.trim().toLowerCase()];
    final at = e.isDeath ? null : teamOf[e.actor?.trim().toLowerCase()];
    if (tt != null) alive[tt] = math.max(0, (alive[tt] ?? 0) - 1);
    if (_same(victim, m.name) && meAlive) {
      meAlive = false;
      death = _elapsed(e);
    }
    if (!e.isDeath && _same(e.actor, m.name) && at != null && tt != null && at != tt) firstKill ??= _elapsed(e);
    if (meAlive && clutchVs == null && startedWithTeam >= 2 && (alive[me.team] ?? 0) == 1) {
      final enemies = alive.entries.where((x) => x.key != me.team).fold<int>(0, (s, x) => s + x.value);
      if (enemies >= 1) clutchVs = enemies;
    }
  }
  return RoundExtra(my: m, clutchVs: clutchVs, firstKillAt: firstKill, deathAt: death);
}

// ---------- the score ----------

class ReplayScore {
  const ReplayScore({required this.score, required this.components, required this.confidence, required this.rounds, required this.notes, this.teamKillPenalty = 0});
  final double? score;
  final Map<String, double?> components; // each 0-100, null when its inputs are missing
  final String confidence; // low | medium | high
  final int rounds;
  final List<String> notes;
  final double teamKillPenalty;
  bool get provisional => confidence != 'high';

  String get label {
    final s = score;
    if (s == null) return 'Not enough data';
    if (s < 35) return 'Rough patch';
    if (s < 45) return 'Below average';
    if (s < 55) return 'Average';
    if (s < 65) return 'Above average';
    if (s < 75) return 'Strong';
    return 'Elite';
  }
}

const _weights = {'impact': 0.30, 'firepower': 0.20, 'survival': 0.10, 'opening': 0.15, 'teamplay': 0.10, 'aim': 0.05, 'results': 0.10};

const scoreComponentNames = {
  'impact': 'Impact (KOST)',
  'firepower': 'Kills per round',
  'survival': 'Survival',
  'opening': 'Opening duels',
  'teamplay': 'Teamplay (trades)',
  'aim': 'Headshots',
  'results': 'Round results',
};

/// Blends the replay numbers into a 0-100 score, renormalised over whatever data exists.
/// 50 means "typical" against the reference values, which are assumptions, so the score is provisional.
ReplayScore scoreReplays(ReplaySummary s, {int teamKills = 0}) {
  final notes = <String>[];
  if (s.rounds < 3) {
    return ReplayScore(score: null, components: {for (final k in _weights.keys) k: null}, confidence: 'low', rounds: s.rounds, notes: const ['Needs at least 3 rounds.']);
  }
  double? n(double? v, double mean, double sd) => v == null ? null : normalize(v, mean, sd);
  final duels = s.openingKills + s.openingDeaths;
  final comp = <String, double?>{
    'impact': n(s.kost, 0.68, 0.12),
    'firepower': n(s.kills / s.rounds, 0.70, 0.30),
    'survival': n(s.survival, 0.35, 0.15),
    'opening': duels >= 4 ? n(s.openingRate, 0.5, 0.2) : null,
    'teamplay': s.deaths >= 4 ? (s.allTimed ? n(s.tradedRate, 0.30, 0.15) : n(s.avengedRate, 0.45, 0.20)) : null,
    'aim': s.kills >= 8 ? n(s.headshotRate, 0.40, 0.15) : null,
    'results': 100 * bayesRate(s.wins, s.rounds),
  };
  if (comp['opening'] == null) notes.add('Opening duels need at least 4 first fights.');
  if (comp['teamplay'] == null) notes.add('Teamplay needs at least 4 deaths.');
  if (comp['aim'] == null) notes.add('Headshots need at least 8 kills.');
  if (s.kostIsLowerBound) notes.add('Some rounds have no kill times, so KOST and trades are minimums.');
  final avail = {for (final e in comp.entries) if (e.value != null) e.key: e.value!};
  final totalW = avail.keys.fold<double>(0, (a, k) => a + _weights[k]!);
  var score = avail.entries.fold<double>(0, (a, e) => a + _weights[e.key]! * e.value) / totalW;
  final penalty = math.min(10.0, 3.0 * teamKills);
  if (penalty > 0) notes.add('$teamKills team kill${teamKills == 1 ? '' : 's'} cost ${penalty.toStringAsFixed(0)} points.');
  score = (score - penalty).clamp(0.0, 100.0);
  final coverage = avail.length / comp.length;
  final conf = (s.rounds >= 30 && coverage >= 0.85) ? 'high' : (s.rounds >= 12 && coverage >= 0.55 ? 'medium' : 'low');
  return ReplayScore(
    score: _r1(score),
    components: {for (final e in comp.entries) e.key: e.value == null ? null : _r1(e.value!)},
    confidence: conf,
    rounds: s.rounds,
    notes: notes,
    teamKillPenalty: penalty,
  );
}

// ---------- matches and improvement ----------

class MatchPoint {
  const MatchPoint({required this.matchId, required this.at, required this.map, required this.type, required this.rounds, required this.wins, required this.score, required this.kost, required this.kills, required this.deaths});
  final String matchId, map, type;
  final DateTime? at;
  final int rounds, wins, kills, deaths;
  final double? score, kost;
}

/// Per-match scores for one player, oldest first. Matches where the player played fewer than 3 rounds are left out.
List<MatchPoint> matchSeries(List<ReplayRound> rounds, String me) {
  final out = <MatchPoint>[];
  for (final g in groupMatches(rounds).reversed) {
    final mine = [for (final r in g) analyzeRound(r, me)].where((m) => m.present).toList();
    if (mine.length < 3) continue;
    final s = summarize(mine);
    out.add(MatchPoint(
      matchId: g.first.matchId,
      at: g.first.at,
      map: g.first.map,
      type: g.first.matchType,
      rounds: s.rounds,
      wins: s.wins,
      score: scoreReplays(s, teamKills: mine.fold(0, (a, m) => a + m.teamKills)).score,
      kost: s.kost,
      kills: s.kills,
      deaths: s.deaths,
    ));
  }
  return out;
}

enum Trend { improving, steady, slipping, unknown }

class MetricDelta {
  const MetricDelta(this.label, this.earlier, this.recent, {this.isPercent = true});
  final String label;
  final double earlier, recent;
  final bool isPercent;
  double get delta => recent - earlier;

  /// Large enough to mention: 4 points for percentages, 0.1 for per-round rates.
  bool get notable => delta.abs() >= (isPercent ? 0.04 : 0.1);
}

class Improvement {
  const Improvement({required this.series, required this.trend, required this.matchesNeeded, this.earlier, this.recent, this.earlierRounds = 0, this.recentRounds = 0, this.metrics = const []});
  final List<MatchPoint> series;
  final Trend trend;
  final int matchesNeeded; // how many more matches until a comparison is possible, 0 when there is one
  final double? earlier, recent;
  final int earlierRounds, recentRounds;
  final List<MetricDelta> metrics;

  double? get delta => (earlier == null || recent == null) ? null : recent! - earlier!;
  List<MetricDelta> get better => metrics.where((m) => m.notable && m.delta > 0).toList()..sort((a, b) => b.delta.abs().compareTo(a.delta.abs()));
  List<MetricDelta> get worse => metrics.where((m) => m.notable && m.delta < 0).toList()..sort((a, b) => b.delta.abs().compareTo(a.delta.abs()));
}

const minMatchesForTrend = 4;

/// Compares the older half of the player's saved matches with the newer half.
Improvement improvement(List<ReplayRound> rounds, String me) {
  final series = matchSeries(rounds, me);
  if (series.length < minMatchesForTrend) {
    return Improvement(series: series, trend: Trend.unknown, matchesNeeded: minMatchesForTrend - series.length);
  }
  final ordered = [for (final g in groupMatches(rounds).reversed) g].where((g) => series.any((p) => p.matchId == g.first.matchId)).toList();
  final cut = ordered.length ~/ 2;
  List<MyRound> pool(Iterable<List<ReplayRound>> gs) => [for (final g in gs) for (final r in g) analyzeRound(r, me)].where((m) => m.present).toList();
  final eMine = pool(ordered.take(cut)), rMine = pool(ordered.skip(cut));
  final e = summarize(eMine), r = summarize(rMine);
  final es = scoreReplays(e, teamKills: eMine.fold(0, (a, m) => a + m.teamKills)).score;
  final rs = scoreReplays(r, teamKills: rMine.fold(0, (a, m) => a + m.teamKills)).score;
  final metrics = <MetricDelta>[];
  void add(String l, double? a, double? b, {bool pctUnit = true}) {
    if (a != null && b != null) metrics.add(MetricDelta(l, a, b, isPercent: pctUnit));
  }

  add('KOST', e.kost, r.kost);
  add('Kills per round', e.rounds == 0 ? null : e.kills / e.rounds, r.rounds == 0 ? null : r.kills / r.rounds, pctUnit: false);
  add('Survival', e.survival, r.survival);
  add('Round wins', e.rounds == 0 ? null : e.wins / e.rounds, r.rounds == 0 ? null : r.wins / r.rounds);
  if (e.openingKills + e.openingDeaths >= 3 && r.openingKills + r.openingDeaths >= 3) add('Opening duels', e.openingRate, r.openingRate);
  if (e.deaths >= 3 && r.deaths >= 3) add('Deaths avenged', e.avengedRate, r.avengedRate);
  if (e.kills >= 5 && r.kills >= 5) add('Headshots', e.headshotRate, r.headshotRate);

  var trend = Trend.unknown;
  if (es != null && rs != null && e.rounds >= 8 && r.rounds >= 8) {
    final d = rs - es;
    trend = d >= 3 ? Trend.improving : (d <= -3 ? Trend.slipping : Trend.steady);
  }
  return Improvement(series: series, trend: trend, matchesNeeded: 0, earlier: es, recent: rs, earlierRounds: e.rounds, recentRounds: r.rounds, metrics: metrics);
}

// ---------- breakdowns ----------

class SideStat {
  const SideStat(this.attack, this.sum);
  final bool attack;
  final ReplaySummary sum;
  int get rounds => sum.rounds;
  double? get winRate => rounds == 0 ? null : sum.wins / rounds;
  double? get kpr => rounds == 0 ? null : sum.kills / rounds;
}

/// Attack and defense, in that order; a side with no rounds is omitted.
List<SideStat> sideSplit(List<MyRound> mine) => [
      for (final a in [true, false])
        if (mine.any((m) => m.attack == a && m.won != null)) SideStat(a, summarize(mine.where((m) => m.attack == a && m.won != null).toList())),
    ];

class OpeningImpact {
  const OpeningImpact(this.killRounds, this.killWins, this.deathRounds, this.deathWins, this.noneRounds, this.noneWins);
  final int killRounds, killWins, deathRounds, deathWins, noneRounds, noneWins;
  double? get afterKill => killRounds == 0 ? null : killWins / killRounds;
  double? get afterDeath => deathRounds == 0 ? null : deathWins / deathRounds;
  double? get otherwise => noneRounds == 0 ? null : noneWins / noneRounds;
}

/// How often the team won the round, split by how the player's own opening duel went.
OpeningImpact openingImpact(List<MyRound> mine) {
  int n(Opening o) => mine.where((m) => m.opening == o && m.won != null).length;
  int w(Opening o) => mine.where((m) => m.opening == o && m.won == true).length;
  return OpeningImpact(n(Opening.kill), w(Opening.kill), n(Opening.death), w(Opening.death), n(Opening.none), w(Opening.none));
}

class ClutchStat {
  const ClutchStat(this.attempts, this.wins, this.byOpponents);
  final int attempts, wins;
  final Map<int, (int, int)> byOpponents; // enemies alive -> (attempts, wins)
  double? get rate => attempts == 0 ? null : wins / attempts;
}

ClutchStat clutchStat(List<RoundExtra> ex) {
  final by = <int, (int, int)>{};
  var a = 0, w = 0;
  for (final x in ex.where((x) => x.clutch)) {
    a++;
    if (x.clutchWon) w++;
    final cur = by[x.clutchVs!] ?? (0, 0);
    by[x.clutchVs!] = (cur.$1 + 1, cur.$2 + (x.clutchWon ? 1 : 0));
  }
  return ClutchStat(a, w, by);
}

/// Rounds by kill count, from 2 kills up (index = kills, 5 includes more).
Map<int, int> multiKills(List<MyRound> mine) {
  final out = <int, int>{};
  for (final m in mine) {
    if (m.kills >= 2) out.update(math.min(5, m.kills), (v) => v + 1, ifAbsent: () => 1);
  }
  return out;
}

class Timing {
  const Timing({required this.kills, required this.deaths, required this.timedRounds, this.medianFirstKill, this.medianDeath});
  final List<int> kills, deaths; // six 30-second buckets of the round clock
  final int timedRounds;
  final double? medianFirstKill, medianDeath; // seconds into the round
  int get totalDeaths => deaths.fold(0, (a, b) => a + b);
  int get totalKills => kills.fold(0, (a, b) => a + b);
}

const timingBuckets = ['3:00', '2:30', '2:00', '1:30', '1:00', '0:30'];
const minTimedRounds = 5;

double? _median(List<int> v) {
  if (v.isEmpty) return null;
  final s = [...v]..sort();
  return s.length.isOdd ? s[s.length ~/ 2].toDouble() : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
}

/// When kills and deaths happen on the round clock. Only rounds with real kill times count.
Timing? timing(List<RoundExtra> ex) {
  final timed = ex.where((x) => x.my.round.timed).toList();
  if (timed.length < minTimedRounds) return null;
  final k = List.filled(6, 0), d = List.filled(6, 0);
  final firsts = <int>[], deaths = <int>[];
  for (final x in timed) {
    for (final e in x.my.round.events.where((e) => e.isKill)) {
      final t = _elapsed(e);
      if (t == null) continue;
      final b = math.min(5, t ~/ 30);
      final enemyKill = _same(e.actor, x.my.name) && x.my.player != null;
      if (enemyKill && !_isTeamKill(x.my.round, e)) k[b]++;
      if (_same(e.target, x.my.name)) d[b]++;
    }
    if (x.firstKillAt != null) firsts.add(x.firstKillAt!);
    if (x.deathAt != null) deaths.add(x.deathAt!);
  }
  return Timing(kills: k, deaths: d, timedRounds: timed.length, medianFirstKill: _median(firsts), medianDeath: _median(deaths));
}

bool _isTeamKill(ReplayRound r, ReplayEvent e) {
  int? team(String? n) {
    for (final p in r.players) {
      if (_same(p.name, n)) return p.team;
    }
    return null;
  }

  final a = team(e.actor);
  return a != null && a == team(e.target);
}

class OperatorLine {
  const OperatorLine(this.operator, this.sum);
  final String operator;
  final ReplaySummary sum;
  int get rounds => sum.rounds;
  double? get winRate => rounds == 0 ? null : sum.wins / rounds;
}

List<OperatorLine> operatorLines(List<MyRound> mine) {
  final by = <String, List<MyRound>>{};
  for (final m in mine) {
    final op = m.player?.operator;
    if (op != null && op.isNotEmpty) by.putIfAbsent(op, () => []).add(m);
  }
  return [for (final e in by.entries) OperatorLine(e.key, summarize(e.value))]..sort((a, b) => b.rounds.compareTo(a.rounds));
}

class MapLine {
  const MapLine(this.map, this.sum);
  final String map;
  final ReplaySummary sum;
  double? get winRate => sum.rounds == 0 ? null : sum.wins / sum.rounds;
}

List<MapLine> mapLines(List<MyRound> mine) {
  final by = <String, List<MyRound>>{};
  for (final m in mine) {
    by.putIfAbsent(m.round.map, () => []).add(m);
  }
  return [for (final e in by.entries) MapLine(e.key, summarize(e.value))]..sort((a, b) => b.sum.rounds.compareTo(a.sum.rounds));
}

// ---------- findings ----------

class ReplayFinding {
  const ReplayFinding({required this.id, required this.title, required this.evidence, required this.action, required this.tone, required this.sample, this.drill});
  final String id, title, evidence, action;
  final String? drill;
  final Tone tone;
  final int sample; // rounds (or events) the claim rests on
}

String _p(double v) => '${(v * 100).round()}%';

List<ReplayFinding> _findings(ReplayReport r) {
  final out = <ReplayFinding>[];
  final s = r.summary;
  if (s.rounds < 6) return out;

  final duels = s.openingKills + s.openingDeaths;
  if (duels >= 6 && s.openingRate != null) {
    final rate = s.openingRate!;
    if (rate < 0.4) {
      out.add(ReplayFinding(
        id: 'opening-low',
        title: 'You lose most first fights',
        evidence: 'You won ${s.openingKills} of $duels opening duels (${_p(rate)}).',
        action: 'Let a drone, a teammate or a utility piece make first contact, then take the fight. Avoid wide peeks into unchecked angles.',
        drill: 'In a Custom Game, do 10 shoulder-peeks per angle on one map before committing. Aim for 7 clean first shots.',
        tone: Tone.warn,
        sample: duels,
      ));
    } else if (rate >= 0.6) {
      out.add(ReplayFinding(id: 'opening-high', title: 'You win first fights', evidence: 'You won ${s.openingKills} of $duels opening duels (${_p(rate)}).', action: 'Keep taking early contact on your terms. Your team benefits when you open rounds.', tone: Tone.good, sample: duels));
    }
  }

  final oi = r.opening;
  if (oi.killRounds >= 3 && oi.deathRounds >= 3 && oi.afterKill != null && oi.afterDeath != null && (oi.afterKill! - oi.afterDeath!).abs() >= 0.15) {
    out.add(ReplayFinding(
      id: 'opening-swing',
      title: 'The first fight decides your rounds',
      evidence: 'Your team won ${_p(oi.afterKill!)} of rounds where you got the opening kill (${oi.killRounds}) and ${_p(oi.afterDeath!)} where you died first (${oi.deathRounds}).',
      action: oi.afterDeath! < oi.afterKill! ? 'A first death hurts your team a lot. Trade your angle for time before you commit.' : 'Your team recovers well after you lose the first fight.',
      tone: Tone.info,
      sample: oi.killRounds + oi.deathRounds,
    ));
  }

  final wasted = r.extras.where((x) => x.wastedDeath).length;
  if (s.deaths >= 6 && wasted / s.deaths >= 0.5) {
    out.add(ReplayFinding(
      id: 'wasted-deaths',
      title: 'Half your deaths gave nothing',
      evidence: '$wasted of ${s.deaths} deaths had no kill, no objective play and no one avenging you.',
      action: 'Before you push, check that a teammate can see the same angle. If you must die, make it cost them something.',
      drill: 'Play 3 rounds where you only take fights within sight of a teammate. Count how many deaths get avenged.',
      tone: Tone.warn,
      sample: s.deaths,
    ));
  }

  if (s.deaths >= 6) {
    final rate = s.allTimed ? s.tradedRate : s.avengedRate;
    if (rate != null) {
      final how = s.allTimed ? 'within 5 seconds' : 'at some point in the round';
      if (rate < 0.3) {
        out.add(ReplayFinding(
          id: 'trades-low',
          title: 'Your deaths are rarely avenged',
          evidence: 'Only ${_p(rate)} of your ${s.deaths} deaths were avenged $how.',
          action: 'Stay within one room of a teammate when you take a fight, so someone can answer right away.',
          drill: 'Call "pushing" before every fight for 3 matches. If nobody is in range, wait.',
          tone: Tone.warn,
          sample: s.deaths,
        ));
      } else if (rate >= 0.6) {
        out.add(ReplayFinding(id: 'trades-high', title: 'Your team backs you up', evidence: '${_p(rate)} of your ${s.deaths} deaths were avenged $how.', action: 'Good spacing. Keep fighting close to teammates.', tone: Tone.good, sample: s.deaths));
      }
    }
  }

  if (r.sides.length == 2 && r.sides.every((x) => x.rounds >= 8)) {
    final a = r.sides[0], d = r.sides[1];
    final gap = (a.winRate ?? 0) - (d.winRate ?? 0);
    if (gap.abs() >= 0.2) {
      final weak = gap < 0 ? a : d;
      out.add(ReplayFinding(
        id: 'side-gap',
        title: 'Your ${weak.attack ? 'attack' : 'defense'} rounds are weaker',
        evidence: 'You win ${_p(a.winRate ?? 0)} on attack (${a.rounds} rounds) and ${_p(d.winRate ?? 0)} on defense (${d.rounds} rounds).',
        action: weak.attack ? 'Practise attack setups: drone out the site early and plan your entry with the team.' : 'Practise defense setups: pick roam or anchor spots you know well and rotate on information.',
        tone: Tone.info,
        sample: a.rounds + d.rounds,
      ));
    }
  }

  final c = r.clutch;
  if (c.attempts >= 3) {
    if (c.wins == 0) {
      out.add(ReplayFinding(
        id: 'clutch-none',
        title: 'No clutches won yet',
        evidence: 'You were the last one alive ${c.attempts} times and won none.',
        action: 'Use the clock. Reposition after each kill, avoid re-peeking the same angle, and let them come to you.',
        drill: 'In Custom Game, practise 1v3 on one map: win by moving after every kill.',
        tone: Tone.warn,
        sample: c.attempts,
      ));
    } else if ((c.rate ?? 0) >= 0.4) {
      out.add(ReplayFinding(id: 'clutch-good', title: 'You close out rounds', evidence: 'You won ${c.wins} of ${c.attempts} clutch situations (${_p(c.rate!)}).', action: 'Keep it up. Calm play late in the round is working.', tone: Tone.good, sample: c.attempts));
    }
  }

  if (s.kills >= 15 && s.headshotRate != null) {
    if (s.headshotRate! < 0.30) {
      out.add(ReplayFinding(
        id: 'hs-low',
        title: 'Aim for the head more',
        evidence: '${_p(s.headshotRate!)} of your ${s.kills} kills were headshots.',
        action: 'Keep your crosshair at head height and pre-aim the places enemies appear.',
        drill: 'Spend 5 minutes in Shooting Range on head-height tracking before ranked.',
        tone: Tone.warn,
        sample: s.kills,
      ));
    } else if (s.headshotRate! >= 0.5) {
      out.add(ReplayFinding(id: 'hs-high', title: 'Your aim is sharp', evidence: '${_p(s.headshotRate!)} of your ${s.kills} kills were headshots.', action: 'Keep your crosshair placement as it is.', tone: Tone.good, sample: s.kills));
    }
  }

  if (r.teamKills > 0) {
    out.add(ReplayFinding(
      id: 'team-kills',
      title: 'Team kills',
      evidence: 'You killed a teammate ${r.teamKills} time${r.teamKills == 1 ? '' : 's'} in these rounds. Each costs score points.',
      action: 'Check your target before firing through doors and when swinging at close range.',
      tone: Tone.warn,
      sample: r.teamKills,
    ));
  }

  final t = r.timing;
  if (t != null && t.totalDeaths >= 6) {
    final early = t.deaths[0] / t.totalDeaths;
    if (early >= 0.4) {
      out.add(ReplayFinding(
        id: 'early-deaths',
        title: 'Many deaths come in the first 30 seconds',
        evidence: '${t.deaths[0]} of your ${t.totalDeaths} deaths happened in the first half-minute of the round.',
        action: 'Slow your opening. Use the early seconds to gather information instead of rushing contact.',
        tone: Tone.warn,
        sample: t.totalDeaths,
      ));
    }
  }

  final imp = r.improvement;
  if (imp.trend == Trend.improving || imp.trend == Trend.slipping) {
    final up = imp.trend == Trend.improving;
    out.add(ReplayFinding(
      id: 'trend',
      title: up ? 'You are improving' : 'Your recent matches are weaker',
      evidence: 'Your replay score is ${imp.recent!.toStringAsFixed(0)} in your newer matches against ${imp.earlier!.toStringAsFixed(0)} in the older ones (${imp.recentRounds} and ${imp.earlierRounds} rounds).',
      action: up ? 'Keep doing what you changed. Check which numbers rose in the Improvement card.' : 'Look at the Improvement card to see which numbers dropped, and take a break if you are on a losing streak.',
      tone: up ? Tone.good : Tone.warn,
      sample: imp.recentRounds + imp.earlierRounds,
    ));
  }

  final ops = r.operators.where((o) => o.rounds >= 6 && o.sum.kost != null).toList();
  if (ops.length >= 2) {
    ops.sort((a, b) => b.sum.kost!.compareTo(a.sum.kost!));
    final best = ops.first, worst = ops.last;
    if (best.sum.kost! - worst.sum.kost! >= 0.15) {
      out.add(ReplayFinding(
        id: 'operators',
        title: 'Your operator choice matters',
        evidence: '${best.operator}: ${_p(best.sum.kost!)} KOST over ${best.rounds} rounds. ${worst.operator}: ${_p(worst.sum.kost!)} over ${worst.rounds}.',
        action: 'Pick ${best.operator} more often, and treat ${worst.operator} as a practice pick until the numbers close.',
        tone: Tone.info,
        sample: best.rounds + worst.rounds,
      ));
    }
  }

  out.sort((a, b) => (a.tone == Tone.warn ? 0 : 1).compareTo(b.tone == Tone.warn ? 0 : 1));
  return out.take(8).toList();
}

// ---------- the report ----------

class ReplayReport {
  const ReplayReport({
    required this.me,
    required this.mine,
    required this.extras,
    required this.summary,
    required this.score,
    required this.improvement,
    required this.sides,
    required this.opening,
    required this.clutch,
    required this.multikills,
    required this.timing,
    required this.operators,
    required this.maps,
    required this.sites,
    required this.matches,
    required this.teamKills,
    required this.findings,
  });

  final String me;
  final List<MyRound> mine;
  final List<RoundExtra> extras;
  final ReplaySummary summary;
  final ReplayScore score;
  final Improvement improvement;
  final List<SideStat> sides;
  final OpeningImpact opening;
  final ClutchStat clutch;
  final Map<int, int> multikills;
  final Timing? timing;
  final List<OperatorLine> operators;
  final List<MapLine> maps;
  final List<SiteStat> sites;
  final int matches, teamKills;
  final List<ReplayFinding> findings;

  bool get hasRounds => summary.rounds > 0;
}

/// Everything the Replays tab shows, for one player over the given rounds. Cheap enough to rebuild on every change.
ReplayReport buildReplayReport(List<ReplayRound> rounds, String me, {bool withFindings = true}) {
  final mine = [for (final r in rounds) analyzeRound(r, me)].where((m) => m.present).toList();
  final extras = [for (final m in mine) extraFor(m)];
  final summary = summarize(mine);
  final tk = mine.fold<int>(0, (a, m) => a + m.teamKills);
  final base = ReplayReport(
    me: me,
    mine: mine,
    extras: extras,
    summary: summary,
    score: scoreReplays(summary, teamKills: tk),
    improvement: withFindings ? improvement(rounds, me) : const Improvement(series: [], trend: Trend.unknown, matchesNeeded: minMatchesForTrend),
    sides: sideSplit(mine),
    opening: openingImpact(mine),
    clutch: clutchStat(extras),
    multikills: multiKills(mine),
    timing: timing(extras),
    operators: operatorLines(mine),
    maps: mapLines(mine),
    sites: siteStats(mine),
    matches: {for (final m in mine) m.round.matchId}.length,
    teamKills: tk,
    findings: const [],
  );
  if (!withFindings) return base;
  return ReplayReport(
    me: base.me,
    mine: base.mine,
    extras: base.extras,
    summary: base.summary,
    score: base.score,
    improvement: base.improvement,
    sides: base.sides,
    opening: base.opening,
    clutch: base.clutch,
    multikills: base.multikills,
    timing: base.timing,
    operators: base.operators,
    maps: base.maps,
    sites: base.sites,
    matches: base.matches,
    teamKills: base.teamKills,
    findings: _findings(base),
  );
}
