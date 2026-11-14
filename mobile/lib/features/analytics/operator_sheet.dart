import 'package:flutter/material.dart';

import '../../analytics/insights.dart';
import '../../analytics/scoring.dart';
import '../../app_state.dart';
import '../../core/charts.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/counters.dart';
import '../../data/models.dart';

void showOperatorSheet(BuildContext context, AppState s, OperatorStat o) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.86,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, controller) => _OperatorSheet(state: s, op: o, controller: controller),
    ),
  );
}

class _OperatorSheet extends StatelessWidget {
  const _OperatorSheet({required this.state, required this.op, required this.controller});
  final AppState state;
  final OperatorStat op;
  final ScrollController controller;

  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  @override
  Widget build(BuildContext context) {
    final g = state.gameByName[op.name.toLowerCase()];
    final score = scoreMatch(statsFor(op));
    final beats = state.counters.beats(op.name).take(5).toList();
    final beaten = state.counters.beatenBy(op.name).take(5).toList();
    final duels = (op.firstBloods ?? 0) + (op.firstDeaths ?? 0);
    final multi = [('2K', op.kills2), ('3K', op.kills3), ('4K', op.kills4), ('5K', op.kills5)];
    final maxMulti = multi.map((e) => e.$2 ?? 0).fold<int>(1, (a, b) => a > b ? a : b);
    return ListView(controller: controller, padding: const EdgeInsets.fromLTRB(20, 0, 20, 32), children: [
      Row(children: [
        OperatorIcon(name: op.name, url: g?.iconUrl, attacker: op.isAttacker, size: 68),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(op.name, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
            Text('${op.isAttacker ? 'Attacker' : 'Defender'}${(g?.season == null || g!.season == 'Y0S0') ? (g == null ? '' : ' · Original') : ' · ${g.season}'}', style: const TextStyle(color: AppColors.textDim)),
          ]),
        ),
        GaugeRing(value: score.score, size: 64),
      ]),
      if (g != null && g.roles.isNotEmpty) ...[
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: [for (final r in g.roles) Pill(r, color: AppColors.accent)]),
      ],
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: _tile('K/D', ratio(op.kd), '${op.kills ?? 0} / ${op.deaths ?? 0}')),
        const SizedBox(width: 10),
        Expanded(child: _tile('Round win', pct(op.roundWinRate), '${op.roundsWon ?? 0} of ${op.roundsPlayed ?? 0}')),
        const SizedBox(width: 10),
        Expanded(child: _tile('Entry', pct(op.openingWinRate), duels == 0 ? 'no duels' : '${op.firstBloods}-${op.firstDeaths}')),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _tile('Headshots', pct(op.headshotRate), '${op.headshots ?? 0}')),
        const SizedBox(width: 10),
        Expanded(child: _tile('Kills / round', ratio(op.killsPerRound), 'assists ${ratio(op.assistsPerRound)}')),
        const SizedBox(width: 10),
        Expanded(child: _tile('Clutch', pct(op.clutchRate), '${op.clutches ?? 0} won')),
      ]),
      const SectionTitle('Matches'),
      AppCard(
        child: Column(children: [
          WinLossBar(wins: op.matchesWon ?? 0, losses: op.matchesLost ?? 0),
          const SizedBox(height: 8),
          Row(children: [
            Text('${op.matchesWon ?? 0}W', style: const TextStyle(color: AppColors.good, fontWeight: FontWeight.w800)),
            Expanded(child: Text('${op.matchesPlayed ?? 0} played · ${hours(op.timePlayedMs ?? 0)}', textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textDim, fontSize: 12.5))),
            Text('${op.matchesLost ?? 0}L', style: const TextStyle(color: AppColors.bad, fontWeight: FontWeight.w800)),
          ]),
        ]),
      ),
      const SectionTitle('Multi-kill rounds'),
      AppCard(
        child: Column(children: [
          for (final m in multi) BarRow(label: m.$1, fraction: (m.$2 ?? 0) / maxMulti, valueText: '${m.$2 ?? 0}', color: AppColors.accent2),
          if ((op.teamKills ?? 0) > 0) Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(top: 6), child: Text('Team kills: ${op.teamKills}', style: const TextStyle(color: AppColors.warn, fontSize: 12.5)))),
        ]),
      ),
      if (beats.isNotEmpty) ...[
        const SectionTitle('Strong against', subtitle: 'Community counter data'),
        for (final c in beats) _counter(c, c.to),
      ],
      if (beaten.isNotEmpty) ...[
        const SectionTitle('Struggles against'),
        for (final c in beaten) _counter(c, c.from),
      ],
      if (beats.isEmpty && beaten.isEmpty) const Padding(padding: EdgeInsets.only(top: 18), child: Text('No counter data for this operator.', style: TextStyle(color: AppColors.textDim))),
    ]);
  }

  Widget _counter(Counter c, String other) {
    final col = switch (c.level) { 'hard' => AppColors.bad, 'soft' => AppColors.warn, _ => AppColors.textDim };
    final game = state.game.where((g) => opId(g.name) == other).firstOrNull;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          OperatorIcon(name: game?.name ?? other, url: game?.iconUrl, attacker: game == null ? null : game.side == 'Attacker', size: 38),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(game?.name ?? _cap(other), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800))),
                const SizedBox(width: 8),
                Pill('${c.level} counter', color: col),
              ]),
              const SizedBox(height: 4),
              Text(c.text, style: const TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.35)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _tile(String l, String v, String sub) => AppCard(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l, style: const TextStyle(color: AppColors.textDim, fontSize: 11.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(v, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, fontFeatures: tabular)),
          Text(sub, style: const TextStyle(color: AppColors.textDim, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      );
}
