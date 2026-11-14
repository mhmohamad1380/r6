import '../data/models.dart';
import 'breakdowns.dart';
import 'patterns.dart';
import 'rp.dart';
import 'scoring.dart';

/// Sums operator rows into one MatchStats. A field stays null when no operator reports it.
MatchStats aggregate(List<OperatorStat> ops, {String mode = 'ranked'}) {
  int? sum(int? Function(OperatorStat) f) {
    int? total;
    for (final o in ops) {
      final v = f(o);
      if (v != null) total = (total ?? 0) + v;
    }
    return total;
  }

  return MatchStats(
    mode: mode,
    roundsPlayed: sum((o) => o.roundsPlayed),
    roundsWon: sum((o) => o.roundsWon),
    kills: sum((o) => o.kills),
    deaths: sum((o) => o.deaths),
    headshots: sum((o) => o.headshots),
    openingKills: sum((o) => o.firstBloods),
    openingDeaths: sum((o) => o.firstDeaths),
  );
}

MatchStats statsFor(OperatorStat o, {String mode = 'ranked'}) => aggregate([o], mode: mode);

enum Tone { good, warn, info }

enum GoalMetric { opening, kd, headshot, roundWin, survival, clutch }

class Insight {
  const Insight({
    required this.id,
    required this.category,
    required this.title,
    required this.evidence,
    required this.action,
    required this.sample,
    required this.tone,
    this.metric,
    this.unit = 'rounds',
    this.drill,
  });
  final String id, category, title, evidence, action;
  final String? drill; // a concrete practice exercise, shown as "Try this"
  final int sample; // how much data the claim rests on, counted in [unit]
  final String unit;
  final Tone tone;
  final GoalMetric? metric; // set when the finding can become a trackable goal
}

/// Share of rounds on operators whose roles mark them as aggressive. Null without game data.
double? _entryStyleShare(List<OperatorStat> ops, List<GameOperator> game) {
  if (game.isEmpty) return null;
  const aggressive = {'Front Line', 'Flank', 'Roam'};
  final byName = {for (final g in game) g.key: g};
  var total = 0, entry = 0;
  for (final o in ops) {
    final r = o.roundsPlayed ?? 0;
    final g = byName[o.name.toLowerCase()];
    if (r == 0 || g == null) continue;
    total += r;
    if (g.roles.any(aggressive.contains)) entry += r;
  }
  return total == 0 ? null : entry / total;
}

String _pct(double v) => '${(v * 100).toStringAsFixed(0)}%';
String _x(double v) => v.toStringAsFixed(2);

/// Rule-based findings. Every rule has a minimum sample and states it. Most important first.
List<Insight> buildInsights(
  List<OperatorStat> ops, {
  List<GameOperator> game = const [],
  RpAnalysis? rp,
  PlayerProfile? profile,
}) {
  final out = <Insight>[];
  final all = aggregate(ops);
  final rounds = all.roundsPlayed ?? 0;
  if (rounds < 100) {
    return [
      Insight(
          id: 'sample', category: 'Data', title: 'Not enough data yet', evidence: 'Only $rounds rounds recorded. Findings need at least 100.',
          action: 'Play more rounds, then refresh.', sample: rounds, tone: Tone.info),
    ];
  }
  final tot = Totals.of('All', ops);

  // Opening duels. Judged against role: anchors and intel players are expected to take fewer.
  if (tot.opening != null && tot.fb + tot.fd >= 30) {
    final r = tot.opening!;
    final entryShare = _entryStyleShare(ops, game);
    final passive = entryShare != null && entryShare < 0.25;
    final roleNote = entryShare == null
        ? ''
        : passive
            ? ' Only ${_pct(entryShare)} of your rounds are on entry-style operators (Front Line, Flank, Roam), so fewer opening duels are normal for you.'
            : ' ${_pct(entryShare)} of your rounds are on entry-style operators, so opening duels are part of your job.';
    if (r < 0.4) {
      out.add(Insight(
          id: 'opening', drill: "Before ranked, spend five minutes in a custom game pre-aiming common angles, and practise peeking with a teammate positioned behind you.", category: 'Tactics', title: passive ? 'Opening duels are low, but your role is passive' : 'You lose most opening duels',
          evidence: 'Won ${tot.fb} of ${tot.fb + tot.fd} opening duels (${_pct(r)}).$roleNote',
          action: passive
              ? 'Avoid taking early fights you do not need. Trade for a teammate instead of peeking first.'
              : 'Review rounds where you die first. Let a teammate take first contact, or get info before you peek.',
          sample: rounds, tone: passive ? Tone.info : Tone.warn, metric: GoalMetric.opening));
    } else if (r > 0.58) {
      out.add(Insight(
          id: 'opening', drill: "Before ranked, spend five minutes in a custom game pre-aiming common angles, and practise peeking with a teammate positioned behind you.", category: 'Tactics', title: 'Strong opening duels',
          evidence: 'Won ${tot.fb} of ${tot.fb + tot.fd} opening duels (${_pct(r)}).$roleNote',
          action: 'Keep it up, and check that your entries come with trades behind them.', sample: rounds, tone: Tone.good));
    }
  }

  // Kills versus round outcome.
  final kd = tot.kd, wr = tot.roundWinRate;
  if (kd != null && wr != null) {
    if (kd < 0.8 && wr >= 0.5) {
      out.add(Insight(
          id: 'kd-vs-wins', drill: "Check three recent rounds: did your kills come before the objective was decided, or after?", category: 'Impact', title: 'Winning rounds despite a low K/D',
          evidence: 'Round win rate ${_pct(wr)} with a K/D of ${_x(kd)}.',
          action: 'Your results come from objective play and team support. K/D alone understates you.', sample: rounds, tone: Tone.info));
    } else if (kd >= 1.1 && wr < 0.5) {
      out.add(Insight(
          id: 'kd-vs-wins', drill: "Check three recent rounds: did your kills come before the objective was decided, or after?", category: 'Impact', title: 'Kills are not turning into wins',
          evidence: 'K/D ${_x(kd)} but round win rate ${_pct(wr)}.',
          action: 'Check whether your kills come late in rounds or after the objective is already lost.', sample: rounds, tone: Tone.warn));
    }
  }

  // Survival.
  final sv = tot.survival;
  if (sv != null && sv < 0.25) {
    out.add(Insight(
        id: 'survival', drill: "After first contact, fall back behind cover instead of re-peeking. Count how many rounds you die before the 1:30 mark and aim to lower it.", category: 'Tactics', title: 'You die in most rounds',
        evidence: 'About ${_pct(1 - sv)} of rounds end with you dead (${tot.deaths} deaths in ${tot.rounds} rounds).',
        action: 'Stay alive longer: fight near teammates and fall back after contact instead of re-peeking.',
        sample: rounds, tone: Tone.warn, metric: GoalMetric.survival));
  }

  // Attack versus defense.
  final atk = sideTotals(ops, true), def = sideTotals(ops, false);
  if (atk.rounds >= 100 && def.rounds >= 100 && atk.kd != null && def.kd != null && (atk.kd! - def.kd!).abs() >= 0.15) {
    final better = atk.kd! > def.kd! ? 'attack' : 'defense';
    out.add(Insight(
        id: 'side', drill: "Queue your weaker side first in Unranked for a few matches and note which sites cost you rounds.", category: 'Sides', title: 'Better on $better',
        evidence: 'Attack K/D ${_x(atk.kd!)} (${atk.rounds} rounds) vs defense K/D ${_x(def.kd!)} (${def.rounds} rounds).',
        action: 'Spend extra practice on your weaker side.', sample: atk.rounds + def.rounds, tone: Tone.info));
  }

  // Clutch.
  final cw = ops.fold<int>(0, (s, o) => s + (o.clutches ?? 0)), cl = ops.fold<int>(0, (s, o) => s + (o.clutchesLost ?? 0));
  if (cw + cl >= 15) {
    final r = cw / (cw + cl);
    if (r < 0.12) {
      out.add(Insight(
          id: 'clutch', drill: "Re-watch your last clutch losses and note where you rushed. In a clutch, use your drone or sound before moving.", category: 'Tactics', title: 'Clutches rarely land',
          evidence: 'Converted $cw of ${cw + cl} clutch situations (${_pct(r)}).',
          action: 'Practice isolating one enemy at a time and use sound and drone info before committing.',
          sample: cw + cl, tone: Tone.warn, metric: GoalMetric.clutch, unit: 'clutch situations'));
    } else if (r > 0.3) {
      out.add(Insight(
          id: 'clutch', drill: "Re-watch your last clutch losses and note where you rushed. In a clutch, use your drone or sound before moving.", category: 'Tactics', title: 'Reliable in clutches',
          evidence: 'Converted $cw of ${cw + cl} clutch situations (${_pct(r)}).',
          action: 'Great. Keep playing for the late-round pressure.', sample: cw + cl, tone: Tone.good, unit: 'clutch situations'));
    }
  }

  // Headshots.
  final hs = tot.headshotRate;
  if (hs != null && tot.kills >= 100) {
    if (hs < 0.3) {
      out.add(Insight(
          id: 'aim', drill: "Spend five minutes in the shooting range keeping your crosshair at head height while you strafe.", category: 'Aim', title: 'Low headshot share', evidence: 'Headshots are ${_pct(hs)} of ${tot.kills} kills.',
          action: 'Work on crosshair height in a custom game or the shooting range.', sample: rounds, tone: Tone.warn, metric: GoalMetric.headshot));
    } else if (hs > 0.55) {
      out.add(Insight(
          id: 'aim', drill: "Spend five minutes in the shooting range keeping your crosshair at head height while you strafe.", category: 'Aim', title: 'Excellent headshot share', evidence: 'Headshots are ${_pct(hs)} of ${tot.kills} kills.',
          action: 'Your crosshair placement is a strength.', sample: rounds, tone: Tone.good));
    }
  }

  // Multi-kills.
  final mk = multiKillRate(ops);
  if (mk != null && rounds >= 200) {
    final threes = ops.fold<int>(0, (s, o) => s + (o.kills3 ?? 0) + (o.kills4 ?? 0) + (o.kills5 ?? 0));
    out.add(Insight(
        id: 'multi', drill: "After a kill, shift to a nearby angle instead of leaving the area. Second kills usually come from the same fight.", category: 'Impact', title: mk >= 12 ? 'You find multi-kill rounds' : 'Multi-kill rounds are rare',
        evidence: '${mk.toStringAsFixed(1)} multi-kill rounds per 100 rounds, $threes of them with 3+ kills.',
        action: mk >= 12 ? 'Good: you convert fights into momentum.' : 'Rounds with 2+ kills decide games. Look for follow-up kills after the first.',
        sample: rounds, tone: mk >= 12 ? Tone.good : Tone.info));
  }

  // Operator spread, only among operators with enough rounds.
  final rated = ops.where((o) => (o.roundsPlayed ?? 0) >= 60 && o.kd != null).toList()..sort((a, b) => b.kd!.compareTo(a.kd!));
  if (rated.length >= 3) {
    final best = rated.first, worst = rated.last;
    out.add(Insight(
        id: 'spread', drill: "Play your weakest operator in Unranked on two maps you know well before judging them.", category: 'Operators', title: 'Operator spread',
        evidence: 'Best: ${best.name} (K/D ${_x(best.kd!)}, ${best.roundsPlayed} rounds). Weakest: ${worst.name} (K/D ${_x(worst.kd!)}, ${worst.roundsPlayed} rounds).',
        action: 'This is correlation, not cause: map and teammates also differ. Test the weakest operator in different situations before dropping it.',
        sample: best.roundsPlayed! + worst.roundsPlayed!, tone: Tone.info));
  }

  // Pool breadth.
  final pool = poolStats(ops, game);
  if (rounds >= 200 && pool.top3Share >= 0.7) {
    out.add(Insight(
        id: 'pool', drill: "Add one new operator per role and play each in Standard until you have 30 rounds on them.", category: 'Operators', title: 'A narrow operator pool',
        evidence: '${_pct(pool.top3Share)} of your rounds are on three operators (${pool.top1} alone: ${_pct(pool.top1Share)}).',
        action: 'A wider pool makes you harder to read and covers team gaps. Learn one new operator per role.', sample: rounds, tone: Tone.info));
  }

  // Role coverage.
  if (game.isNotEmpty) {
    final roles = roleTotals(ops, game);
    final solid = roles.where((r) => r.rounds >= 60 && r.kd != null).toList()..sort((a, b) => b.kd!.compareTo(a.kd!));
    if (solid.length >= 3) {
      final b = solid.first, w = solid.last;
      if ((b.kd! - w.kd!) >= 0.2) {
        out.add(Insight(
            id: 'roles', drill: "Practise your weaker role in Unranked until its numbers catch up.", category: 'Operators', title: 'Role gap',
            evidence: '${b.label} K/D ${_x(b.kd!)} (${b.rounds} rounds) vs ${w.label} K/D ${_x(w.kd!)} (${w.rounds} rounds).',
            action: 'Roles overlap, so read this loosely. Lean on your strong role and practice the weaker one in unranked.',
            sample: b.rounds + w.rounds, tone: Tone.info));
      }
    }
  }

  // Ranked RP behaviour.
  if (rp != null && rp.games >= 6) {
    final be = rp.breakEvenWinRate;
    if (rp.avgWin != null && rp.avgLoss != null && be != null && rp.winRate != null) {
      final wr = rp.winRate!;
      out.add(Insight(
          id: 'rp-edge', category: 'Ranked', title: wr >= be ? 'You are gaining RP' : 'You are losing RP',
          evidence: 'Wins average +${rp.avgWin!.toStringAsFixed(0)} RP, losses -${rp.avgLoss!.toStringAsFixed(0)} RP. '
              'You need ${_pct(be)} wins to break even and are at ${_pct(wr)} over the last ${rp.games} games.',
          action: wr >= be ? 'Keep your routine; this trend is healthy.' : 'Take a break after two losses in a row and re-check your operator choice.',
          sample: rp.games, tone: wr >= be ? Tone.good : Tone.warn, unit: 'games'));
    }
    final gap = timeGap(byTimeOfDay(rp.deltas));
    if (gap != null) {
      out.add(Insight(
          id: 'time-of-day', category: 'Ranked', title: 'You play better in the ${gap.best.label.toLowerCase()}',
          evidence: '${gap.best.label}: ${_pct(gap.best.winRate)} wins over ${gap.best.games} games. ${gap.worst.label}: ${_pct(gap.worst.winRate)} over ${gap.worst.games}.',
          action: 'Aim your ranked games at your best part of the day, and warm up in Unranked at other times.',
          drill: 'For one week, play ranked only in the ${gap.best.label.toLowerCase()} (${gap.best.range}) and compare.',
          sample: gap.best.games + gap.worst.games, tone: Tone.info, unit: 'games'));
    }
    if (rp.streak <= -3) {
      out.add(Insight(
          id: 'tilt', drill: "Take a 15-minute break after your third loss in a row.", category: 'Ranked', title: 'Loss streak: ${-rp.streak} in a row',
          evidence: 'Your last ${-rp.streak} ranked results were losses (${rp.deltas.take(-rp.streak).fold<int>(0, (s, d) => s + d.delta)} RP).',
          action: 'Stop for the day or switch to unranked. Streaks are rarely fixed by queuing again right away.', sample: rp.games, tone: Tone.warn, unit: 'games'));
    } else if (rp.streak >= 3) {
      out.add(Insight(
          id: 'hot', category: 'Ranked', title: 'Win streak: ${rp.streak} in a row',
          evidence: 'Your last ${rp.streak} ranked results were wins.', action: 'Ride it, but stop when you feel tired.', sample: rp.games, tone: Tone.good, unit: 'games'));
    }
    if (rp.recentNet != null && rp.priorNet != null && (rp.recentNet! - rp.priorNet!).abs() >= 60) {
      final up = rp.recentNet! > rp.priorNet!;
      out.add(Insight(
          id: 'form', category: 'Ranked', title: up ? 'Your form is improving' : 'Your form dipped',
          evidence: 'Last 5 games: ${rp.recentNet! >= 0 ? '+' : ''}${rp.recentNet} RP. The 5 before: ${rp.priorNet! >= 0 ? '+' : ''}${rp.priorNet} RP.',
          action: up ? 'Note what changed and repeat it.' : 'Compare your operators and queue times between the two stretches.', sample: rp.games, tone: up ? Tone.good : Tone.warn, unit: 'games'));
    }
  }

  // Mode comparison.
  if (profile != null) {
    final rows = modeRows(profile).where((m) => (m.matches ?? 0) >= 15 && m.kd != null).toList();
    final ranked = rows.where((m) => m.id == 'ranked').toList();
    final others = rows.where((m) => m.id != 'ranked').toList();
    if (ranked.isNotEmpty && others.isNotEmpty) {
      final r = ranked.first, o = others.reduce((a, b) => (a.matches ?? 0) >= (b.matches ?? 0) ? a : b);
      if ((o.kd! - r.kd!).abs() >= 0.2) {
        out.add(Insight(
            id: 'modes', category: 'Modes', title: o.kd! > r.kd! ? 'Better outside ranked' : 'Better in ranked',
            evidence: 'Ranked K/D ${_x(r.kd!)} (${r.matches} matches) vs ${o.label} K/D ${_x(o.kd!)} (${o.matches} matches).',
            action: o.kd! > r.kd! ? 'Ranked opponents are tougher, but check whether you play more cautiously or rushed there.' : 'Your focus is higher in ranked; bring it to other modes to warm up.',
            sample: (r.matches ?? 0) + (o.matches ?? 0), tone: Tone.info, unit: 'matches'));
      }
    }
  }

  // Team kills.
  final tk = ops.fold<int>(0, (s, o) => s + (o.teamKills ?? 0));
  if (tk >= 10 && tot.kills > 0 && tk / tot.kills > 0.02) {
    out.add(Insight(
        id: 'teamkills', drill: "Call out before every shot through a floor or wall, and wait for the answer.", category: 'Teamplay', title: 'Friendly fire is costing you',
        evidence: '$tk team kills out of ${tot.kills} kills (${_pct(tk / tot.kills)}).',
        action: 'Slow down on wall and floor fire, and call your position before shooting through surfaces.', sample: rounds, tone: Tone.warn));
  }

  if (out.isEmpty) {
    out.add(Insight(id: 'none', category: 'Data', title: 'No clear pattern', evidence: 'Nothing stands out across $rounds rounds.', action: 'Keep playing and check back.', sample: rounds, tone: Tone.info));
  }
  // Warnings first, then info, then strengths.
  int rank(Tone t) => switch (t) { Tone.warn => 0, Tone.info => 1, Tone.good => 2 };
  out.sort((a, b) => rank(a.tone).compareTo(rank(b.tone)));
  return out;
}
