import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../analytics/analytics_screen.dart';
import '../coaching/improve_screen.dart';
import '../common/common.dart';
import '../replays/patterns_screen.dart';

enum _Page { patterns, numbers, improve }

/// Patterns from your replays first (they need nothing), then lifetime stats for those who turned them on.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.state, required this.onOpenSettings});
  final AppState state;
  final VoidCallback onOpenSettings;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  _Page _page = _Page.patterns;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final s = widget.state;
          // Without the optional key the lifetime pages would only say "turn me on", so they are not offered as tabs.
          final lifetime = s.hasStatsKey;
          final page = lifetime ? _page : _Page.patterns;
          final title = Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Stats', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
              const SizedBox(height: 2),
              Text(page == _Page.patterns ? 'Patterns across all your replays.' : 'Your lifetime numbers from the stats service.', style: const TextStyle(color: AppColors.textDim, height: 1.4)),
            ]),
          );
          final tabs = lifetime
              ? Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 14),
                  child: Segmented<_Page>(options: const {_Page.patterns: 'Patterns', _Page.numbers: 'Lifetime', _Page.improve: 'Improve'}, value: page, onChanged: (v) => setState(() => _page = v)),
                )
              : const SizedBox(height: 10);

          if (page == _Page.patterns) {
            return RefreshIndicator(
              color: AppColors.accent,
              backgroundColor: AppColors.surfaceHi,
              onRefresh: () => s.replayServerConfigured ? s.syncReplayServer() : Future.value(),
              child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
                title,
                tabs,
                PatternsView(state: s),
                if (!lifetime)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Center(child: TextButton.icon(onPressed: widget.onOpenSettings, icon: const Icon(Icons.insights_outlined, size: 18), label: const Text('Lifetime stats (optional)'))),
                  ),
              ]),
            );
          }
          final g = gate(context, s, onSetup: widget.onOpenSettings);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [title, tabs])),
            Expanded(
              child: g != null
                  ? ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [g])
                  : page == _Page.numbers
                      ? AnalyticsScreen(key: const ValueKey('numbers'), state: s, onOpenSettings: widget.onOpenSettings, embedded: true)
                      : ImproveScreen(key: const ValueKey('improve'), state: s, onOpenSettings: widget.onOpenSettings, embedded: true),
            ),
          ]);
        },
      );
}
