import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../analytics/replay_patterns.dart';
import '../../app_state.dart';
import '../../core/charts.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../common/common.dart';
import '../common/guide.dart';
import 'replay_insights_ui.dart';


Color _rateColor(double? v) => v == null ? AppColors.outline : (v >= 0.55 ? AppColors.good : (v >= 0.45 ? AppColors.warn : AppColors.bad));
String _wl(WinCount w) => '${w.wins}W ${w.rounds - w.wins}L';
String _few(int n, int min) => n < min ? ' · too few to trust' : '';

/// Patterns across all your replays: squad, enemy operators, how rounds end, pressure, spawns and when you play.
/// Works from replays alone: no key, no account.
class PatternsView extends StatefulWidget {
  const PatternsView({super.key, required this.state});
  final AppState state;

  @override
  State<PatternsView> createState() => _PatternsViewState();
}

class _PatternsViewState extends State<PatternsView> {
  final _open = <String>{};
  Patterns _patterns(AppState s) => cachedPatterns(s.replays, s.playerName, population: s.population);

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    if (s.replays.isEmpty || s.playerName.isEmpty) {
      return Column(children: [
        const SizedBox(height: 8),
        NextStepCard(step: nextStepFor(s), onAction: (id) => runStep(context, s, id)),
      ]);
    }
    final p = _patterns(s);
    if (p.rounds < 10) {
      return EmptyState(
        icon: Icons.hourglass_bottom,
        title: 'A few more rounds first',
        message: 'Patterns need at least 10 of your rounds to mean anything. You have ${p.rounds}. Play a couple of matches with the Windows uploader running.',
      );
    }
    final matches = s.replays.where((r) => r.players.any((x) => x.name.toLowerCase() == s.playerName.toLowerCase())).map((r) => r.matchId).toSet().length;
    final sections = _sections(p);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
        child: Row(children: [
          Expanded(child: Text('From ${p.rounds} of your rounds in $matches matches.', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5))),
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => showInfo(context, 'How patterns work',
                'Each pattern compares groups of your own rounds: with your regular teammates and without them, after a won round and after a lost one, from one spawn and another.\n\n'
                'A finding only appears when both groups have enough rounds, and every number says how many rounds it rests on. Small groups are marked "too few to trust".\n\n'
                '"You vs the players you meet" compares you with the other players in the replays on your server: your teammates and opponents, at your level.'),
            child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.info_outline, size: 20, color: AppColors.textDim)),
          ),
        ]),
      ),
      if (p.findings.isNotEmpty) ...[
        const Padding(padding: EdgeInsets.fromLTRB(4, 0, 4, 8), child: Text('What stands out', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
        FindingList(p.findings),
      ] else
        const Padding(padding: EdgeInsets.only(bottom: 10), child: Notice('Nothing stands out yet: your groups are close to each other, or still small. Open a section to see the numbers.', color: AppColors.accent2, icon: Icons.lightbulb_outline)),
      const Padding(padding: EdgeInsets.fromLTRB(4, 14, 4, 8), child: Text('Explore', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
      for (final x in sections) _section(x),
    ]);
  }

  List<DetailSection> _sections(Patterns p) => [
        DetailSection('You vs the players you meet', _standingPreview(p), _standingCard(p), icon: Icons.leaderboard_outlined),
        DetailSection('Your squad', _squadPreview(p.squad), _squadCard(p.squad), icon: Icons.groups_outlined),
        DetailSection('Enemy operators', _opsPreview(p.enemyOps), _opsCard(p.enemyOps), icon: Icons.person_search_outlined),
        DetailSection('How your rounds end', _endsPreview(p.ends), _endsCard(p.ends), icon: Icons.flag_outlined),
        DetailSection('The plant', _plantPreview(p.plants), _plantCard(p.plants), icon: Icons.memory),
        DetailSection('Under pressure', _pressurePreview(p.pressure), _pressureCard(p.pressure), icon: Icons.bolt_outlined),
        if (p.spawns.isNotEmpty) DetailSection('Attack spawns', _spawnPreview(p.spawns), _spawnCard(p.spawns), icon: Icons.place_outlined),
        DetailSection('When you play', _whenPreview(p.when), _whenCard(p.when), icon: Icons.schedule),
        if (p.short.short.rounds >= 3) DetailSection('A player short', 'Won ${pct(p.short.short.rate)} of ${p.short.short.rounds} rounds played a player down', _shortCard(p.short), icon: Icons.person_remove_outlined),
        if (p.seasons.length > 1) DetailSection('Seasons', p.seasons.map((x) => '${x.season}: KOST ${pct(x.summary.kost)}').join(' · '), _seasonCard(p.seasons), icon: Icons.calendar_month_outlined),
      ];

  Widget _section(DetailSection x) {
    final open = _open.contains(x.title);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppCard(
          padding: EdgeInsets.zero,
          child: Semantics(
            button: true,
            expanded: open,
            label: '${x.title}. ${x.preview}',
            excludeSemantics: true,
            child: InkWell(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => open ? _open.remove(x.title) : _open.add(x.title));
              },
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  Icon(x.icon, color: AppColors.accent2, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(x.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(x.preview, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.3)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(turns: open ? 0.5 : 0, duration: const Duration(milliseconds: 200), child: const Icon(Icons.expand_more, color: AppColors.textDim)),
                ]),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: open ? Padding(padding: const EdgeInsets.only(top: 8), child: x.body) : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- standing
  String _standingPreview(Patterns p) {
    if (p.population == null) return 'Sync with your replay server to compare yourself with the players you meet';
    if (p.standings.isEmpty) return 'Needs 10 of your rounds and a server table';
    final k = p.standings.firstWhere((x) => x.metric == 'kost', orElse: () => p.standings.first);
    return '${k.label}: better than ${pct(k.percentile)} of ${p.population!.players} players';
  }

  Widget _standingCard(Patterns p) {
    String fmt(String metric, double v) => metric == 'kd' || metric == 'killsPerRound' ? v.toStringAsFixed(2) : pct(v);
    if (p.population == null) {
      return AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('This compares you with every other player in the replays on your server. Your phone gets that table when it syncs.', style: TextStyle(color: AppColors.textDim, height: 1.4, fontSize: 13)),
          const SizedBox(height: 12),
          if (widget.state.replayServerConfigured)
            OutlinedButton.icon(onPressed: () => widget.state.syncReplayServer(), icon: const Icon(Icons.sync), label: const Text('Sync now'))
          else
            OutlinedButton.icon(onPressed: () => AppNav.maybeOf(context)?.goTab(Tabs.profile), icon: const Icon(Icons.dns_outlined), label: const Text('Set up the replay server')),
        ]),
      );
    }
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Against the ${p.population!.players} other players in your replays who played at least 5 rounds: your teammates and opponents.', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.35)),
        const SizedBox(height: 8),
        for (final x in p.standings)
          BarRow(
            label: x.label,
            fraction: x.percentile,
            valueText: 'Better than ${pct(x.percentile)}',
            color: x.percentile >= 0.6 ? AppColors.good : (x.percentile >= 0.4 ? AppColors.warn : AppColors.bad),
            caption: 'You: ${fmt(x.metric, x.value)} · the middle player: ${fmt(x.metric, p.population!.quantiles[x.metric]![10])}',
          ),
      ]),
    );
  }

  // ---------------------------------------------------------------- squad
  String _squadPreview(SquadReport q) => q.regulars.isEmpty
      ? 'No regular teammates yet: you played every match with different people'
      : 'With them ${pct(q.withSquad.rate)} · without ${pct(q.solo.rate)} rounds won';

  Widget _squadCard(SquadReport q) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (q.regulars.isEmpty)
            const Text('A regular teammate is someone on your side in at least two of your matches. Nobody is yet.', style: TextStyle(color: AppColors.textDim, height: 1.4, fontSize: 13))
          else ...[
            BarRow(label: 'With a regular teammate', fraction: q.withSquad.rate, valueText: pct(q.withSquad.rate), color: _rateColor(q.withSquad.rate), caption: '${_wl(q.withSquad)} · your KOST ${pct(q.withKost)}${_few(q.withSquad.rounds, 12)}'),
            BarRow(label: 'Without one', fraction: q.solo.rate, valueText: pct(q.solo.rate), color: _rateColor(q.solo.rate), caption: '${_wl(q.solo)} · your KOST ${pct(q.soloKost)}${_few(q.solo.rounds, 12)}'),
            const SizedBox(height: 10),
            const Text('Regular teammates', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            for (final m in q.regulars.take(8))
              BarRow(
                label: m.name,
                fraction: m.rec.rate,
                valueText: pct(m.rec.rate),
                color: _rateColor(m.rec.rate),
                caption: [
                  '${m.matches.length} matches · ${_wl(m.rec)}',
                  if (m.avengedMe > 0) 'avenged you ${m.avengedMe}×',
                  if (m.iAvenged > 0) 'you avenged them ${m.iAvenged}×',
                ].join(' · '),
              ),
          ],
        ]),
      );

  // ---------------------------------------------------------------- enemy operators
  String _opsPreview(List<OpDuel> ops) {
    final hard = ops.where((o) => o.fights >= 5).toList()..sort((a, b) => (a.winRate ?? 1).compareTo(b.winRate ?? 1) != 0 ? (a.winRate ?? 1).compareTo(b.winRate ?? 1) : b.deaths.compareTo(a.deaths)); // same bar as the finding
    return hard.isEmpty ? 'Your fights against each operator' : 'Hardest: ${operatorLabel(hard.first.op)}, ${hard.first.kills}–${hard.first.deaths}';
  }

  Widget _opsCard(List<OpDuel> ops) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Fights you won and lost against each enemy operator. A fight is a kill either way.', style: TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.35)),
          const SizedBox(height: 6),
          if (ops.isEmpty) const Text('No fights recorded yet.', style: TextStyle(color: AppColors.textDim)),
          for (final o in ops.take(10))
            BarRow(label: operatorLabel(o.op), fraction: o.winRate, valueText: '${o.kills}–${o.deaths}', color: _rateColor(o.winRate), caption: 'Won ${pct(o.winRate)} of ${o.fights} fights${_few(o.fights, 5)}'),
        ]),
      );

  // ---------------------------------------------------------------- round ends
  String _endsPreview(EndReport e) {
    final lost = e.total(e.attackLosses);
    final t = e.attackLosses[RoundEnd.time] ?? 0;
    return lost == 0 ? 'How your rounds were won and lost' : '$t of $lost lost attacks ran out of time';
  }

  Widget _endsList(String title, Map<RoundEnd, int> m, Color color) {
    final total = m.values.fold<int>(0, (a, b) => a + b);
    final entries = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 8), child: Text('$title · $total', style: const TextStyle(fontWeight: FontWeight.w800))),
      if (total == 0) const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Text('None yet.', style: TextStyle(color: AppColors.textDim))),
      for (final x in entries) BarRow(label: endLabel(x.key), fraction: total == 0 ? 0 : x.value / total, valueText: '${x.value}', color: color),
    ]);
  }

  Widget _endsCard(EndReport e) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Worked out from each round: who was left alive, the plant, and the defuse.', style: TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.35)),
          _endsList('Attack, won', e.attackWins, AppColors.good),
          _endsList('Attack, lost', e.attackLosses, AppColors.bad),
          _endsList('Defense, won', e.defenseWins, AppColors.good),
          _endsList('Defense, lost', e.defenseLosses, AppColors.bad),
        ]),
      );

  // ---------------------------------------------------------------- plant
  String _plantPreview(PlantReport p) => p.planted.rounds == 0 ? 'No plants in your attack rounds yet' : 'With a plant ${pct(p.planted.rate)} won · without ${pct(p.notPlanted.rate)}';

  Widget _plantCard(PlantReport p) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('On attack', style: TextStyle(fontWeight: FontWeight.w800)),
          BarRow(label: 'Rounds with a plant', fraction: p.planted.rate, valueText: pct(p.planted.rate), color: _rateColor(p.planted.rate), caption: '${_wl(p.planted)}${_few(p.planted.rounds, 5)}'),
          BarRow(label: 'Rounds without one', fraction: p.notPlanted.rate, valueText: pct(p.notPlanted.rate), color: _rateColor(p.notPlanted.rate), caption: '${_wl(p.notPlanted)}${_few(p.notPlanted.rounds, 5)}'),
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(p.myPlants == 0 ? 'You did not plant yourself in these rounds.' : 'You planted ${p.myPlants} time${p.myPlants == 1 ? '' : 's'} yourself.', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5))),
          const SizedBox(height: 12),
          const Text('On defense', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            p.againstPlanted == 0 ? 'The attackers never planted against you.' : 'The attackers planted in ${p.againstPlanted} rounds. Your team disabled it ${p.defusedByUs} time${p.defusedByUs == 1 ? '' : 's'}.',
            style: const TextStyle(color: AppColors.textDim, fontSize: 13, height: 1.35),
          ),
        ]),
      );

  // ---------------------------------------------------------------- pressure
  String _pressurePreview(PressureReport r) => 'After a loss ${pct(r.afterLoss.rate)} · after a win ${pct(r.afterWin.rate)} rounds won';

  Widget _pressureCard(PressureReport r) {
    Widget row(String label, WinCount w, {String? extra, int min = 5}) =>
        BarRow(label: label, fraction: w.rate, valueText: w.rounds == 0 ? '—' : pct(w.rate), color: _rateColor(w.rate), caption: w.rounds == 0 ? 'Not yet' : '${_wl(w)}${extra ?? ''}${_few(w.rounds, min)}');
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Rounds your team won, by the situation going into them.', style: TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.35)),
        row('First round of the match', r.firstRound),
        row('After a won round', r.afterWin, extra: ' · your KOST ${pct(r.afterWinKost)}', min: 10),
        row('After a lost round', r.afterLoss, extra: ' · your KOST ${pct(r.afterLossKost)}', min: 10),
        row('Your match point', r.ourMatchPoint),
        row('Their match point', r.theirMatchPoint),
        row('Overtime', r.overtime),
        if (r.downTwo > 0) Padding(padding: const EdgeInsets.only(top: 6), child: Text('You lost the first two rounds in ${r.downTwo} match${r.downTwo == 1 ? '' : 'es'} and came back to win ${r.downTwoWon}.', style: const TextStyle(fontSize: 13, height: 1.35))),
      ]),
    );
  }

  // ---------------------------------------------------------------- spawns
  String _spawnPreview(List<SpawnLine> s) {
    final best = s.where((x) => x.rec.rounds >= 3).toList()..sort((a, b) => (b.rec.rate ?? 0).compareTo(a.rec.rate ?? 0));
    return best.isEmpty ? 'Your attack rounds by spawn point' : 'Best: ${best.first.spawn} on ${best.first.map}, ${pct(best.first.rec.rate)}';
  }

  Widget _spawnCard(List<SpawnLine> s) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Attack rounds your team won, by where you spawned. Only spawns with 2 or more rounds.', style: TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.35)),
          for (final x in s.where((x) => x.rec.rounds >= 2).take(12))
            BarRow(label: '${x.map} · ${x.spawn}', fraction: x.rec.rate, valueText: pct(x.rec.rate), color: _rateColor(x.rec.rate), caption: '${_wl(x.rec)} · ${x.kills} kills, ${x.deaths} deaths${x.openingDeaths > 0 ? ', died first ${x.openingDeaths}×' : ''}${_few(x.rec.rounds, 4)}'),
        ]),
      );

  // ---------------------------------------------------------------- when
  String _whenPreview(WhenReport w) {
    if (w.byMatchInSession.length < 2) return '${w.sessions} sitting${w.sessions == 1 ? '' : 's'} so far';
    final a = w.byMatchInSession.first, b = w.byMatchInSession.last;
    return 'KOST ${pct(a.kost)} in your ${a.label} · ${pct(b.kost)} in your ${b.label}';
  }

  Widget _whenCard(WhenReport w) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('A sitting is matches with less than 2 hours between them. You had ${w.sessions}.', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.35)),
          const Padding(padding: EdgeInsets.only(top: 8), child: Text('Your KOST by match in a sitting', style: TextStyle(fontWeight: FontWeight.w800))),
          for (final l in w.byMatchInSession) BarRow(label: l.label, fraction: l.kost, valueText: pct(l.kost), color: _rateColor(l.kost), caption: '${l.rounds.length} rounds · ${pct(l.rec.rate)} won${_few(l.rounds.length, 12)}'),
          const Padding(padding: EdgeInsets.only(top: 12), child: Text('By time of day', style: TextStyle(fontWeight: FontWeight.w800))),
          for (final l in w.byTimeOfDay) BarRow(label: l.label, fraction: l.kost, valueText: pct(l.kost), color: _rateColor(l.kost), caption: '${l.rounds.length} rounds · ${pct(l.rec.rate)} won${_few(l.rounds.length, 12)}'),
        ]),
      );

  // ---------------------------------------------------------------- short, seasons
  Widget _shortCard(ShortReport s) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          BarRow(label: 'Full team', fraction: s.full.rate, valueText: pct(s.full.rate), color: _rateColor(s.full.rate), caption: _wl(s.full)),
          BarRow(label: 'A player short', fraction: s.short.rate, valueText: pct(s.short.rate), color: _rateColor(s.short.rate), caption: '${_wl(s.short)}${_few(s.short.rounds, 5)}'),
          if (s.leaverRounds > 0) Padding(padding: const EdgeInsets.only(top: 6), child: Text('A teammate quit during ${s.leaverRounds} round${s.leaverRounds == 1 ? '' : 's'}.', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5))),
        ]),
      );

  Widget _seasonCard(List<SeasonLine> list) => AppCard(
        child: Column(children: [
          for (final x in list) BarRow(label: x.season, fraction: x.summary.kost, valueText: 'KOST ${pct(x.summary.kost)}', color: _rateColor(x.summary.kost), caption: '${x.summary.rounds} rounds · K/D ${ratio(x.summary.kd)} · ${pct(x.summary.rounds == 0 ? null : x.summary.wins / x.summary.rounds)} won'),
        ]),
      );
}
