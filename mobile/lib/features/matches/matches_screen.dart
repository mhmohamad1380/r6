import 'package:flutter/material.dart';

import '../../analytics/patterns.dart';
import '../../analytics/rp.dart';
import '../../analytics/sessions.dart';
import '../../app_state.dart';
import '../../core/charts.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../clips/clips.dart';
import '../common/common.dart';
import '../replays/replay_ui.dart';
import 'match_widgets.dart';

class MatchesScreen extends StatefulWidget {
  const MatchesScreen({super.key, required this.state, required this.onOpenSettings});
  final AppState state;
  final VoidCallback onOpenSettings;

  @override
  State<MatchesScreen> createState() => _MatchesScreenState();
}

enum _Tab { log, sessions, rp, replays, clips }

class _MatchesScreenState extends State<MatchesScreen> {
  late _Tab _tab = widget.state.configured ? _Tab.log : _Tab.replays; // replays work without the optional stats key
  String _logMode = 'all'; // all | ranked | unranked

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final s = widget.state;
          // Log, Sessions and RP come from the optional stats key. Without it they would only say "turn me on",
          // so the page is just your replays, with one quiet link to the optional part.
          final lifetime = s.hasStatsKey;
          final tab = lifetime || _tab == _Tab.clips ? _tab : _Tab.replays;
          final g = (tab == _Tab.replays || tab == _Tab.clips) ? null : gate(context, s, onSetup: widget.onOpenSettings);
          return PageBody(state: s, children: [
            const Padding(padding: EdgeInsets.fromLTRB(4, 8, 4, 4), child: Text('Matches', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900))),
            Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 12), child: Text(switch (tab) { _Tab.replays => 'Every match your PC sent, round by round.', _Tab.clips => 'Your best moments, recorded on your PC.', _ => 'Your match log and rank history.' }, style: const TextStyle(color: AppColors.textDim, height: 1.4))),
            Segmented<_Tab>(
              options: lifetime ? const {_Tab.replays: 'Replays', _Tab.clips: 'Clips', _Tab.log: 'Log', _Tab.sessions: 'Sessions', _Tab.rp: 'RP'} : const {_Tab.replays: 'Replays', _Tab.clips: 'Clips'},
              value: tab,
              onChanged: (v) => setState(() => _tab = v),
            ),
            const SizedBox(height: 14),
            if (g != null) g else if (tab == _Tab.clips) ClipsSection(state: s) else if (tab == _Tab.log) ..._matchLog(s) else if (tab == _Tab.sessions) ..._sessions(s) else if (tab == _Tab.rp) ..._rpHistory(s) else ...replaysSection(context, s),
            if (!lifetime) Padding(padding: const EdgeInsets.only(top: 8), child: Center(child: TextButton.icon(onPressed: widget.onOpenSettings, icon: const Icon(Icons.show_chart, size: 18), label: const Text('Rank history and match log (optional)')))),
          ]);
        },
      );

  List<Widget> _matchLog(AppState s) {
    final everything = s.matchLog;
    final log = switch (_logMode) {
      'ranked' => everything.where((r) => r.mode == 'ranked').toList(),
      'unranked' => everything.where((r) => r.mode != 'ranked' && r.mode != 'mixed').toList(),
      _ => everything,
    };
    if (everything.isEmpty) {
      return [
        const SizedBox(height: 20),
        EmptyState(
          icon: Icons.camera_alt_outlined,
          title: 'Your match log starts here',
          message: 'The data source has no match feed, so the app records a snapshot of your stats every time it refreshes. '
              'Play a game, come back and pull down to refresh: the difference is your match, with operator, kills, headshots, opening duels and RP.\n\n'
              '${s.snapshots.length} snapshot${s.snapshots.length == 1 ? '' : 's'} saved so far.',
          action: OutlinedButton.icon(onPressed: () => s.refresh(force: true), icon: const Icon(Icons.refresh), label: const Text('Refresh now')),
        ),
      ];
    }
    final wins = log.where((r) => r.exact && r.won!).length, exact = log.where((r) => r.exact).length;
    return [
      Wrap(spacing: 8, children: [
        for (final e in const {'all': 'All', 'ranked': 'Ranked', 'unranked': 'Unranked'}.entries)
          ChoiceChip(label: Text(e.value), selected: _logMode == e.key, onSelected: (_) => setState(() => _logMode = e.key)),
      ]),
      const SizedBox(height: 12),
      AppCard(
        child: Row(children: [
          Expanded(child: _kv('Logged', '${log.length}')),
          Expanded(child: _kv('Exact matches', '$exact')),
          Expanded(child: _kv('Win rate', exact == 0 ? '—' : pct(wins / exact))),
        ]),
      ),
      const SizedBox(height: 12),
      if (log.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: Text('No logged matches in this mode yet.', style: TextStyle(color: AppColors.textDim)))),
      for (final r in log) Padding(padding: const EdgeInsets.only(bottom: 12), child: MatchCard(record: r, state: s)),
      const Padding(padding: EdgeInsets.only(top: 4), child: Text('Tip: refresh right after each game. Two matches between refreshes are merged into one entry.', style: TextStyle(color: AppColors.textDim, fontSize: 12))),
    ];
  }

  Widget _kv(String k, String v) => Column(children: [
        Text(v, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
        Text(k, style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
      ]);

  List<Widget> _sessions(AppState s) {
    final sessions = sessionsFromRp(s.rp.deltas);
    if (sessions.isEmpty) {
      return const [SizedBox(height: 20), EmptyState(icon: Icons.timelapse, title: 'No sessions yet', message: 'Sessions are built from your ranked RP history. Play ranked and refresh.')];
    }
    return [
      const Notice('A session is a stretch of ranked games with no break longer than 2 hours, inferred from RP changes.', color: AppColors.textDim),
      const SizedBox(height: 12),
      for (final x in sessions)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('${dayLabel(x.start.toLocal())}  ${clock(x.start.toLocal())}-${clock(x.end.toLocal())}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5))),
                Pill('${signed(x.net)} RP', color: x.net >= 0 ? AppColors.good : AppColors.bad),
              ]),
              const SizedBox(height: 4),
              Text('${x.games.length} game${x.games.length == 1 ? '' : 's'} · ${x.wins}W ${x.losses}L · ${x.length.inMinutes < 1 ? 'single game' : '${(x.length.inMinutes / 60).toStringAsFixed(1)} h between first and last result'}', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5)),
              const SizedBox(height: 12),
              FormStrip(x.games.reversed.toList(), max: 14),
              if (x.games.length >= 2) ...[
                const SizedBox(height: 12),
                Text('Best ${signed(x.best.delta)} · worst ${signed(x.worst.delta)}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ],
              if (x.note != null) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppColors.surfaceHi, borderRadius: BorderRadius.circular(12)),
                  child: Text(x.note!, style: const TextStyle(fontSize: 12.5, height: 1.4)),
                ),
              ],
            ]),
          ),
        ),
    ];
  }

  List<Widget> _rpHistory(AppState s) {
    final rp = s.rp;
    if (!rp.hasData) {
      return const [SizedBox(height: 20), EmptyState(icon: Icons.show_chart, title: 'No RP history yet', message: 'Play ranked and refresh to see your results here.')];
    }
    final byDay = <String, List<RpDelta>>{};
    for (final d in rp.deltas) {
      byDay.putIfAbsent(dayLabel(d.at.toLocal()), () => []).add(d);
    }
    return [
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          RpLineChart(points: s.rpHistory.take(40).toList()),
          const SizedBox(height: 12),
          Column(children: [
            IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _s('Games', '${rp.games}')),
              Expanded(child: _s('Win rate', pct(rp.winRate))),
              Expanded(child: _s('Net RP', signed(rp.net), color: rp.net >= 0 ? AppColors.good : AppColors.bad)),
            ])),
            const SizedBox(height: 10),
            IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _s('Avg win', rp.avgWin == null ? '—' : '+${rp.avgWin!.toStringAsFixed(0)}', color: AppColors.good)),
              Expanded(child: _s('Avg loss', rp.avgLoss == null ? '—' : '-${rp.avgLoss!.toStringAsFixed(0)}', color: AppColors.bad)),
              Expanded(child: _s('Break-even', pct(rp.breakEvenWinRate), hint: 'Win rate needed to hold your RP')),
            ])),
            const SizedBox(height: 10),
            IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _s('Best win', rp.best == null ? '—' : '+${rp.best}')),
              Expanded(child: _s('Worst loss', rp.worst == null ? '—' : '${rp.worst}')),
              Expanded(child: _s('Best streak', '${rp.longestWinStreak}W')),
            ])),
          ]),
        ]),
      ),
      const SizedBox(height: 12),
      ..._timeOfDay(rp),
      const SizedBox(height: 4),
      const Notice('Wins and losses are inferred from RP going up or down. The data source does not list matches.', color: AppColors.textDim),
      for (final e in byDay.entries) ...[
        SectionTitle(e.key, subtitle: '${e.value.length} game${e.value.length == 1 ? '' : 's'} · ${signed(e.value.fold<int>(0, (a, d) => a + d.delta))} RP'),
        for (final d in e.value)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                Container(width: 4, height: 34, decoration: BoxDecoration(color: d.win ? AppColors.good : AppColors.bad, borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(d.win ? 'Likely win' : 'Likely loss', style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text('${d.rank ?? 'Ranked'} · ${clock(d.at.toLocal())}', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5)),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${signed(d.delta)} RP', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: d.win ? AppColors.good : AppColors.bad)),
                  Text('${d.rpAfter}', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                ]),
              ]),
            ),
          ),
      ],
    ];
  }

  List<Widget> _timeOfDay(RpAnalysis rp) {
    final blocks = byTimeOfDay(rp.deltas);
    final enough = rp.games >= 8;
    return [
      const SectionTitle('When you play best', subtitle: 'Win rate by time of day, from RP history'),
      AppCard(
        child: Column(children: [
          for (final b in blocks)
            BarRow(
              label: '${b.label}  ·  ${b.range}',
              fraction: b.games == 0 ? null : b.winRate,
              valueText: b.games == 0 ? '—' : '${pct(b.winRate)} (${b.games})',
              color: b.winRate >= 0.5 ? AppColors.good : AppColors.warn,
              caption: b.games == 0 ? 'No games yet' : '${b.wins}W ${b.games - b.wins}L · ${signed(b.net)} RP${b.games < 8 ? ' · too few to trust' : ''}',
            ),
          if (!enough) const Padding(padding: EdgeInsets.only(top: 6), child: Text('History grows with every refresh. Patterns are reliable from about 8 games per time of day.', style: TextStyle(color: AppColors.textDim, fontSize: 12))),
        ]),
      ),
    ];
  }

  Widget _s(String l, String v, {Color? color, String? hint}) => Tooltip(
        message: hint ?? l,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l, style: const TextStyle(color: AppColors.textDim, fontSize: 11.5)),
          Text(v, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: color, fontFeatures: tabular)),
        ]),
      );
}
