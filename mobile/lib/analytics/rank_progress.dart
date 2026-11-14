import '../data/ranks.dart';
import 'rp.dart';

/// Where the player sits inside their division and what recent results imply.
class RankProgress {
  const RankProgress({
    required this.band,
    required this.rp,
    required this.toNext,
    required this.toDrop,
    required this.fraction,
    this.nextName,
    this.expectedPerGame,
    this.gamesToNext,
    this.gamesToDrop,
    this.sample = 0,
  });

  final RankBand band;
  final int rp;
  final int? toNext; // RP needed for the next division (null at the top)
  final int toDrop; // RP above the division floor
  final double fraction; // 0..1 through the current division
  final String? nextName;
  final double? expectedPerGame; // average RP change per game at the recent win rate
  final int? gamesToNext, gamesToDrop;
  final int sample;

  bool get climbing => (expectedPerGame ?? 0) > 0;
}

/// Games estimates use the player's own recent average gain/loss and win rate, so they are only
/// as good as that sample: they are hidden below 8 games and are never presented as promises.
RankProgress? rankProgress(int? rp, RankLadder ladder, RpAnalysis analysis) {
  if (rp == null) return null;
  final band = ladder.bandFor(rp);
  if (band == null) return null;
  final next = ladder.next(band);
  final toNext = (next == null || band.isTop) ? null : next.min - rp;
  final toDrop = rp - band.min;
  final frac = band.isTop ? 1.0 : ((rp - band.min) / band.width).clamp(0.0, 1.0);

  double? exp;
  int? gNext, gDrop;
  if (analysis.games >= 8 && analysis.avgWin != null && analysis.avgLoss != null && analysis.winRate != null) {
    exp = analysis.winRate! * analysis.avgWin! - (1 - analysis.winRate!) * analysis.avgLoss!;
    if (exp > 1 && toNext != null) gNext = (toNext / exp).ceil();
    if (exp < -1) gDrop = ((toDrop + 1) / -exp).ceil();
  }
  return RankProgress(
    band: band,
    rp: rp,
    toNext: toNext,
    toDrop: toDrop,
    fraction: frac,
    nextName: next?.name,
    expectedPerGame: exp,
    gamesToNext: gNext,
    gamesToDrop: gDrop,
    sample: analysis.games,
  );
}
