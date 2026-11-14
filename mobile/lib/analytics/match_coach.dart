import '../core/format.dart';
import '../data/replay.dart';
import 'insights.dart' show Tone;
import 'replay_report.dart';
import 'replay_stats.dart';

/// One thing that set a match apart from your usual level, in words, with the numbers behind it.
class Reason {
  const Reason(this.key, this.text, this.diff, {this.title = ''});
  final String key; // a score component: impact, firepower, survival, opening, teamplay, aim, results
  final String title; // the part of your game, in words: "Getting kills"
  final String text;
  final double diff; // match component minus the usual one, in score points
}

/// A match scored and explained: how you played, what lifted it, what dragged it.
class MatchReview {
  const MatchReview({
    required this.matchId,
    required this.map,
    required this.type,
    required this.at,
    required this.rounds,
    required this.wins,
    required this.score,
    required this.label,
    required this.vsUsual,
    required this.headline,
    required this.strengths,
    required this.weaknesses,
    required this.kills,
    required this.deaths,
  });
  final String matchId, map, type, label, headline;
  final DateTime? at;
  final int rounds, wins, kills, deaths;
  final double? score;
  final double? vsUsual; // this score minus the average of your other matches; null with fewer than 2 others
  final List<Reason> strengths, weaknesses;

  int get losses => rounds - wins;
  bool? get won => wins == losses ? null : wins > losses;
}

class CoachVerdict {
  const CoachVerdict({required this.headline, required this.detail, required this.strengths, required this.gap, required this.focus, required this.plan, required this.best, required this.worst});
  final String headline, detail;
  final List<Reason> strengths; // what you do well, strongest first
  final Reason? gap; // the weakest part of your game
  final ReplayFinding? focus; // the one thing to work on first
  final List<String> plan; // concrete things to try in the next session
  final MatchReview? best, worst;
}

class MatchCoach {
  const MatchCoach({required this.report, required this.reviews, required this.verdict});
  final ReplayReport report;
  final List<MatchReview> reviews; // newest first
  final CoachVerdict verdict;
}

const _drills = {
  'impact': 'In your next ranked games, aim to touch every round: a kill, the objective, a trade, or staying alive at the end.',
  'firepower': 'Hold one strong angle for the first 30 seconds instead of roaming; kills come from being set, not from moving.',
  'survival': 'Play the first minute for information, not kills. Stay alive until the round is decided.',
  'opening': 'Before you peek, ask whether a teammate or a drone already has that angle.',
  'teamplay': 'Stay within one room of a teammate until the first contact, so a death can be traded.',
  'aim': 'Spend 5 minutes in Shooting Range on head-height tracking before you queue.',
  'results': 'Play two rounds on your weaker side with one simple plan: pick the site first, then the roles.',
};

const _partTitles = {
  'impact': 'Staying involved',
  'firepower': 'Getting kills',
  'survival': 'Staying alive',
  'opening': 'First fights',
  'teamplay': 'Being traded',
  'aim': 'Headshots',
  'results': 'Winning rounds',
};

const _gapNames = {
  'impact': 'staying involved every round',
  'firepower': 'getting kills',
  'survival': 'staying alive',
  'opening': 'first fights',
  'teamplay': 'being traded by teammates',
  'aim': 'headshots',
  'results': 'winning rounds',
};

String _perRound(ReplaySummary s) => (s.kills / s.rounds).toStringAsFixed(1);

/// The sentence that says what a score component means, next to your usual number when there is one.
String _phrase(String key, ReplaySummary s, ReplaySummary? o) {
  String usual(String v) => o == null ? '' : ', usually $v';
  return switch (key) {
    'impact' => 'KOST ${pct(s.kost)}${usual(pct(o?.kost))}',
    'firepower' => '${_perRound(s)} kills per round${usual(o == null ? '' : _perRound(o))}',
    'survival' => 'Survived ${pct(s.survival)} of rounds${usual(pct(o?.survival))}',
    'opening' => 'Won ${s.openingKills} of ${s.openingKills + s.openingDeaths} first fights${usual(pct(o?.openingRate))}',
    'teamplay' => s.allTimed ? 'Teammates traded ${pct(s.tradedRate)} of your deaths${usual(pct(o?.tradedRate))}' : 'Teammates avenged ${pct(s.avengedRate)} of your deaths${usual(pct(o?.avengedRate))}',
    'aim' => 'Headshots ${pct(s.headshotRate)}${usual(pct(o?.headshotRate))}',
    _ => 'Your team won ${s.wins} of ${s.rounds} rounds',
  };
}

/// What kept a match from being a normal one: the components that moved most, up and down.
({List<Reason> up, List<Reason> down}) _reasons(ReplayScore m, ReplaySummary ms, ReplayScore usual, ReplaySummary us, bool haveUsual) {
  final up = <Reason>[], down = <Reason>[];
  for (final k in scoreComponentNames.keys) {
    final v = m.components[k];
    if (v == null) continue;
    final base = haveUsual ? usual.components[k] : 50.0; // one match only: compare with a typical player
    if (base == null) continue;
    final d = v - base;
    if (d >= 12 && v >= 50) up.add(Reason(k, _phrase(k, ms, haveUsual ? us : null), d));
    if (d <= -12 && v < 50) down.add(Reason(k, _phrase(k, ms, haveUsual ? us : null), d));
  }
  up.sort((a, b) => b.diff.compareTo(a.diff));
  down.sort((a, b) => a.diff.compareTo(b.diff));
  return (up: up.take(2).toList(), down: down.take(2).toList());
}

String _headline(double? score, String label, double? vs, bool? won) {
  if (score == null) return 'Too few rounds to score.';
  if (vs == null) return won == null ? '$label game.' : '${won ? 'Won' : 'Lost'}. $label game.';
  if (vs >= 8) return won == false ? 'Lost, but you played better than usual.' : (won == true ? 'Strong win: you played above your usual level.' : 'You played above your usual level.');
  if (vs <= -8) return won == true ? 'Won, but you played below your usual level.' : (won == false ? 'Rough game: below your usual level and a loss.' : 'You played below your usual level.');
  return won == null ? 'A typical game for you.' : (won ? 'A typical game for you, and a win.' : 'A typical game for you, but a loss.');
}

/// Scores every match, explains each against your own usual level, and boils everything down to what to do next.
MatchCoach buildMatchCoach(List<ReplayRound> rounds, String me) {
  final report = buildReplayReport(rounds, me);
  final built = <({String id, ReplayScore score, ReplaySummary sum, ReplayRound first})>[];
  for (final g in groupMatches(rounds)) {
    final mine = [for (final r in g) analyzeRound(r, me)].where((m) => m.present).toList();
    if (mine.length < 3) continue;
    final s = summarize(mine);
    built.add((id: g.first.matchId, score: scoreReplays(s, teamKills: mine.fold(0, (a, m) => a + m.teamKills)), sum: s, first: g.first));
  }
  final reviews = <MatchReview>[];
  for (final b in built) {
    final others = [for (final o in built) if (o.id != b.id && o.score.score != null) o.score.score!];
    final haveUsual = built.length >= 2 && report.score.score != null;
    final vs = (b.score.score != null && others.length >= 2) ? b.score.score! - others.reduce((a, c) => a + c) / others.length : null;
    final why = _reasons(b.score, b.sum, report.score, report.summary, haveUsual);
    final won = b.sum.wins == b.sum.losses ? null : b.sum.wins > b.sum.losses;
    reviews.add(MatchReview(
      matchId: b.id,
      map: b.first.map,
      type: b.first.matchType,
      at: b.first.at,
      rounds: b.sum.rounds,
      wins: b.sum.wins,
      score: b.score.score,
      label: b.score.label,
      vsUsual: vs,
      headline: _headline(b.score.score, b.score.label, vs, won),
      strengths: why.up,
      weaknesses: why.down,
      kills: b.sum.kills,
      deaths: b.sum.deaths,
    ));
  }

  final scored = [for (final r in reviews) if (r.score != null) r];
  MatchReview? best, worst;
  if (scored.length >= 2) {
    best = scored.reduce((a, c) => c.score! > a.score! ? c : a);
    worst = scored.reduce((a, c) => c.score! < a.score! ? c : a);
    if (best.matchId == worst.matchId) best = worst = null;
  }
  return MatchCoach(report: report, reviews: reviews, verdict: _verdict(report, best, worst));
}

CoachVerdict _verdict(ReplayReport r, MatchReview? best, MatchReview? worst) {
  final sc = r.score;
  if (sc.score == null) {
    return CoachVerdict(headline: 'Not enough replays to coach you yet.', detail: 'Play or import at least 3 rounds you were in.', strengths: const [], gap: null, focus: null, plan: const [], best: best, worst: worst);
  }
  final comps = [for (final e in sc.components.entries) if (e.value != null) (key: e.key, v: e.value!)]..sort((a, b) => b.v.compareTo(a.v));
  final strengths = [for (final c in comps.where((c) => c.v >= 58).take(2)) Reason(c.key, _phrase(c.key, r.summary, null), c.v - 50, title: _partTitles[c.key] ?? c.key)];
  final weakest = comps.isEmpty ? null : comps.last;
  final gap = (weakest != null && weakest.v < 46) ? Reason(weakest.key, _phrase(weakest.key, r.summary, null), weakest.v - 50, title: _partTitles[weakest.key] ?? weakest.key) : null;
  final imp = r.improvement;
  final d = imp.delta;
  String pts(double v) => v.abs().toStringAsFixed(v.abs() < 10 ? 1 : 0);
  final headline = imp.trend == Trend.improving && d != null
      ? 'You are improving: ${pts(d)} points up on your older matches.'
      : (imp.trend == Trend.slipping && d != null ? 'You are slipping: ${pts(d)} points down on your older matches.' : 'You are playing at ${_article(sc.label)} level.');
  final parts = <String>[
    if (strengths.isNotEmpty) 'Best part of your game: ${_gapNames[strengths.first.key]}.',
    if (gap != null) 'Biggest gap: ${_gapNames[gap.key]}.',
    if (strengths.isEmpty && gap == null) 'No part of your game stands out yet.',
  ];
  final warnings = [for (final f in r.findings) if (f.tone == Tone.warn) f];
  // The focus card already shows its own drill, so the plan is what comes after it.
  final drills = [for (final f in warnings.skip(1)) if (f.drill != null) f.drill!];
  final fallback = gap == null ? null : _drills[gap.key];
  return CoachVerdict(
    headline: headline,
    detail: parts.join(' '),
    strengths: strengths,
    gap: gap,
    focus: warnings.isEmpty ? null : warnings.first,
    plan: [...drills.take(3), if (drills.isEmpty && fallback != null && warnings.isEmpty) fallback],
    best: best,
    worst: worst,
  );
}

String _article(String label) {
  final l = label.toLowerCase();
  return '${'aeiou'.contains(l[0]) ? 'an' : 'a'} $l';
}
