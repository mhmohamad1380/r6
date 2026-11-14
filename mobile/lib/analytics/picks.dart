import '../data/models.dart';

class Pick {
  const Pick(this.op, this.score, this.winRate, this.rounds);
  final OperatorStat op;
  final double score; // shrunk round win rate, 0..1
  final double winRate; // raw round win rate
  final int rounds;
}

/// Ranks operators by round win rate pulled toward the player's own average, so 12 lucky rounds
/// can't outrank 200 solid ones. [strength] is how many rounds of "average" are mixed in.
List<Pick> operatorPicks(List<OperatorStat> ops, {required bool attacker, int minRounds = 40, double strength = 40}) {
  final all = ops.where((o) => (o.roundsPlayed ?? 0) > 0).toList();
  final rounds = all.fold<int>(0, (s, o) => s + (o.roundsPlayed ?? 0));
  final won = all.fold<int>(0, (s, o) => s + (o.roundsWon ?? 0));
  if (rounds == 0) return const [];
  final base = won / rounds;
  final picks = <Pick>[];
  for (final o in all.where((o) => o.isAttacker == attacker && (o.roundsPlayed ?? 0) >= minRounds && o.roundsWon != null)) {
    final r = o.roundsPlayed!;
    picks.add(Pick(o, (o.roundsWon! + strength * base) / (r + strength), o.roundsWon! / r, r));
  }
  picks.sort((a, b) => b.score.compareTo(a.score));
  return picks;
}
