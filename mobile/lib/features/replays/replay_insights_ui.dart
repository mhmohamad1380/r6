import 'package:flutter/material.dart';

import '../../analytics/insights.dart' show Tone;
import '../../analytics/replay_report.dart';
import '../../analytics/replay_stats.dart';
import '../../core/charts.dart';
import '../../core/replay_charts.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

Widget statTile(String v, String l) => Column(children: [
      FittedBox(fit: BoxFit.scaleDown, child: Text(v, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, fontFeatures: tabular))),
      Text(l, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textDim, fontSize: 11.5)),
    ]);

String _plus(num v, {int digits = 0}) => '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(digits)}';

/// One decimal for small moves, none once the change is big enough that the decimal is noise.
String _pts(double v) => _plus(v, digits: v.abs() < 10 ? 1 : 0);

List<FlowRound> flowOf(ReplayReport r) => [
      for (final x in r.extras)
        FlowRound(
          number: x.my.round.number,
          kills: x.my.kills,
          died: x.my.died,
          attack: x.my.attack,
          won: x.my.won,
          opening: x.my.opening == Opening.kill ? 1 : (x.my.opening == Opening.death ? -1 : 0),
          clutch: x.clutchWon,
        ),
    ]..sort((a, b) => a.number.compareTo(b.number));

void showScoreInfo(BuildContext context, ReplayReport r) => showInfo(
      context,
      'Replay score',
      'A 0-100 grade for how you played in the rounds we have replays for. 50 is typical against the reference values below, higher is better.\n\n'
      'Impact (KOST) 30%: rounds with a kill, objective play, survival or a trade.\n'
      'Kills per round 20%.\n'
      'Opening duels 15%: the share of first fights you won.\n'
      'Survival 10%.\n'
      'Teamplay 10%: how often a teammate avenged your death.\n'
      'Round results 10%.\n'
      'Headshots 5%.\n\n'
      'Parts without enough data are left out and the rest count more. A team kill costs 3 points, up to 10.\n\n'
      'The reference values are assumptions, not measured from other players, so treat the score as a way to compare yourself with yourself over time. '
      '${r.score.notes.isEmpty ? '' : '\n${r.score.notes.join('\n')}'}',
    );

/// The plain number behind one score part, for the caption under its bar.
String scoreRaw(ReplayReport report, String key) {
  final s = report.summary;
  return switch (key) {
    'impact' => 'KOST ${pct(s.kost)}${s.kostIsLowerBound ? '+' : ''}',
    'firepower' => '${(s.kills / s.rounds).toStringAsFixed(2)} kills per round',
    'survival' => 'Survived ${pct(s.survival)} of rounds',
    'opening' => 'Won ${s.openingKills} of ${s.openingKills + s.openingDeaths} first fights',
    'teamplay' => s.allTimed ? '${pct(s.tradedRate)} traded within 5s' : '${pct(s.avengedRate)} avenged',
    'aim' => '${pct(s.headshotRate)} headshots',
    _ => '${s.wins}W ${s.losses}L',
  };
}

/// The score, what it means, and how it has moved.
class ScoreHero extends StatelessWidget {
  const ScoreHero({super.key, required this.report, this.title = 'Replay score', this.showBreakdown = true});
  final ReplayReport report;
  final String title;
  final bool showBreakdown;

  String _raw(String key) => scoreRaw(report, key);

  @override
  Widget build(BuildContext context) {
    final sc = report.score;
    final imp = report.improvement;
    final d = imp.delta;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          IconButton(tooltip: 'How is this scored?', visualDensity: VisualDensity.compact, onPressed: () => showScoreInfo(context, report), icon: const Icon(Icons.info_outline, size: 20, color: AppColors.textDim)),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          GaugeRing(value: sc.score, size: 104, label: 'of 100'),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(sc.label, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: scoreColor(sc.score)))),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                Pill(sc.confidence == 'high' ? 'High confidence' : (sc.confidence == 'medium' ? 'Medium confidence' : 'Low confidence'), color: sc.confidence == 'high' ? AppColors.good : (sc.confidence == 'medium' ? AppColors.warn : AppColors.textDim)),
                if (d != null && imp.trend != Trend.unknown) DeltaChip('${_pts(d)} vs earlier', up: d >= 0, neutral: imp.trend == Trend.steady),
              ]),
              const SizedBox(height: 6),
              Text('${sc.rounds} round${sc.rounds == 1 ? '' : 's'}${report.matches > 1 ? ' in ${report.matches} matches' : ''}', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5)),
            ]),
          ),
        ]),
        if (showBreakdown && sc.score != null && sc.components.values.where((v) => v != null).length >= 3) ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _extreme('Strongest', sc, true)),
            const SizedBox(width: 8),
            Expanded(child: _extreme('Work on', sc, false)),
          ]),
        ],
        if (showBreakdown && sc.score != null) ...[
          const SizedBox(height: 10),
          for (final k in scoreComponentNames.keys)
            if (sc.components[k] != null) BarRow(label: scoreComponentNames[k]!, fraction: sc.components[k]! / 100, valueText: sc.components[k]!.round().toString(), color: scoreColor(sc.components[k]), caption: _raw(k)),
          if (sc.teamKillPenalty > 0) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Team kills: −${sc.teamKillPenalty.round()} points', style: const TextStyle(color: AppColors.bad, fontSize: 12.5, fontWeight: FontWeight.w700))),
        ],
        if (sc.score == null) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Add at least 3 rounds you played to get a score.', style: TextStyle(color: AppColors.textDim, fontSize: 12.5))),
      ]),
    );
  }
}

Widget _extreme(String title, ReplayScore sc, bool best) {
  final e = sc.components.entries.where((x) => x.value != null).toList()..sort((a, b) => best ? b.value!.compareTo(a.value!) : a.value!.compareTo(b.value!));
  final k = e.first;
  final c = best ? AppColors.good : AppColors.warn;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(color: c.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12), border: Border.all(color: c.withValues(alpha: 0.35))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(color: c, fontSize: 11.5, fontWeight: FontWeight.w800)),
      Text(scoreComponentNames[k.key] ?? k.key, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
      Text('${k.value!.round()} / 100', style: const TextStyle(color: AppColors.textDim, fontSize: 12, fontFeatures: tabular)),
    ]),
  );
}

Color _toneColor(Tone t) => switch (t) { Tone.good => AppColors.good, Tone.warn => AppColors.warn, Tone.info => AppColors.accent2 };
IconData _toneIcon(Tone t) => switch (t) { Tone.good => Icons.check_circle_outline, Tone.warn => Icons.warning_amber_rounded, Tone.info => Icons.lightbulb_outline };

/// The top findings first; the rest one tap away, so the tab is not a wall of text.
class FindingList extends StatefulWidget {
  const FindingList(this.items, {super.key, this.initiallyShown = shown});
  final List<ReplayFinding> items;
  final int initiallyShown;

  static const shown = 3;

  @override
  State<FindingList> createState() => _FindingListState();
}

class _FindingListState extends State<FindingList> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final more = items.length - widget.initiallyShown;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final f in _all || more <= 0 ? items : items.take(widget.initiallyShown)) FindingCard(f),
      if (more > 0)
        TextButton.icon(
          onPressed: () => setState(() => _all = !_all),
          icon: Icon(_all ? Icons.expand_less : Icons.expand_more),
          label: Text(_all ? 'Show fewer' : 'Show $more more finding${more == 1 ? '' : 's'}'),
        ),
    ]);
  }
}

class FindingCard extends StatelessWidget {
  const FindingCard(this.f, {super.key});
  final ReplayFinding f;

  @override
  Widget build(BuildContext context) {
    final c = _toneColor(f.tone);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.outline)),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 4, decoration: BoxDecoration(color: c, borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)))),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(_toneIcon(f.tone), size: 18, color: c),
                  const SizedBox(width: 8),
                  Expanded(child: Text(f.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
                ]),
                const SizedBox(height: 6),
                Text(f.evidence, style: const TextStyle(color: AppColors.textDim, fontSize: 13, height: 1.35)),
                const SizedBox(height: 6),
                Text(f.action, style: const TextStyle(fontSize: 13.5, height: 1.35)),
                if (f.drill != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: AppColors.surfaceHi, borderRadius: BorderRadius.circular(10)),
                    child: Text.rich(TextSpan(children: [const TextSpan(text: 'Try this: ', style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.accent)), TextSpan(text: f.drill)]), style: const TextStyle(fontSize: 12.5, height: 1.35)),
                  ),
                ],
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

Widget improvementCard(BuildContext context, ReplayReport r) {
  final imp = r.improvement;
  final pts = [
    for (final p in imp.series)
      if (p.score != null) TrendPoint(p.score!, '${p.map} · ${p.type}${p.at == null ? '' : ' · ${dayLabel(p.at!.toLocal())}'} · ${p.wins}W ${p.rounds - p.wins}L', good: p.score! >= 50),
  ];
  final (String, Color, IconData) verdict = switch (imp.trend) {
    Trend.improving => ('Improving', AppColors.good, Icons.trending_up),
    Trend.slipping => ('Slipping', AppColors.bad, Icons.trending_down),
    Trend.steady => ('Steady', AppColors.textDim, Icons.trending_flat),
    Trend.unknown => ('Not enough data yet', AppColors.textDim, Icons.hourglass_empty),
  };
  return AppCard(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(verdict.$3, color: verdict.$2),
        const SizedBox(width: 8),
        Expanded(child: Text(verdict.$1, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: verdict.$2))),
        if (imp.delta != null && imp.trend != Trend.unknown) DeltaChip('${_pts(imp.delta!)} pts', up: imp.delta! >= 0, neutral: imp.trend == Trend.steady),
      ]),
      const SizedBox(height: 10),
      if (pts.length >= 2) TrendChart(points: pts),
      if (imp.matchesNeeded > 0) ...[
        const SizedBox(height: 10),
        ClipRRect(borderRadius: BorderRadius.circular(6), child: LinearProgressIndicator(value: imp.series.length / minMatchesForTrend, minHeight: 8, backgroundColor: AppColors.surfaceHi, valueColor: const AlwaysStoppedAnimation(AppColors.accent))),
        const SizedBox(height: 8),
        Text('Save ${imp.matchesNeeded} more match${imp.matchesNeeded == 1 ? '' : 'es'} with you in them to compare your newer games with your older ones.', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.35)),
      ] else if (imp.earlier != null && imp.recent != null) ...[
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _period('Older', imp.earlier!, imp.earlierRounds)),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward, size: 18, color: AppColors.textDim)),
          Expanded(child: _period('Newer', imp.recent!, imp.recentRounds)),
        ]),
        if (imp.trend == Trend.unknown) const Padding(padding: EdgeInsets.only(top: 8), child: Notice('One side has under 8 rounds, so no call is made yet.', color: AppColors.textDim)),
        if (imp.better.isNotEmpty || imp.worse.isNotEmpty) const SizedBox(height: 10),
        for (final m in imp.better.take(3)) _metricRow(m),
        for (final m in imp.worse.take(3)) _metricRow(m),
      ],
    ]),
  );
}

Widget _fromTo(String a, String b) => FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text(a, style: const TextStyle(color: AppColors.textDim, fontSize: 12, fontFeatures: tabular)),
      const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Icon(Icons.arrow_forward, size: 12, color: AppColors.textDim)),
      Text(b, style: const TextStyle(color: AppColors.text, fontSize: 12, fontWeight: FontWeight.w700, fontFeatures: tabular)),
    ]));

Widget _period(String name, double score, int rounds) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: AppColors.surfaceHi, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$name matches', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textDim, fontSize: 11.5)),
        Text(score.toStringAsFixed(0), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: scoreColor(score), fontFeatures: tabular)),
        Text('$rounds rounds', style: const TextStyle(color: AppColors.textDim, fontSize: 11.5)),
      ]),
    );

Widget _metricRow(MetricDelta m) {
  String f(double v) => m.isPercent ? pct(v) : v.toStringAsFixed(2);
  final d = m.isPercent ? '${_plus(m.delta * 100)} pts' : _plus(m.delta, digits: 2);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(m.label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
          _fromTo(f(m.earlier), f(m.recent)),
        ]),
      ),
      const SizedBox(width: 8),
      Flexible(child: DeltaChip(d, up: m.delta > 0)),
    ]),
  );
}

/// One row per metric: attack value, a bar growing out from the middle each way, defense value.
Widget _sideMetric(String title, SideStat? a, SideStat? d, double? Function(SideStat) v, String Function(double?) fmt, {double scale = 1}) {
  final x = a == null ? null : v(a), y = d == null ? null : v(d);
  Widget bar(double? val, Color c, bool left) => Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Container(
            height: 8,
            color: AppColors.surfaceHi,
            alignment: left ? Alignment.centerRight : Alignment.centerLeft,
            child: FractionallySizedBox(widthFactor: ((val ?? 0) / scale).clamp(0.0, 1.0), child: Container(color: c)),
          ),
        ),
      );
  Widget value(double? val, bool has, Color c, TextAlign al) => SizedBox(width: 52, child: Text(has ? fmt(val) : '—', textAlign: al, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: c, fontFeatures: tabular)));
  final better = x != null && y != null && (x - y).abs() > 1e-9 ? (x > y ? 0 : 1) : -1;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Semantics(
      label: '$title: attack ${a == null ? 'none' : fmt(x)}, defense ${d == null ? 'none' : fmt(y)}',
      excludeSemantics: true,
      child: Column(children: [
        Text(title, style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
        const SizedBox(height: 4),
        Row(children: [
          value(x, a != null, better == 0 ? AppColors.attack : AppColors.text, TextAlign.left),
          bar(x, AppColors.attack, true),
          const SizedBox(width: 3),
          bar(y, AppColors.defense, false),
          value(y, d != null, better == 1 ? AppColors.defense : AppColors.text, TextAlign.right),
        ]),
      ]),
    ),
  );
}

Widget _sideCard(ReplayReport r) {
  SideStat? side(bool a) => r.sides.where((s) => s.attack == a).firstOrNull;
  final a = side(true), d = side(false);
  return AppCard(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('Attack · ${a?.rounds ?? 0} rounds', style: const TextStyle(color: AppColors.attack, fontSize: 12.5, fontWeight: FontWeight.w800))),
        Expanded(child: Text('Defense · ${d?.rounds ?? 0} rounds', textAlign: TextAlign.right, style: const TextStyle(color: AppColors.defense, fontSize: 12.5, fontWeight: FontWeight.w800))),
      ]),
      const SizedBox(height: 4),
      _sideMetric('Rounds won', a, d, (s) => s.winRate, (x) => pct(x)),
      _sideMetric('KOST', a, d, (s) => s.sum.kost, (x) => pct(x)),
      _sideMetric('Kills per round', a, d, (s) => s.kpr, (x) => x == null ? '—' : x.toStringAsFixed(2), scale: 1.5),
      _sideMetric('Survived', a, d, (s) => s.sum.survival, (x) => pct(x)),
      if ((a?.rounds ?? 0) < 6 || (d?.rounds ?? 0) < 6) const Padding(padding: EdgeInsets.only(top: 4), child: Text('One side has under 6 rounds, so treat the gap as a hint.', style: TextStyle(color: AppColors.textDim, fontSize: 11.5))),
    ]),
  );
}

Widget _openingCard(ReplayReport r) {
  final o = r.opening;
  Widget row(String label, double? f, int n, Color c) => BarRow(label: label, fraction: f, valueText: f == null ? '—' : '${pct(f)} ($n)', color: c, caption: n < 4 && n > 0 ? 'only $n rounds' : null);
  return AppCard(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('How often your team won the round', style: TextStyle(color: AppColors.textDim, fontSize: 12.5)),
      if (o.killRounds > 0) row('When you win the first fight', o.afterKill, o.killRounds, AppColors.good),
      if (o.deathRounds > 0) row('When you lose the first fight', o.afterDeath, o.deathRounds, AppColors.bad),
      if (o.noneRounds > 0) row('When you are not in it', o.otherwise, o.noneRounds, AppColors.accent),
      if (o.killRounds + o.deathRounds == 0) const Text('You were not part of an opening duel in these rounds.', style: TextStyle(color: AppColors.textDim)),
    ]),
  );
}

Widget _impactCard(ReplayReport r) {
  final c = r.clutch;
  final won = c.byOpponents.entries.where((e) => e.value.$2 > 0).map((e) => e.key).fold<int>(0, (a, b) => b > a ? b : a);
  const names = {2: '2K', 3: '3K', 4: '4K', 5: 'Ace'};
  return AppCard(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: statTile(c.attempts == 0 ? '—' : '${c.wins}/${c.attempts}', 'Clutches')),
        for (final k in [2, 3, 4, 5]) Expanded(child: statTile('${r.multikills[k] ?? 0}', names[k]!)),
      ]),
      const SizedBox(height: 10),
      Text(
        c.attempts == 0 ? 'You were never the last one alive on your team.' : (won > 0 ? 'Biggest clutch won: 1v$won. Rounds with a gold border in the match view are clutches you won.' : 'You were the last one alive ${c.attempts} time${c.attempts == 1 ? '' : 's'} and did not win the round.'),
        style: const TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.35),
      ),
    ]),
  );
}

Widget _timingCard(ReplayReport r) {
  final t = r.timing!;
  String clock(double? s) => s == null ? '—' : '${(180 - s) ~/ 60}:${((180 - s) % 60).round().toString().padLeft(2, '0')}';
  return AppCard(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TimeHistogram(kills: t.kills, deaths: t.deaths, labels: timingBuckets),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: statTile(clock(t.medianFirstKill), 'Typical first kill')),
        Expanded(child: statTile(clock(t.medianDeath), 'Typical death')),
        Expanded(child: statTile('${t.timedRounds}', 'Timed rounds')),
      ]),
      const SizedBox(height: 8),
      const Text('Times are on the round clock, counting down from 3:00. Only rounds with exact kill times are used.', style: TextStyle(color: AppColors.textDim, fontSize: 11.5, height: 1.35)),
    ]),
  );
}

Widget _operatorCard(ReplayReport r) => AppCard(
      child: Column(children: [
        for (final o in r.operators.take(6))
          BarRow(
            label: o.operator,
            fraction: o.sum.kost,
            valueText: 'KOST ${pct(o.sum.kost)}${o.sum.kostIsLowerBound ? '+' : ''}',
            color: scoreColor(o.sum.kost == null ? null : o.sum.kost! * 100 - 10),
            caption: '${o.rounds} round${o.rounds == 1 ? '' : 's'} · ${o.sum.kills}K ${o.sum.deaths}D · ${pct(o.winRate)} won${o.rounds < 4 ? ' · too few to trust' : ''}',
          ),
      ]),
    );

Widget _mapCard(ReplayReport r) => AppCard(
      child: Column(children: [
        for (final m in r.maps.take(5))
          BarRow(
            label: m.map,
            fraction: m.winRate,
            valueText: '${pct(m.winRate)} (${m.sum.rounds})',
            color: (m.winRate ?? 0) >= 0.5 ? AppColors.good : AppColors.warn,
            caption: 'KOST ${pct(m.sum.kost)}${m.sum.kostIsLowerBound ? '+' : ''} · ${m.sum.kills}K ${m.sum.deaths}D${m.sum.rounds < 4 ? ' · too few to trust' : ''}',
          ),
      ]),
    );

/// One collapsible block of detail. [preview] is the one line you see without opening it.
class DetailSection {
  const DetailSection(this.title, this.preview, this.body, {this.icon = Icons.bar_chart});
  final String title, preview;
  final Widget body;
  final IconData icon;
}

Widget _bombsiteCard(ReplayReport r) => AppCard(
      child: Column(children: [
        for (final x in r.sites.take(6))
          BarRow(
            label: '${x.map} · ${x.site}',
            fraction: x.winRate,
            valueText: '${pct(x.winRate)} (${x.rounds})',
            color: x.winRate >= 0.5 ? AppColors.good : AppColors.warn,
            caption: '${x.attack ? 'Attack' : 'Defense'} · ${x.wins}W ${x.rounds - x.wins}L${x.rounds < 4 ? ' · too few to trust' : ''}',
          ),
      ]),
    );

Widget _kostNumbers(BuildContext context, ReplayReport r) {
  final s = r.summary;
  return AppCard(
    child: Column(children: [
      Row(children: [
        Expanded(child: statTile('${pct(s.kost)}${s.kostIsLowerBound ? '+' : ''}', 'KOST')),
        Expanded(child: statTile(ratio(s.kd), 'K/D')),
        Expanded(child: statTile(pct(s.openingRate), 'Opening duels')),
        Expanded(child: statTile(pct(s.survival), 'Survived')),
      ]),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 36), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onPressed: () => showInfo(context, 'What is KOST?', 'KOST is the share of rounds where you did at least one of these:\n\nK  Kill: you got a kill.\nO  Objective: you planted or defused.\nS  Survived: you were alive at the end.\nT  Traded: you died, but a teammate killed your killer within 5 seconds.\n\nA KOST of 67% means you helped in about two of every three rounds. It is steadier than K/D because a round where you survived or set up a teammate still counts.'),
          icon: const Icon(Icons.help_outline, size: 16),
          label: const Text('What is KOST?'),
        ),
      ),
      if (s.kostIsLowerBound) const Text('KOST is a minimum: some rounds have no kill times, so trades were not counted.', style: TextStyle(color: AppColors.textDim, fontSize: 11.5)),
    ]),
  );
}

/// The full breakdown, one entry per topic, for the coach's Details page.
List<DetailSection> detailSections(BuildContext context, ReplayReport r) {
  final s = r.summary;
  final a = r.sides.where((x) => x.attack).firstOrNull, d = r.sides.where((x) => !x.attack).firstOrNull;
  final duels = r.opening.killRounds + r.opening.deathRounds;
  return [
    DetailSection('Your numbers', 'KOST ${pct(s.kost)} · K/D ${ratio(s.kd)} · ${s.rounds} rounds', _kostNumbers(context, r), icon: Icons.tag),
    if (r.score.score != null) DetailSection('How the score is made', 'Seven parts, each 0 to 100', _scoreParts(context, r), icon: Icons.calculate_outlined),
    if (r.findings.isNotEmpty) DetailSection('All findings', '${r.findings.length} things the replays show', FindingList(r.findings, initiallyShown: 100), icon: Icons.fact_check_outlined),
    if (r.sides.isNotEmpty) DetailSection('Attack and defense', 'Team won ${pct(a?.winRate)} attacking · ${pct(d?.winRate)} defending', _sideCard(r), icon: Icons.swap_horiz),
    if (duels > 0) DetailSection('The first fight', 'You won ${pct(r.opening.afterKill)} of rounds after winning it, ${pct(r.opening.afterDeath)} after losing it', _openingCard(r), icon: Icons.flash_on),
    DetailSection('Clutches and multi-kills', r.clutch.attempts == 0 ? 'No clutch situations yet' : '${r.clutch.wins} of ${r.clutch.attempts} clutches won', _impactCard(r), icon: Icons.local_fire_department_outlined),
    if (r.timing != null) DetailSection('When things happen', 'Your kills and deaths on the round clock', _timingCard(r), icon: Icons.timer_outlined),
    if (r.operators.isNotEmpty) DetailSection('Operators', '${r.operators.length} played · best ${r.operators.first.operator}', _operatorCard(r), icon: Icons.person_search_outlined),
    if (r.maps.isNotEmpty) DetailSection('Maps', '${r.maps.length} map${r.maps.length == 1 ? '' : 's'}', _mapCard(r), icon: Icons.map_outlined),
    if (r.sites.isNotEmpty) DetailSection('By bombsite', 'Round results where you were present', _bombsiteCard(r), icon: Icons.place_outlined),
  ];
}

Widget _scoreParts(BuildContext context, ReplayReport r) {
  final sc = r.score;
  return AppCard(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final k in scoreComponentNames.keys)
        if (sc.components[k] != null) BarRow(label: scoreComponentNames[k]!, fraction: sc.components[k]! / 100, valueText: sc.components[k]!.round().toString(), color: scoreColor(sc.components[k]), caption: scoreRaw(r, k)),
      if (sc.teamKillPenalty > 0) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Team kills: −${sc.teamKillPenalty.round()} points', style: const TextStyle(color: AppColors.bad, fontSize: 12.5, fontWeight: FontWeight.w700))),
      TextButton.icon(
        style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 36), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        onPressed: () => showScoreInfo(context, r),
        icon: const Icon(Icons.info_outline, size: 16),
        label: const Text('How is this scored?'),
      ),
    ]),
  );
}
