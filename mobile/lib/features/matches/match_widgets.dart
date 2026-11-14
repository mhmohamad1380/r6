import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/charts.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/match_notes.dart';
import '../../data/snapshots.dart';
import 'match_detail_screen.dart';

String modeLabel(String m) => switch (m) { 'ranked' => 'Ranked', 'standard' => 'Standard', 'casual' => 'Quick Match', 'mixed' => 'Mixed modes', _ => 'Unranked' };

Color resultColor(MatchRecord r) => r.exact ? (r.won! ? AppColors.good : AppColors.bad) : (r.wins >= r.losses ? AppColors.accent : AppColors.warn);

String resultTitle(MatchRecord r) => r.exact ? (r.won! ? 'Victory' : 'Defeat') : '${r.matches} matches · ${r.wins}W ${r.losses}L';

class MatchCard extends StatelessWidget {
  const MatchCard({super.key, required this.record, required this.state});
  final MatchRecord record;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final r = record;
    final c = resultColor(r);
    final game = state.gameByName;
    final score = r.score;
    return AppCard(
      padding: EdgeInsets.zero,
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MatchDetailScreen(record: r, state: state))),
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border(left: BorderSide(color: c, width: 6))),
        child: Row(children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(resultTitle(r), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: c))),
                  if (r.rpDelta != null) Text('${signed(r.rpDelta!)} RP', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: r.rpDelta! >= 0 ? AppColors.good : AppColors.bad)),
                ]),
                const SizedBox(height: 4),
                Text('${modeLabel(r.mode)} · ${dayLabel(r.at.toLocal())} ${clock(r.at.toLocal())}', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5)),
                if (state.noteFor(r) != null && !state.noteFor(r)!.isEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    if (state.noteFor(r)!.map != null) Pill(state.noteFor(r)!.map!, color: AppColors.accent2, icon: Icons.map_outlined),
                    if (state.noteFor(r)!.party != null) Pill(partyLabel(state.noteFor(r)!.party!), color: AppColors.accent, icon: Icons.groups_2_outlined),
                    if ((state.noteFor(r)!.text ?? '').isNotEmpty) const Pill('note', color: AppColors.textDim, icon: Icons.notes),
                  ]),
                ],
                const SizedBox(height: 12),
                LayoutBuilder(builder: (context, c) {
                  // Operator icons yield space to the stats and gauge on narrow phones.
                  final icons = ((c.maxWidth - 215) / 44).floor().clamp(1, 3);
                  return Row(children: [
                    for (final o in r.ops.take(icons))
                      Padding(padding: const EdgeInsets.only(right: 6), child: OperatorIcon(name: o.name, url: game[o.name.toLowerCase()]?.iconUrl, attacker: o.attacker, size: 38)),
                    const Spacer(),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          _stat('K/D', r.kd == null ? '—' : r.kd!.toStringAsFixed(2)),
                          _stat('Kills', '${r.kills}'),
                          _stat('Rounds', r.rounds == 0 ? '—' : '${r.roundsWon}-${r.rounds - r.roundsWon}'),
                          const SizedBox(width: 8),
                          GaugeRing(value: score.score, size: 46),
                        ]),
                      ),
                    ),
                  ]);
                }),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _stat(String l, String v) => Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(v, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, fontFeatures: tabular)),
          Text(l, style: const TextStyle(color: AppColors.textDim, fontSize: 10.5)),
        ]),
      );
}
