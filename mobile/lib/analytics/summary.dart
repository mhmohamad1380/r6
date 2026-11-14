import '../data/models.dart';
import 'insights.dart';
import 'rp.dart';
import 'scoring.dart';

/// Plain-text profile summary for sharing. Contains only the player's own public stats.
String buildSummary(PlayerProfile p, List<OperatorStat> ops, RpAnalysis rp, {List<GameOperator> game = const []}) {
  final tot = aggregate(ops);
  final score = scoreMatch(tot);
  final r = p.ranked;
  String pc(double? v) => v == null ? '-' : '${(v * 100).toStringAsFixed(0)}%';
  final kd = (tot.kills != null && (tot.deaths ?? 0) > 0) ? (tot.kills! / tot.deaths!).toStringAsFixed(2) : '-';
  final duels = (tot.openingKills ?? 0) + (tot.openingDeaths ?? 0);
  final lines = <String>[
    '${p.name} - R6 Coach',
    '${p.currentRankName ?? 'Unranked'}${r?.rankPoints == null ? '' : ' (${r!.rankPoints} RP)'}',
    'K/D $kd | round wins ${pc(tot.roundsPlayed == null || tot.roundsPlayed == 0 ? null : (tot.roundsWon ?? 0) / tot.roundsPlayed!)} | entry ${pc(duels == 0 ? null : tot.openingKills! / duels)}',
    if (score.score != null) 'Performance ${score.score!.toStringAsFixed(0)}/100 (${score.confidence} confidence, provisional)',
    if (rp.games >= 5) 'Last ${rp.games} ranked games: ${rp.wins}W ${rp.losses}L, ${rp.net >= 0 ? '+' : ''}${rp.net} RP',
    if (buildInsights(ops, game: game, rp: rp, profile: p).isNotEmpty) 'Focus: ${buildInsights(ops, game: game, rp: rp, profile: p).first.title}',
  ];
  return lines.join('\n');
}
