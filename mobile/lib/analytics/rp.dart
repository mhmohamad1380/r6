import 'dart:math' as math;

import '../data/models.dart';

class RpDelta {
  const RpDelta(this.at, this.delta, this.rpAfter, this.rank);
  final DateTime at;
  final int delta, rpAfter;
  final String? rank;
  bool get win => delta > 0;
}

/// Ranked results inferred from consecutive RP readings (newest first).
/// A rise means a win and a fall means a loss; 0 is ignored. The source has no match feed.
class RpAnalysis {
  const RpAnalysis({
    required this.deltas,
    required this.wins,
    required this.losses,
    required this.avgWin,
    required this.avgLoss,
    required this.net,
    required this.best,
    required this.worst,
    required this.streak,
    required this.longestWinStreak,
    required this.longestLossStreak,
    required this.volatility,
    required this.recentNet,
    required this.priorNet,
  });

  final List<RpDelta> deltas;
  final int wins, losses;
  final double? avgWin, avgLoss; // avgLoss is positive magnitude
  final int net;
  final int? best, worst;
  final int streak; // +n current win streak, -n current loss streak
  final int longestWinStreak, longestLossStreak;
  final double? volatility;
  final int? recentNet, priorNet; // last 5 vs the 5 before

  int get games => wins + losses;
  double? get winRate => games == 0 ? null : wins / games;
  bool get hasData => deltas.isNotEmpty;

  /// Win rate needed to break even given the average gain/loss, or null if unknown.
  double? get breakEvenWinRate {
    if (avgWin == null || avgLoss == null) return null;
    return avgLoss! / (avgWin! + avgLoss!);
  }

  factory RpAnalysis.from(List<RpPoint> history) {
    final deltas = <RpDelta>[];
    for (var i = 0; i < history.length - 1; i++) {
      final d = history[i].rp - history[i + 1].rp;
      if (d != 0) deltas.add(RpDelta(history[i].at, d, history[i].rp, history[i].rank));
    }
    final w = deltas.where((d) => d.win).toList(), l = deltas.where((d) => !d.win).toList();
    double? avg(Iterable<int> v) => v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;

    var streak = 0;
    if (deltas.isNotEmpty) {
      final sign = deltas.first.win;
      for (final d in deltas) {
        if (d.win != sign) break;
        streak += sign ? 1 : -1;
      }
    }
    var lw = 0, ll = 0, cw = 0, cl = 0;
    for (final d in deltas.reversed) {
      if (d.win) {
        cw++;
        cl = 0;
      } else {
        cl++;
        cw = 0;
      }
      lw = math.max(lw, cw);
      ll = math.max(ll, cl);
    }
    double? vol;
    if (deltas.length >= 4) {
      final m = deltas.map((d) => d.delta).reduce((a, b) => a + b) / deltas.length;
      vol = math.sqrt(deltas.map((d) => math.pow(d.delta - m, 2)).reduce((a, b) => a + b) / deltas.length);
    }
    int sum(Iterable<RpDelta> x) => x.fold(0, (s, d) => s + d.delta);
    return RpAnalysis(
      deltas: deltas,
      wins: w.length,
      losses: l.length,
      avgWin: avg(w.map((d) => d.delta)),
      avgLoss: avg(l.map((d) => -d.delta)),
      net: sum(deltas),
      best: w.isEmpty ? null : w.map((d) => d.delta).reduce(math.max),
      worst: l.isEmpty ? null : l.map((d) => d.delta).reduce(math.min),
      streak: streak,
      longestWinStreak: lw,
      longestLossStreak: ll,
      volatility: vol,
      recentNet: deltas.length >= 10 ? sum(deltas.take(5)) : null,
      priorNet: deltas.length >= 10 ? sum(deltas.skip(5).take(5)) : null,
    );
  }
}
