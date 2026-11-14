import '../data/models.dart';
import 'insights.dart';
import 'stats.dart';

/// One spoke of the skill radar. score is null when the sample is too small to say.
class SkillAxis {
  const SkillAxis({required this.id, required this.label, required this.score, required this.value, required this.sample, required this.help});
  final String id, label, value, help;
  final double? score;
  final String sample;
}

/// Reference (mean, sd) per axis are design assumptions, not measured population values.
const _fragRef = (0.55, 0.20);
const _hsRef = (0.45, 0.15);
const _entryRef = (0.50, 0.12);
const _surviveRef = (0.35, 0.10);
const _supportRef = (0.12, 0.07);
const _clutchRef = (0.20, 0.12);
const _objectiveRef = (0.50, 0.07);

List<SkillAxis> skillProfile(List<OperatorStat> ops) {
  final a = aggregate(ops);
  final rounds = a.roundsPlayed ?? 0;
  double? score(double? v, (double, double) ref, bool enough) => (v == null || !enough) ? null : normalize(v, ref.$1, ref.$2);
  String f(double? v, {bool pct = false}) => v == null ? '—' : (pct ? '${(v * 100).toStringAsFixed(0)}%' : v.toStringAsFixed(2));

  double ratio(int? n, int? d) => (n == null || d == null || d == 0) ? double.nan : n / d;
  double? nn(double v) => v.isNaN ? null : v;

  final kpr = nn(ratio(a.kills, rounds));
  final hs = nn(ratio(a.headshots, a.kills));
  final duels = (a.openingKills ?? 0) + (a.openingDeaths ?? 0);
  final entry = duels == 0 ? null : (a.openingKills ?? 0) / duels;
  final dpr = nn(ratio(a.deaths, rounds));
  final survive = dpr == null ? null : 1 - dpr;
  final apr = nn(ratio(ops.fold<int>(0, (s, o) => s + (o.assists ?? 0)), rounds));
  final cw = ops.fold<int>(0, (s, o) => s + (o.clutches ?? 0));
  final cl = ops.fold<int>(0, (s, o) => s + (o.clutchesLost ?? 0));
  final clutch = (cw + cl) == 0 ? null : cw / (cw + cl);
  final obj = nn(ratio(a.roundsWon, rounds));

  return [
    SkillAxis(id: 'frag', label: 'Fragging', score: score(kpr, _fragRef, rounds >= 100), value: '${f(kpr)}/rd', sample: '$rounds rounds', help: 'Kills per round.'),
    SkillAxis(id: 'aim', label: 'Aim', score: score(hs, _hsRef, (a.kills ?? 0) >= 100), value: f(hs, pct: true), sample: '${a.kills ?? 0} kills', help: 'Share of kills that are headshots.'),
    SkillAxis(id: 'entry', label: 'Entry', score: score(entry, _entryRef, duels >= 30), value: f(entry, pct: true), sample: '$duels duels', help: 'Opening duels won (first kill or first death of a round).'),
    SkillAxis(id: 'survive', label: 'Survival', score: score(survive, _surviveRef, rounds >= 100), value: f(survive, pct: true), sample: '$rounds rounds', help: 'Rounds you do not die in, roughly.'),
    SkillAxis(id: 'support', label: 'Support', score: score(apr, _supportRef, rounds >= 100), value: '${f(apr)}/rd', sample: '$rounds rounds', help: 'Assists per round.'),
    SkillAxis(id: 'clutch', label: 'Clutch', score: score(clutch, _clutchRef, cw + cl >= 8), value: f(clutch, pct: true), sample: '${cw + cl} tries', help: 'Clutch situations converted into round wins.'),
    SkillAxis(id: 'objective', label: 'Objective', score: score(obj, _objectiveRef, rounds >= 100), value: f(obj, pct: true), sample: '$rounds rounds', help: 'Rounds your team won while you played.'),
  ];
}
