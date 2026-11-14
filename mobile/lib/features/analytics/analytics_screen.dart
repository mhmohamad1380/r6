import 'package:flutter/material.dart';

import '../../analytics/breakdowns.dart';
import '../../analytics/context.dart';
import '../../analytics/picks.dart';
import '../../app_state.dart';
import '../../core/charts.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../common/common.dart';
import 'compare_screen.dart';
import 'operator_sheet.dart';

enum _View { operators, sides, modes, maps }

enum _Sort { rounds, kd, win, entry }

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key, required this.state, required this.onOpenSettings, this.embedded = false});
  final AppState state;
  final VoidCallback onOpenSettings;
  final bool embedded; // inside the Stats tab, which supplies the title

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  _View _view = _View.operators;
  _Sort _sort = _Sort.rounds;
  String _side = 'All';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final s = widget.state;
          final g = gate(context, s, onSetup: widget.onOpenSettings);
          if (g != null) return g;
          final ops = s.activeOps;
          return PageBody(state: s, children: [
            if (!widget.embedded) const Padding(padding: EdgeInsets.fromLTRB(4, 8, 4, 12), child: Text('Analytics', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900))),
            Segmented<_View>(options: const {_View.operators: 'Operators', _View.sides: 'Sides', _View.modes: 'Modes', _View.maps: 'Maps'}, value: _view, onChanged: (v) => setState(() => _view = v)),
            if (_view != _View.modes && _view != _View.maps) ...[const SizedBox(height: 10), FilterBar(s)],
            const SizedBox(height: 14),
            if (_view == _View.modes)
              ..._modes(s)
            else if (_view == _View.maps)
              ..._maps(s)
            else if (ops.isEmpty)
              s.loading ? const Column(children: [Skeleton(height: 90), SizedBox(height: 12), Skeleton(height: 90), SizedBox(height: 12), Skeleton(height: 90)]) : Notice(s.activeReady ? 'No rounds recorded for ${s.filterLabel}.' : 'No data for ${s.filterLabel} yet.', color: AppColors.textDim)
            else if (_view == _View.operators)
              ..._operators(s, ops)
            else
              ..._sides(s, ops),
          ]);
        },
      );

  // ----- Operators -----
  List<Widget> _operators(AppState s, List<OperatorStat> all) {
    final list = all.where((o) => (o.roundsPlayed ?? 0) > 0 && (_side == 'All' || o.side == _side)).toList();
    num key(OperatorStat o) => switch (_sort) {
          _Sort.rounds => o.roundsPlayed ?? 0,
          _Sort.kd => o.kd ?? -1,
          _Sort.win => o.roundWinRate ?? -1,
          _Sort.entry => o.openingWinRate ?? -1,
        };
    list.sort((a, b) => key(b).compareTo(key(a)));
    final game = s.gameByName;
    final maxRounds = list.isEmpty ? 1 : (list.map((o) => o.roundsPlayed ?? 0).reduce((a, b) => a > b ? a : b));
    return [
      AppCard(
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CompareScreen(state: s))),
        child: Row(children: [
          Container(width: 40, height: 40, decoration: BoxDecoration(color: AppColors.accent2.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.compare_arrows_rounded, color: AppColors.accent2)),
          const SizedBox(width: 12),
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Compare with a friend', style: TextStyle(fontWeight: FontWeight.w800)),
            Text('Skill radar and stats side by side. Uses 2 API calls.', style: TextStyle(color: AppColors.textDim, fontSize: 12.5)),
          ])),
          const Icon(Icons.chevron_right, color: AppColors.textDim),
        ]),
      ),
      ..._picks(s, all),
      const SizedBox(height: 12),
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final e in const {'All': 'All', 'Attacker': 'Attack', 'Defender': 'Defense'}.entries)
            Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(e.value), selected: _side == e.key, onSelected: (_) => setState(() => _side = e.key))),
          const SizedBox(width: 8),
          for (final e in const {_Sort.rounds: 'Most played', _Sort.kd: 'K/D', _Sort.win: 'Win %', _Sort.entry: 'Entry'}.entries)
            Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(avatar: _sort == e.key ? const Icon(Icons.sort, size: 16) : null, label: Text(e.value), selected: _sort == e.key, onSelected: (_) => setState(() => _sort = e.key))),
        ]),
      ),
      const SizedBox(height: 4),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('${list.length} operators · under 60 rounds is noisy (shown dimmed)', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
      ),
      for (final o in list)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Opacity(
            opacity: (o.roundsPlayed ?? 0) >= 60 ? 1 : 0.62,
            child: AppCard(
              padding: const EdgeInsets.all(12),
              onTap: () => showOperatorSheet(context, s, o),
              child: Row(children: [
                OperatorIcon(name: o.name, url: game[o.name.toLowerCase()]?.iconUrl, attacker: o.isAttacker, size: 50),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(o.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5))),
                      Text(ratio(o.kd), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, fontFeatures: tabular, color: (o.kd ?? 0) >= 1 ? AppColors.good : AppColors.text)),
                      const Text('  K/D', style: TextStyle(color: AppColors.textDim, fontSize: 11)),
                    ]),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(value: (o.roundsPlayed ?? 0) / maxRounds, minHeight: 5, backgroundColor: AppColors.surfaceHi, valueColor: AlwaysStoppedAnimation(o.isAttacker ? AppColors.attack : AppColors.defense)),
                    ),
                    const SizedBox(height: 6),
                    Text('${o.roundsPlayed} rounds · win ${pct(o.roundWinRate)} · entry ${pct(o.openingWinRate)}', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                  ]),
                ),
                const Icon(Icons.chevron_right, color: AppColors.textDim),
              ]),
            ),
          ),
        ),
    ];
  }

  List<Widget> _picks(AppState s, List<OperatorStat> all) {
    final atk = operatorPicks(all, attacker: true).take(3).toList();
    final def = operatorPicks(all, attacker: false).take(3).toList();
    if (atk.isEmpty && def.isEmpty) return const [];
    final game = s.gameByName;
    Widget col(String title, Color c, List<Pick> picks) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: c, fontWeight: FontWeight.w900, fontSize: 12.5)),
            const SizedBox(height: 8),
            if (picks.isEmpty) const Text('Not enough rounds yet', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            for (final p in picks)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  onTap: () => showOperatorSheet(context, s, p.op),
                  borderRadius: BorderRadius.circular(10),
                  child: Row(children: [
                    OperatorIcon(name: p.op.name, url: game[p.op.name.toLowerCase()]?.iconUrl, attacker: p.op.isAttacker, size: 36),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(p.op.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5), maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text('${pct(p.score)} · ${p.rounds} rds', style: const TextStyle(color: AppColors.textDim, fontSize: 11.5)),
                      ]),
                    ),
                  ]),
                ),
              ),
          ]),
        );
    return [
      const SectionTitle('Picks for you', subtitle: 'Best round results, adjusted for sample size'),
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [col('ATTACK', AppColors.attack, atk), const SizedBox(width: 12), col('DEFENSE', AppColors.defense, def)]),
          const SizedBox(height: 4),
          const Text('Ranked by round win rate pulled toward your average, so a few lucky rounds cannot beat a long record. This is correlation, not proof that the operator caused the wins.', style: TextStyle(color: AppColors.textDim, fontSize: 11.5, height: 1.4)),
        ]),
      ),
    ];
  }

  // ----- Sides & roles -----
  List<Widget> _sides(AppState s, List<OperatorStat> ops) {
    final atk = sideTotals(ops, true), def = sideTotals(ops, false);
    final roles = roleTotals(ops, s.game).where((r) => r.rounds >= 20).toList();
    final pool = poolStats(ops, s.game);
    final mk = multiKillRate(ops);
    Widget pair(String label, double? a, double? d, {required String Function(double?) f, double max = 1}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: AppColors.textDim, fontSize: 12.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            _dual('Attack', a, f(a), max, AppColors.attack),
            const SizedBox(height: 5),
            _dual('Defense', d, f(d), max, AppColors.defense),
          ]),
        );
    return [
      AppCard(
        child: Column(children: [
          Row(children: [
            Expanded(child: _sideHead('Attack', atk, AppColors.attack)),
            Container(width: 1, height: 44, color: AppColors.outline),
            Expanded(child: _sideHead('Defense', def, AppColors.defense)),
          ]),
          const Divider(height: 24),
          pair('K/D', atk.kd, def.kd, f: ratio, max: 2),
          pair('Round win rate', atk.roundWinRate, def.roundWinRate, f: pct),
          pair('Opening duels won', atk.opening, def.opening, f: pct),
          pair('Headshot %', atk.headshotRate, def.headshotRate, f: pct),
          pair('Rounds survived', atk.survival, def.survival, f: pct),
        ]),
      ),
      const SectionTitle('Roles', subtitle: 'Operators can have several roles, so rows overlap'),
      AppCard(
        child: Column(children: [
          if (roles.isEmpty) const Text('Not enough rounds per role yet.', style: TextStyle(color: AppColors.textDim)),
          for (final r in roles.take(10))
            BarRow(
              label: r.label,
              fraction: r.kd == null ? null : (r.kd! / 2).clamp(0.0, 1.0),
              valueText: 'K/D ${ratio(r.kd)}',
              caption: '${r.rounds} rounds · ${r.operators} operator${r.operators == 1 ? '' : 's'} · win ${pct(r.roundWinRate)}',
              color: (r.kd ?? 0) >= 1 ? AppColors.good : AppColors.accent,
            ),
        ]),
      ),
      const SectionTitle('Operator pool'),
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: _big('${pool.played}', 'operators played', sub: 'of ${pool.available}')),
            Expanded(child: _big('${pool.regulars}', 'with 30+ rounds')),
            Expanded(child: _big(pct(pool.top3Share), 'on your top 3')),
          ]),
          const SizedBox(height: 14),
          BarRow(label: pool.top1 == null ? 'Most played' : '${pool.top1} (most played)', fraction: pool.top1Share, valueText: pct(pool.top1Share), caption: 'Share of all your rounds'),
          if (mk != null) BarRow(label: 'Multi-kill rounds', fraction: (mk / 25).clamp(0.0, 1.0), valueText: '${mk.toStringAsFixed(1)} / 100 rounds', color: AppColors.accent2),
        ]),
      ),
    ];
  }

  Widget _sideHead(String l, Totals t, Color c) => Column(children: [
        Text(l, style: TextStyle(color: c, fontWeight: FontWeight.w900, fontSize: 15)),
        const SizedBox(height: 4),
        Text('${t.rounds} rounds', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
        Text('${t.operators} operators', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
      ]);

  Widget _dual(String l, double? v, String text, double max, Color c) => Row(children: [
        SizedBox(width: 54, child: Text(l, style: const TextStyle(fontSize: 12, color: AppColors.textDim))),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(value: v == null ? 0 : (v / max).clamp(0.0, 1.0), minHeight: 8, backgroundColor: AppColors.surfaceHi, valueColor: AlwaysStoppedAnimation(c)),
          ),
        ),
        SizedBox(width: 52, child: Text(text, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800, fontFeatures: tabular))),
      ]);

  Widget _big(String v, String l, {String? sub}) => Column(children: [
        Text(v, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
        Text(l, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textDim, fontSize: 11.5)),
        if (sub != null) Text(sub, style: const TextStyle(color: AppColors.textDim, fontSize: 11)),
      ]);

  // ----- Maps & teams (from matches the player annotated) -----
  List<Widget> _maps(AppState s) {
    final log = s.matchLog;
    final exact = log.where((r) => r.exact).length;
    final done = annotatedExact(log, s.noteFor);
    final maps = byMap(log, s.noteFor), party = byParty(log, s.noteFor), mood = byFeeling(log, s.noteFor);

    Widget group(String title, String sub, List<GroupResult> rows) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SectionTitle(title, subtitle: sub),
          AppCard(
            child: Column(children: [
              for (final g in rows)
                Opacity(
                  opacity: g.games >= 3 ? 1 : 0.6,
                  child: BarRow(
                    label: g.label,
                    fraction: g.winRate,
                    valueText: '${pct(g.winRate)} wins',
                    color: g.winRate >= 0.5 ? AppColors.good : AppColors.warn,
                    caption: '${g.wins}W ${g.losses}L · K/D ${ratio(g.kd)} · ${g.games} match${g.games == 1 ? '' : 'es'}${g.games < 3 ? ' (too few to trust)' : ''}',
                  ),
                ),
            ]),
          ),
        ]);

    return [
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(exact == 0 ? 'No logged matches yet' : '${done.length} of $exact logged matches have context', style: const TextStyle(fontWeight: FontWeight.w800))),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(value: exact == 0 ? 0 : done.length / exact, minHeight: 8, backgroundColor: AppColors.surfaceHi, valueColor: const AlwaysStoppedAnimation(AppColors.accent2)),
          ),
          const SizedBox(height: 10),
          const Text('The API has no map or team data. Open a match in Matches and tell the app the map, who you played with and how you felt. Results by map, team size and mood appear here once you have a few games each.', style: TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.4)),
        ]),
      ),
      if (maps.isNotEmpty) group('By map', 'Win rate from your annotated matches', maps),
      if (party.isNotEmpty) group('Solo vs team', 'Win rate by how many you queued with', party),
      if (mood.isNotEmpty) group('By mood', 'Win rate by how you felt', mood),
      if (done.isEmpty && exact > 0) const Padding(padding: EdgeInsets.only(top: 16), child: Notice('You have logged matches. Open one and add its map to start.', color: AppColors.accent)),
    ];
  }

  // ----- Modes -----
  List<Widget> _modes(AppState s) {
    final p = s.profile!;
    final rows = modeRows(p);
    if (rows.isEmpty) return const [Notice('No mode data yet.', color: AppColors.textDim)];
    return [
      for (final m in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(m.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900))),
                const SizedBox(width: 8),
                Pill('${m.matches} matches', color: AppColors.textDim),
              ]),
              const SizedBox(height: 12),
              WinLossBar(wins: m.board?.wins ?? (m.segment?.stat('matchesWon')?.toInt() ?? 0), losses: m.board?.losses ?? (m.segment?.stat('matchesLost')?.toInt() ?? 0)),
              const SizedBox(height: 8),
              Row(children: [
                Text('${m.board?.wins ?? m.segment?.stat('matchesWon')?.toInt() ?? 0}W', style: const TextStyle(color: AppColors.good, fontWeight: FontWeight.w800)),
                const Spacer(),
                Text('${m.board?.losses ?? m.segment?.stat('matchesLost')?.toInt() ?? 0}L', style: const TextStyle(color: AppColors.bad, fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(child: _big(pct(m.winRate), 'win rate')),
                Expanded(child: _big(ratio(m.kd), 'K/D')),
                Expanded(child: _big(m.hours == null ? '—' : '${m.hours} h', 'played')),
              ]),
            ]),
          ),
        ),
      const Text('Per-season figures from the current season.', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
    ];
  }
}
