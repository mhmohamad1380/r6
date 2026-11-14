import 'package:flutter/material.dart';

import '../../analytics/breakdowns.dart';
import '../../app_state.dart';
import '../../core/charts.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/snapshots.dart';
import 'context_card.dart';
import 'match_widgets.dart';

class MatchDetailScreen extends StatelessWidget {
  const MatchDetailScreen({super.key, required this.record, required this.state});
  final MatchRecord record;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final r = record;
    final c = resultColor(r);
    final score = r.score;
    final career = Totals.of('Career', state.operators);
    final game = state.gameByName;
    final hsRate = r.kills == 0 ? null : r.headshots / r.kills;
    final duels = r.firstBloods + r.firstDeaths;
    final entry = duels == 0 ? null : r.firstBloods / duels;
    final surv = r.rounds == 0 ? null : 1 - r.deaths / r.rounds;
    final rwr = r.rounds == 0 ? null : r.roundsWon / r.rounds;
    final clutchTries = r.clutches + r.clutchesLost;

    return Scaffold(
      appBar: AppBar(title: Text(modeLabel(r.mode)), backgroundColor: AppColors.bg, surfaceTintColor: Colors.transparent),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        AppCard(
          tint: c,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(resultTitle(r), style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: c)),
            const SizedBox(height: 4),
            Text('${dayLabel(r.at.toLocal())}, between ${clock(r.since.toLocal())} and ${clock(r.at.toLocal())}', style: const TextStyle(color: AppColors.textDim)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (r.rounds > 0) Pill('Rounds ${r.roundsWon}-${r.rounds - r.roundsWon}', color: AppColors.text),
              if (r.rpDelta != null) Pill('${signed(r.rpDelta!)} RP', color: r.rpDelta! >= 0 ? AppColors.good : AppColors.bad),
              if (r.rpAfter != null && r.mode == 'ranked') Pill('${r.rpAfter} RP now', color: AppColors.textDim),
              if (r.rank != null && r.mode == 'ranked') Pill(r.rank!, color: AppColors.accent),
            ]),
          ]),
        ),
        if (!r.exact) ...[
          const SizedBox(height: 12),
          const Notice('This covers more than one match because the app was not refreshed in between. Refresh right after each game for exact per-match numbers.', color: AppColors.warn),
        ],
        const SizedBox(height: 14),
        AppCard(
          child: Row(children: [
            GaugeRing(value: score.score, size: 108, label: 'score'),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ConfidenceChip(score.confidence),
                const SizedBox(height: 10),
                for (final e in score.components.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Row(children: [
                      SizedBox(width: 80, child: Text(e.key, style: const TextStyle(color: AppColors.textDim, fontSize: 12.5))),
                      Text(e.value?.toStringAsFixed(0) ?? '—', style: TextStyle(fontWeight: FontWeight.w800, color: scoreColor(e.value))),
                    ]),
                  ),
              ]),
            ),
          ]),
        ),
        const SectionTitle('Numbers'),
        Column(children: [
          _row3(
            _tile('Kills', '${r.kills}'),
            _tile('Deaths', '${r.deaths}'),
            _tile('Assists', '${r.assists}'),
          ),
          const SizedBox(height: 10),
          _row3(
            _tile('K/D', r.kd?.toStringAsFixed(2) ?? '—'),
            _tile('Headshots', '${r.headshots}', sub: hsRate == null ? null : pct(hsRate)),
            _tile('Multi-kills', '${r.multiKills}', sub: 'rounds with 2+'),
          ),
          const SizedBox(height: 10),
          _row3(
            _tile('Opening duels', duels == 0 ? '—' : '${r.firstBloods}-${r.firstDeaths}', sub: 'won-lost'),
            _tile('Clutches', clutchTries == 0 ? '—' : '${r.clutches}/$clutchTries', sub: 'won/tries'),
            _tile('Survived', surv == null ? '—' : pct(surv), sub: 'of rounds'),
          ),
        ]),
        const SectionTitle('Versus your career', subtitle: 'Green = better than your usual'),
        AppCard(
          child: Column(children: [
            _cmp('K/D', r.kd, career.kd, fmt: ratio),
            _cmp('Headshot %', hsRate, career.headshotRate, fmt: pct),
            _cmp('Opening duels won', entry, career.opening, fmt: pct),
            _cmp('Round win rate', rwr, career.roundWinRate, fmt: pct),
            _cmp('Rounds survived', surv, career.survival, fmt: pct),
          ]),
        ),
        const SectionTitle('Context', subtitle: 'Map, team and notes'),
        ContextCard(record: r, state: state),
        const SectionTitle('Operators used'),
        for (final o in r.ops)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: AppCard(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  OperatorIcon(name: o.name, url: game[o.name.toLowerCase()]?.iconUrl, attacker: o.attacker, size: 46),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(o.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      Text('${o.attacker ? 'Attack' : 'Defense'} · ${o.rounds} rounds', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5)),
                    ]),
                  ),
                  Text('${o.kills}/${o.deaths}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, fontFeatures: tabular)),
                ]),
                ..._counterHints(o.name),
              ]),
            ),
          ),
        const SizedBox(height: 8),
        const Text('Reconstructed from the change in your cumulative stats between two refreshes. Map and teammates are not available from the data source.', style: TextStyle(color: AppColors.textDim, fontSize: 11.5, height: 1.4)),
      ]),
    );
  }

  List<Widget> _counterHints(String op) {
    final by = state.counters.beatenBy(op).where((c) => c.level != 'minor').take(2).toList();
    if (by.isEmpty) return const [];
    return [
      const SizedBox(height: 10),
      Text('Watch out for: ${by.map((c) => c.from).map(_cap).join(', ')}', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
    ];
  }

  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Widget _row3(Widget a, Widget b, Widget c) => IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: a), const SizedBox(width: 10), Expanded(child: b), const SizedBox(width: 10), Expanded(child: c)]),
      );

  Widget _tile(String l, String v, {String? sub}) => AppCard(
        padding: const EdgeInsets.all(10),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l, style: const TextStyle(color: AppColors.textDim, fontSize: 11.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(v, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900, fontFeatures: tabular)),
          if (sub != null) Text(sub, style: const TextStyle(color: AppColors.textDim, fontSize: 10.5)),
        ]),
      );

  Widget _cmp(String label, double? now, double? base, {required String Function(double?) fmt}) {
    final better = (now != null && base != null) ? now >= base : null;
    final col = better == null ? AppColors.textDim : (better ? AppColors.good : AppColors.bad);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
        Text(fmt(now), style: TextStyle(fontWeight: FontWeight.w900, color: col, fontFeatures: tabular)),
        const SizedBox(width: 6),
        Icon(better == null ? Icons.remove : (better ? Icons.arrow_upward : Icons.arrow_downward), size: 15, color: col),
        const SizedBox(width: 10),
        SizedBox(width: 64, child: Text('avg ${fmt(base)}', textAlign: TextAlign.right, style: const TextStyle(color: AppColors.textDim, fontSize: 12))),
      ]),
    );
  }
}
