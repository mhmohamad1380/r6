import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../analytics/breakdowns.dart';
import '../../analytics/match_coach.dart';
import '../../analytics/next_step.dart';
import '../../analytics/insights.dart';
import '../../analytics/scoring.dart';
import '../../analytics/rank_progress.dart';
import '../../analytics/recap.dart';
import '../../analytics/skills.dart';
import '../../analytics/summary.dart';
import '../../app_state.dart';
import '../../core/charts.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../clips/clips.dart';
import '../common/common.dart';
import '../common/guide.dart';
import '../matches/match_widgets.dart';
import '../replays/coach_screen.dart';
import '../replays/replay_ui.dart';
import 'rank_progress_card.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.state, required this.onOpenSettings, required this.onOpenTab});
  final AppState state;
  final VoidCallback onOpenSettings;
  final ValueChanged<int> onOpenTab;

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: state, builder: (context, _) => _body(context));

  /// Home for someone using replays only: where you are, what to do next, and your coach at a glance.
  Widget _replayHome(BuildContext context) {
    final step = nextStepFor(state);
    final coach = state.replays.isEmpty ? null : buildMatchCoach(state.replays, replayPlayerName(state));
    final rounds = state.replays.length;
    return PageBody(state: state, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Text(state.hasAccount ? 'Hi, ${state.playerName}' : 'R6 Coach', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
        child: Text(
          rounds == 0 ? 'Your matches will show up here.' : '$rounds round${rounds == 1 ? '' : 's'} saved${state.lastReplaySync == null ? '' : ' · synced ${ago(state.lastReplaySync)}'}',
          style: const TextStyle(color: AppColors.textDim, height: 1.4),
        ),
      ),
      if (state.notice != null) ...[Notice(state.notice!, color: AppColors.accent), const SizedBox(height: 12)],
      // Once replays are flowing the coach card says it all; the step card is for getting there.
      if (step.id != StepId.coach || coach == null || !coach.report.hasRounds) NextStepCard(step: step, onAction: (id) => runStep(context, state, id), onSecondary: () => onOpenTab(Tabs.matches)),
      if (coach != null && coach.report.hasRounds) CoachEntryCard(state: state, coach: coach),
      if (state.highlights.isNotEmpty) ...[const SizedBox(height: 12), LatestClipCard(state: state)],
      const SizedBox(height: 14),
      if (state.replayServerConfigured)
        OutlinedButton.icon(
          onPressed: state.replaySyncing ? null : () async {
            final r = await state.syncReplayServer();
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.summary)));
          },
          icon: state.replaySyncing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_download_outlined),
          label: Text(state.replaySyncing ? 'Syncing…' : 'Sync replays now'),
        ),
    ]);
  }

  Widget _body(BuildContext context) {
    if (!state.configured) return _replayHome(context); // no optional stats key: the app is the coach and the replays
    final g = gate(context, state, onSetup: onOpenSettings);
    if (g != null) return g;
    final p = state.profile!;
    final ops = state.activeOps;
    final rp = state.rp;
    final week = weekRecap(rp.deltas);
    final form = recentForm(state.matchLog);
    final rank = p.latestRank;
    final rankColor = parseHex(rank?.colorHex);
    final ranked = p.ranked;
    final season = p.rankedSeason;
    final waiting = ops.isEmpty;
    final stats = aggregate(ops, mode: scoringMode(state.mode));
    final score = scoreMatch(stats);
    final skills = skillProfile(ops);
    final tot = Totals.of('All', ops);
    final insights = buildInsights(ops, game: state.game, rp: rp, profile: p);
    final log = state.matchLog;
    final rankProg = rankProgress(ranked?.rankPoints, state.ranks, rp);

    return PageBody(state: state, children: [
      // Header
      Row(children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: AppColors.surfaceHi,
          backgroundImage: p.avatarUrl == null ? null : NetworkImage(p.avatarUrl!),
          onBackgroundImageError: p.avatarUrl == null ? null : (_, _) {},
          child: p.avatarUrl == null ? const Icon(Icons.person) : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            Text('Level ${p.level ?? '—'} · data from ${state.serverStale ? ageText(state.serverAge!) : ago(state.fetchedAt).replaceAll(' ago', '')} ago', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5)),
          ]),
        ),
        state.loading
            ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4)))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Copy summary',
                  icon: const Icon(Icons.ios_share_rounded),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: buildSummary(p, state.operators, rp, game: state.game)));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Summary copied. Paste it anywhere.'), duration: Duration(seconds: 2)));
                  },
                ),
                IconButton(tooltip: 'Refresh', onPressed: () => state.refresh(force: true), icon: const Icon(Icons.refresh_rounded)),
              ]),
      ]),
      const SizedBox(height: 12),
      if (state.error != null) ...[Notice(state.error!, color: AppColors.bad, icon: Icons.error_outline), const SizedBox(height: 12)],
      if (state.serverStale) ...[
        Notice(
          'The server\'s copy of your stats is ${ageText(state.serverAge!)} old, so recent games may be missing. Refreshing here cannot make it newer.',
          color: AppColors.warn,
          icon: Icons.history_toggle_off,
          action: TextButton(onPressed: () => showStaleInfo(context, state), child: const Text('Why?')),
        ),
        const SizedBox(height: 12),
      ],
      if (state.notice != null) ...[Notice(state.notice!, color: AppColors.accent), const SizedBox(height: 12)],

      if (!nextStepFor(state).complete) ...[
        NextStepCard(step: nextStepFor(state), onAction: (id) => runStep(context, state, id), onSecondary: () => onOpenTab(Tabs.matches)),
        const SizedBox(height: 12),
      ],
      if (state.highlights.isNotEmpty) ...[LatestClipCard(state: state), const SizedBox(height: 12)],

      // Rank hero
      AppCard(
        tint: rankColor,
        child: Row(children: [
          RankBadge(url: rank?.imageUrl, size: 92, color: rankColor),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(rank?.rank ?? 'Unranked', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: rankColor))),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  AnimatedNumber(ranked?.rankPoints?.toDouble(), style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, height: 1.1)),
                  const SizedBox(width: 6),
                  const Padding(padding: EdgeInsets.only(bottom: 5), child: Text('RP', style: TextStyle(color: AppColors.textDim, fontWeight: FontWeight.w700))),
                ]),
              ),
              Text('${season?.shortName ?? ''} ${season?.seasonName ?? ''}'.trim(), style: const TextStyle(color: AppColors.textDim, fontSize: 12.5)),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                if (ranked?.matches != null) Pill('${ranked!.wins}W · ${ranked.losses}L', color: AppColors.text),
                if (rp.streak.abs() >= 2) Pill(rp.streak > 0 ? '${rp.streak} win streak' : '${-rp.streak} loss streak', color: rp.streak > 0 ? AppColors.good : AppColors.bad, icon: rp.streak > 0 ? Icons.local_fire_department : Icons.trending_down),
              ]),
            ]),
          ),
        ]),
      ),
      if (rankProg != null) ...[const SizedBox(height: 12), RankProgressCard(progress: rankProg, color: rankColor)],
      const SizedBox(height: 14),
      FilterBar(state),
      const SizedBox(height: 14),

      if (waiting)
        state.loading ? const Column(children: [Skeleton(height: 150), SizedBox(height: 14), Skeleton(height: 300)]) : Notice(state.activeReady ? 'No rounds recorded for ${state.filterLabel}.' : 'No ${state.filterLabel} data yet. Pull down to refresh.', color: AppColors.textDim)
      else ...[
        // Score
        AppCard(
          child: Row(children: [
            GaugeRing(value: score.score, size: MediaQuery.sizeOf(context).width < 340 ? 96 : 118, label: 'of 100'),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Expanded(child: Text('Performance', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
                  InkWell(
                    onTap: () => showInfo(context, 'How the score works', 'The score blends three parts: mechanical (K/D and headshots), tactical (opening duels) and objective (rounds your team won). Weights and reference values are untested design assumptions, so 50 means "typical" only by that assumption. Treat it as a compass, not a verdict.'),
                    child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.info_outline, size: 18, color: AppColors.textDim)),
                  ),
                ]),
                const SizedBox(height: 6),
                ConfidenceChip(score.confidence),
                const SizedBox(height: 10),
                for (final e in score.components.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Row(children: [
                      SizedBox(width: 78, child: Text(e.key, style: const TextStyle(color: AppColors.textDim, fontSize: 12.5))),
                      Text(e.value?.toStringAsFixed(0) ?? '—', style: TextStyle(fontWeight: FontWeight.w800, color: scoreColor(e.value))),
                    ]),
                  ),
              ]),
            ),
          ]),
        ),

        // Skill profile
        SectionTitle('Skill profile', subtitle: '${state.filterLabel} · ${tot.rounds} rounds · grey ring = typical player'),
        AppCard(
          child: Column(children: [
            RadarChart(axes: skills),
            const SizedBox(height: 8),
            for (final a in skills)
              InkWell(
                onTap: () => showInfo(context, a.label, '${a.help}\n\nYou: ${a.value} (${a.sample}).${a.score == null ? '\nNot enough data yet to rate this.' : '\nRated ${a.score!.toStringAsFixed(0)} / 100 against assumed typical values.'}'),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: BarRow(label: a.label, fraction: a.score == null ? null : a.score! / 100, valueText: a.value, color: scoreColor(a.score), caption: a.score == null ? 'Need more data (${a.sample})' : null),
                ),
              ),
          ]),
        ),

        // KPIs
        SectionTitle('Key numbers', subtitle: state.filterLabel),
        Column(children: [
          _pair(
            StatTile(label: 'K/D', value: tot.kd, digits: 2, caption: '${tot.kills} kills · ${tot.deaths} deaths', color: tot.kd == null ? null : (tot.kd! >= 1 ? AppColors.good : AppColors.warn)),
            StatTile(label: 'Round win rate', value: tot.roundWinRate == null ? null : tot.roundWinRate! * 100, suffix: '%', caption: '${tot.roundsWon} of ${tot.rounds} rounds'),
          ),
          const SizedBox(height: 12),
          _pair(
            StatTile(label: 'Headshot %', value: tot.headshotRate == null ? null : tot.headshotRate! * 100, suffix: '%', caption: '${tot.headshots} headshots'),
            StatTile(label: 'Opening duels', value: tot.opening == null ? null : tot.opening! * 100, suffix: '%', caption: '${tot.fb} won · ${tot.fd} lost', color: tot.opening == null ? null : (tot.opening! >= 0.5 ? AppColors.good : AppColors.warn)),
          ),
        ]),
      ],

      // RP
      if (state.rpHistory.length >= 2) ...[
        SectionTitle('Ranked points', subtitle: 'Last ${state.rpHistory.length} readings', trailing: rp.hasData ? Pill('${signed(rp.net)} RP', color: rp.net >= 0 ? AppColors.good : AppColors.bad) : null),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            RpLineChart(points: state.rpHistory.take(40).toList()),
            if (rp.hasData) ...[
              const SizedBox(height: 14),
              const Text('Recent results (inferred from RP)', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
              const SizedBox(height: 8),
              FormStrip(rp.deltas),
            ],
          ]),
        ),
      ],

      if (week != null) ...[
        const SectionTitle('This week'),
        AppCard(
          child: Row(children: [
            Expanded(child: _mini('Games', '${week.games}', '${week.wins}W ${week.losses}L')),
            Expanded(child: _mini('Net RP', signed(week.net), week.net >= 0 ? 'up' : 'down', color: week.net >= 0 ? AppColors.good : AppColors.bad)),
            Expanded(child: _mini('Best day', week.bestDay?.substring(0, 3) ?? '—', '${week.days} day${week.days == 1 ? '' : 's'} played')),
          ]),
        ),
      ],
      if (form != null) ...[
        SectionTitle('Recent form', subtitle: 'Your last ${form.matches} tracked matches vs your career'),
        AppCard(
          child: Column(children: [
            _formRow('K/D', form.kd, tot.kd, ratio),
            _formRow('Win rate', form.winRate, tot.roundWinRate, pct),
            _formRow('Headshot %', form.headshotRate, tot.headshotRate, pct),
            _formRow('Opening duels', form.openingRate, tot.opening, pct),
          ]),
        ),
      ],

      // Latest match
      if (log.isNotEmpty) ...[
        SectionTitle('Latest match', trailing: TextButton(onPressed: () => onOpenTab(1), child: const Text('See all'))),
        MatchCard(record: log.first, state: state),
      ],

      // Insights
      if (!waiting) ...[
        SectionTitle('What to work on', trailing: TextButton(onPressed: () => onOpenTab(3), child: const Text('Full plan'))),
        for (final i in insights.take(3)) Padding(padding: const EdgeInsets.only(bottom: 12), child: InsightCard(i, compact: true)),
      ],
      const SizedBox(height: 4),
      Center(child: Text('${state.callsThisMonth} of ${AppState.monthlyQuota} API calls used this month on this device', style: const TextStyle(color: AppColors.textDim, fontSize: 11.5))),
    ]);
  }
}

Widget _mini(String l, String v, String sub, {Color? color}) => Column(children: [
      Text(v, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: color)),
      Text(l, style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
      Text(sub, style: const TextStyle(color: AppColors.textDim, fontSize: 11)),
    ]);

Widget _formRow(String label, double? now, double? base, String Function(double?) f) {
  final better = (now != null && base != null) ? now >= base : null;
  final col = better == null ? AppColors.textDim : (better ? AppColors.good : AppColors.bad);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(children: [
      Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
      Text(f(now), style: TextStyle(fontWeight: FontWeight.w900, color: col, fontFeatures: tabular)),
      const SizedBox(width: 6),
      Icon(better == null ? Icons.remove : (better ? Icons.arrow_upward : Icons.arrow_downward), size: 15, color: col),
      const SizedBox(width: 10),
      SizedBox(width: 74, child: Text('career ${f(base)}', textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textDim, fontSize: 12))),
    ]),
  );
}

Widget _pair(Widget a, Widget b) => IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: a), const SizedBox(width: 12), Expanded(child: b)]),
    );
