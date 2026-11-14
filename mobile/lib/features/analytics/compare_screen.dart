import 'package:flutter/material.dart';

import '../../analytics/breakdowns.dart';
import '../../analytics/skills.dart';
import '../../app_state.dart';
import '../../core/charts.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Head-to-head with another player. Costs 2 API calls and only runs when the user taps Compare.
class CompareScreen extends StatefulWidget {
  const CompareScreen({super.key, required this.state});
  final AppState state;

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  final _name = TextEditingController();
  late String _platform = widget.state.platform;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Compare'), backgroundColor: AppColors.bg, surfaceTintColor: Colors.transparent),
        body: ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) {
            final s = widget.state;
            final o = s.other;
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
              Row(children: [
                Expanded(child: TextField(controller: _name, autocorrect: false, textInputAction: TextInputAction.search, onSubmitted: (_) => _go(), decoration: const InputDecoration(labelText: "Friend's username", prefixIcon: Icon(Icons.person_search_outlined)))),
                const SizedBox(width: 10),
                SizedBox(
                  width: 110,
                  child: DropdownButtonFormField<String>(
                    initialValue: _platform,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Platform'),
                    items: const [DropdownMenuItem(value: 'uplay', child: Text('PC')), DropdownMenuItem(value: 'psn', child: Text('PSN')), DropdownMenuItem(value: 'xbl', child: Text('Xbox'))],
                    onChanged: (v) => setState(() => _platform = v ?? 'uplay'),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: s.otherLoading ? null : _go,
                icon: s.otherLoading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.compare_arrows_rounded),
                label: Text(s.otherLoading ? 'Loading…' : 'Compare (2 API calls)'),
              ),
              if (s.otherError != null) ...[const SizedBox(height: 12), Notice(s.otherError!, color: AppColors.bad, icon: Icons.error_outline)],
              if (o == null && !s.otherLoading && s.otherError == null)
                const Padding(
                  padding: EdgeInsets.only(top: 28),
                  child: EmptyState(icon: Icons.groups_2_outlined, title: 'Pick a rival or a teammate', message: 'Enter their username to see skill radars and key numbers side by side. Only public stats are shown.'),
                ),
              if (o != null) ..._result(s, o),
            ]);
          },
        ),
      );

  void _go() {
    FocusScope.of(context).unfocus();
    widget.state.compareWith(_name.text, _platform);
  }

  List<Widget> _result(AppState s, OtherPlayer o) {
    final me = s.profile!;
    final mineAxes = skillProfile(s.operators), theirAxes = skillProfile(o.operators);
    final a = Totals.of(me.name, s.operators), b = Totals.of(o.profile.name, o.operators);
    Widget head(String name, Color c, String sub) => Expanded(
          child: Column(children: [
            Text(name, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: c)),
            Text(sub, style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
          ]),
        );
    return [
      const SizedBox(height: 18),
      AppCard(
        child: Column(children: [
          Row(children: [
            head(me.name, AppColors.accent, me.currentRankName ?? 'Unranked'),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('vs', style: TextStyle(color: AppColors.textDim))),
            head(o.profile.name, AppColors.accent2, o.profile.currentRankName ?? 'Unranked'),
          ]),
          RadarChart(axes: mineAxes, other: theirAxes, size: 270),
        ]),
      ),
      const SectionTitle('Key numbers', subtitle: 'The higher value is highlighted'),
      AppCard(
        child: Column(children: [
          _row('Level', me.level?.toDouble(), o.profile.level?.toDouble(), (v) => v?.toStringAsFixed(0) ?? '—'),
          _row('K/D', a.kd, b.kd, ratio),
          _row('Round win rate', a.roundWinRate, b.roundWinRate, pct),
          _row('Headshot %', a.headshotRate, b.headshotRate, pct),
          _row('Opening duels won', a.opening, b.opening, pct),
          _row('Rounds survived', a.survival, b.survival, pct),
          _row('Kills per round', a.killsPerRound, b.killsPerRound, ratio),
          _row('Rounds played', a.rounds.toDouble(), b.rounds.toDouble(), (v) => v?.toStringAsFixed(0) ?? '—'),
          _row('Ranked RP', me.ranked?.rankPoints?.toDouble(), o.profile.ranked?.rankPoints?.toDouble(), (v) => v?.toStringAsFixed(0) ?? '—'),
        ]),
      ),
      const SizedBox(height: 10),
      const Text('Skill ratings use the same assumed reference values for both players, so they are comparable with each other, not absolute truth.', style: TextStyle(color: AppColors.textDim, fontSize: 11.5, height: 1.4)),
      TextButton(onPressed: widget.state.clearOther, child: const Text('Clear comparison')),
    ];
  }

  Widget _row(String label, double? x, double? y, String Function(double?) f) {
    final xBetter = (x != null && y != null) ? x > y : null;
    TextStyle st(bool? win) => TextStyle(fontWeight: FontWeight.w900, fontFeatures: tabular, color: win == true ? AppColors.good : AppColors.text);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(flex: 3, child: Text(f(x), style: st(xBetter))),
        Expanded(flex: 5, child: Text(label, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textDim, fontSize: 12.5))),
        Expanded(flex: 3, child: Text(f(y), textAlign: TextAlign.right, style: st(xBetter == null ? null : !xBetter && x != y))),
      ]),
    );
  }
}
