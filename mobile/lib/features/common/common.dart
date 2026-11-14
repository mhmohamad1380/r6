import 'package:flutter/material.dart';

import '../../analytics/insights.dart';
import '../../app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/scope.dart';

/// Mode chips plus a lifetime / season switch. Opening a mode or period for the first time costs
/// one request; Unranked is derived from Ranked and All, so it costs nothing extra.
class FilterBar extends StatelessWidget {
  const FilterBar(this.state, {super.key, this.showPeriod = true});
  final AppState state;
  final bool showPeriod;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final needs = [for (final k in keysNeeded(s.mode, s.period)) if (!s.hasSet(k)) k];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        height: 42,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final m in ModeFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(label: Text(m.label), selected: s.mode == m, onSelected: (_) => s.setFilter(mode: m)),
            ),
        ]),
      ),
      if (showPeriod && s.seasonId != null) ...[
        const SizedBox(height: 8),
        Segmented<Period>(
          options: {Period.lifetime: 'Lifetime', Period.season: 'This season (${s.seasonId})'},
          value: s.period,
          onChanged: (p) => s.setFilter(period: p),
        ),
      ],
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: Text(
          s.loading && needs.isNotEmpty
              ? 'Loading ${s.filterLabel}… uses ${needs.length} request${needs.length == 1 ? '' : 's'}, once.'
              : '${s.mode.hint}${s.period == Period.season ? ', ${s.seasonId}' : ', all time'}',
          style: const TextStyle(color: AppColors.textDim, fontSize: 12),
        ),
      ),
    ]);
  }
}

Color toneColor(Tone t) => switch (t) { Tone.good => AppColors.good, Tone.warn => AppColors.warn, Tone.info => AppColors.accent };
IconData toneIcon(Tone t) => switch (t) { Tone.good => Icons.trending_up, Tone.warn => Icons.priority_high, Tone.info => Icons.lightbulb_outline };

class InsightCard extends StatelessWidget {
  const InsightCard(this.i, {super.key, this.footer, this.compact = false});
  final Insight i;
  final Widget? footer;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = toneColor(i.tone);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(11)),
            child: Icon(toneIcon(i.tone), size: 18, color: c),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(i.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5))),
          Pill(i.category, color: AppColors.textDim),
        ]),
        const SizedBox(height: 10),
        Text(i.evidence, style: const TextStyle(height: 1.4)),
        const SizedBox(height: 4),
        Text('Based on ${i.sample} ${i.unit}', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
        if (!compact) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.surfaceHi, borderRadius: BorderRadius.circular(12)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.arrow_forward_rounded, size: 16, color: AppColors.accent),
              const SizedBox(width: 8),
              Expanded(child: Text(i.action, style: const TextStyle(fontSize: 13, height: 1.4))),
            ]),
          ),
        ],
        if (!compact && i.drill != null) ...[
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.fitness_center, size: 15, color: AppColors.accent2),
            const SizedBox(width: 8),
            Expanded(child: Text('Try this: ${i.drill}', style: const TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.accent2))),
          ]),
        ],
        ?footer,
      ]),
    );
  }
}

/// Scroll body with pull-to-refresh and room for the nav bar.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.state, required this.children});
  final AppState state;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        color: AppColors.accent,
        backgroundColor: AppColors.surfaceHi,
        onRefresh: () => Future.wait([state.refresh(force: true), if (state.replayServerConfigured) state.syncReplayServer()]), // pulling down updates everything
        child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: children),
      );
}

/// The tabs, in order. Screens use these to send the user somewhere, so nobody has to hunt for a setting.
class Tabs {
  static const home = 0, coach = 1, matches = 2, stats = 3, profile = 4;
}

/// Lets any screen jump to a tab without being handed a callback through every constructor.
class AppNav extends InheritedWidget {
  const AppNav({super.key, required this.goTab, required super.child});
  final void Function(int tab) goTab;

  static AppNav? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppNav>();

  @override
  bool updateShouldNotify(AppNav old) => false;
}

/// Shared first-run / error states for the pages that show lifetime stats from Arenyze.
/// Those need the optional key; the coach and replays never do, and this says so instead of leaving a dead end.
Widget? gate(BuildContext context, AppState s, {required VoidCallback onSetup}) {
  if (!s.hasAccount) {
    return EmptyState(
      icon: Icons.person_outline,
      title: 'Tell us who you are',
      message: 'Add your Ubisoft name so the app can find you in your replays.',
      action: FilledButton(onPressed: onSetup, child: const Text('Add my name')),
    );
  }
  if (!s.hasStatsKey) {
    final nav = AppNav.maybeOf(context);
    // Compact, with the way forward first, so it is on screen even with large text.
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.insights_outlined, color: AppColors.accent),
          SizedBox(width: 10),
          Expanded(child: Text('Lifetime stats are optional', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: 10),
        const Text('Your all-time rank and stats come from a free third-party service that needs its own key, so they are off by default. Your Match Coach does not need them: it works from your own replays.', style: TextStyle(color: AppColors.textDim, height: 1.4, fontSize: 13.5)),
        const SizedBox(height: 14),
        if (nav != null) FilledButton.icon(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)), onPressed: () => nav.goTab(Tabs.coach), icon: const Icon(Icons.school_outlined), label: const Text('Open my Match Coach')),
        Align(alignment: Alignment.center, child: TextButton(onPressed: onSetup, child: const Text('Turn on lifetime stats'))),
      ]),
    );
  }
  if (s.profile == null) {
    if (s.loading) return const LoadingList();
    return EmptyState(
      icon: Icons.cloud_off,
      title: 'Could not load stats',
      message: s.error ?? 'No data yet.',
      action: FilledButton(onPressed: () => s.refresh(force: true, bypassGap: true), child: const Text('Try again')),
    );
  }
  return null;
}

/// Explains why the app cannot show a game that was just played.
void showStaleInfo(BuildContext context, AppState s) => showInfo(
      context,
      'Why is my last game missing?',
      'This app does not talk to Ubisoft directly. It asks Arenyze, which keeps its own saved copy of each player and only re-downloads it from Ubisoft from time to time. '
      'The copy it sent is ${s.serverAge == null ? 'old' : ageText(s.serverAge!)} old, and asking again returns the same copy.\n\n'
      'I tested a no-cache header and several refresh options: none of them changed it. Games played since that copy was made will appear after Arenyze refreshes it. '
      'Replays are not affected: upload the .rec file of a round and it is analysed straight away.',
    );
