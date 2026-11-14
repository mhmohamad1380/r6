import 'package:flutter/material.dart';

import '../../analytics/rank_progress.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Progress through the current division, with a cautious estimate of games to promote or drop.
class RankProgressCard extends StatelessWidget {
  const RankProgressCard({super.key, required this.progress, required this.color});
  final RankProgress progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    String? outlook;
    if (p.gamesToNext != null) {
      outlook = 'At your recent pace (${signed(p.expectedPerGame!.round())} RP per game) you would reach ${p.nextName} in about ${p.gamesToNext} games.';
    } else if (p.gamesToDrop != null) {
      outlook = 'At your recent pace (${signed(p.expectedPerGame!.round())} RP per game) you could drop a division in about ${p.gamesToDrop} games.';
    } else if (p.sample < 8) {
      outlook = 'Play ${8 - p.sample} more ranked games for a pace estimate.';
    }
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(p.band.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w800, color: color))),
          const SizedBox(width: 8),
          Flexible(child: Text(p.nextName ?? 'Top rank', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textDim, fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: 8),
        Semantics(
          label: '${p.toDrop} RP into ${p.band.name}${p.toNext == null ? '' : ', ${p.toNext} RP to ${p.nextName}'}',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: p.fraction),
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeOutCubic,
              builder: (_, v, _) => LinearProgressIndicator(value: v, minHeight: 12, backgroundColor: AppColors.surfaceHi, valueColor: AlwaysStoppedAnimation(color)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text('${p.toDrop} RP above demotion', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textDim, fontSize: 12.5))),
          if (p.toNext != null) ...[const SizedBox(width: 8), Text('${p.toNext} RP to go', maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5))],
        ]),
        if (outlook != null) ...[
          const SizedBox(height: 10),
          Text(outlook, style: const TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.4)),
        ],
      ]),
    );
  }
}
