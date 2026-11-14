import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../analytics/match_coach.dart';
import '../../analytics/replay_patterns.dart';
import '../../analytics/replay_report.dart';
import '../../app_state.dart';
import '../../core/charts.dart';
import '../../core/replay_charts.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../common/common.dart';
import '../common/guide.dart';
import 'replay_insights_ui.dart';
import 'replay_ui.dart';

String _plus(num v) => '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(v.abs() < 10 ? 1 : 0)}';

String _confidenceText(String c) => c == 'high' ? 'High confidence' : (c == 'medium' ? 'Medium confidence' : 'Low confidence');
Color _confidenceColor(String c) => c == 'high' ? AppColors.good : (c == 'medium' ? AppColors.warn : AppColors.textDim);

void openMatchCoach(BuildContext context, AppState s) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MatchCoachScreen(state: s)));

/// A short card for the Replays tab: your score, what the coach thinks, and a way in.
class CoachEntryCard extends StatelessWidget {
  const CoachEntryCard({super.key, required this.state, required this.coach});
  final AppState state;
  final MatchCoach coach;

  @override
  Widget build(BuildContext context) {
    final v = coach.verdict, sc = coach.report.score;
    return AppCard(
      tint: sc.score == null ? null : scoreColor(sc.score),
      onTap: () => openMatchCoach(context, state),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.school_outlined, size: 20, color: AppColors.accent),
          const SizedBox(width: 8),
          const Expanded(child: Text('Match Coach', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          const Icon(Icons.chevron_right, color: AppColors.textDim),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          GaugeRing(value: sc.score, size: 72, label: 'score'),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(sc.label, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: scoreColor(sc.score))),
              const SizedBox(height: 4),
              Text(v.headline, style: const TextStyle(fontSize: 13.5, height: 1.35)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Text(coach.reviews.isEmpty ? 'Open it to see what to do next.' : 'See each match scored, what to work on, and your plan for the next session.', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.35)),
      ]),
    );
  }
}

enum _Page { overview, matches, details }

class MatchCoachScreen extends StatefulWidget {
  const MatchCoachScreen({super.key, required this.state, this.embedded = false});
  final AppState state;
  final bool embedded; // a main tab: no app bar, a page title instead, and a guided empty state

  @override
  State<MatchCoachScreen> createState() => _MatchCoachScreenState();
}

class _MatchCoachScreenState extends State<MatchCoachScreen> {
  _Page _page = _Page.overview;
  final _open = <String>{};
  MatchCoach? _coach;
  Object? _key;

  MatchCoach _coachFor(AppState s) {
    final key = (s.replays, replayPlayerName(s));
    if (_coach == null || _key != key) {
      _coach = buildMatchCoach(s.replays, replayPlayerName(s));
      _key = key;
    }
    return _coach!;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final c = _coachFor(widget.state);
          final body = ListView(padding: EdgeInsets.fromLTRB(16, widget.embedded ? 8 : 4, 16, 32), children: [
            if (widget.embedded) ...[
              const Padding(padding: EdgeInsets.fromLTRB(4, 8, 4, 4), child: Text('Match Coach', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900))),
              Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 12), child: Text(c.report.hasRounds ? 'How you played, and what to do next.' : 'Your score and plan appear here once replays arrive.', style: const TextStyle(color: AppColors.textDim, height: 1.4))),
              if (c.report.hasRounds) Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 12), child: _who(widget.state)),
            ],
            if (!c.report.hasRounds) ...[
              NextStepCard(step: nextStepFor(widget.state), onAction: (id) => runStep(context, widget.state, id), onSecondary: () => AppNav.maybeOf(context)?.goTab(Tabs.matches)),
            ] else ...[
              Segmented<_Page>(options: const {_Page.overview: 'Overview', _Page.matches: 'Matches', _Page.details: 'Details'}, value: _page, onChanged: (v) => setState(() => _page = v)),
              const SizedBox(height: 14),
              if (_page == _Page.overview) ..._overview(context, c) else if (_page == _Page.matches) ..._matches(context, c) else ..._details(context, c),
            ],
          ]);
          if (widget.embedded) return RefreshIndicator(color: AppColors.accent, backgroundColor: AppColors.surfaceHi, onRefresh: () => widget.state.replayServerConfigured ? widget.state.syncReplayServer() : Future.value(), child: body);
          return Scaffold(appBar: AppBar(title: const Text('Match Coach'), backgroundColor: AppColors.bg, surfaceTintColor: Colors.transparent), body: body);
        },
      );

  /// Who the coach thinks you are, and how it knows, so a wrong guess is easy to spot and fix.
  Widget _who(AppState s) => Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Icon(Icons.person_pin_circle_outlined, size: 16, color: AppColors.textDim),
        Text('Playing as ${s.playerName}${s.nameFromReplays || (s.detected?.how == 'recorded' && s.username.isEmpty) ? ', found in your replays' : ''}', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5)),
        InkWell(onTap: () => AppNav.maybeOf(context)?.goTab(Tabs.profile), child: const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Not you?', style: TextStyle(color: AppColors.accent, fontSize: 12.5, fontWeight: FontWeight.w700)))),
      ]);

  // ---------------------------------------------------------------- overview
  List<Widget> _overview(BuildContext context, MatchCoach c) {
    final v = c.verdict, r = c.report, sc = r.score, imp = r.improvement;
    return [
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            GaugeRing(value: sc.score, size: 104, label: 'of 100'),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(sc.label, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: scoreColor(sc.score)))),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  Pill(_confidenceText(sc.confidence), color: _confidenceColor(sc.confidence)),
                  if (imp.delta != null && imp.trend != Trend.unknown) DeltaChip('${_plus(imp.delta!)} vs earlier', up: imp.delta! >= 0, neutral: imp.trend == Trend.steady),
                ]),
                const SizedBox(height: 6),
                Text('${sc.rounds} rounds in ${r.matches} match${r.matches == 1 ? '' : 'es'}', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5)),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          Text(v.headline, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5, height: 1.3)),
          if (v.detail.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(v.detail, style: const TextStyle(color: AppColors.textDim, fontSize: 13, height: 1.4))),
          if (sc.provisional) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Based on ${sc.rounds} rounds, so treat it as a first read. More matches make it steadier.', style: const TextStyle(color: AppColors.textDim, fontSize: 12, height: 1.35))),
        ]),
      ),
      const SectionTitle('Work on this first', subtitle: 'The single change that should help most'),
      if (v.focus != null)
        FindingCard(v.focus!)
      else if (v.gap != null)
        _gapCard(v.gap!)
      else
        const AppCard(child: Row(children: [Icon(Icons.check_circle_outline, color: AppColors.good), SizedBox(width: 10), Expanded(child: Text('No clear weakness in these replays. Keep playing and this updates.', style: TextStyle(height: 1.35)))])),
      if (v.strengths.isNotEmpty) ...[
        const SectionTitle('What you do well'),
        AppCard(
          child: Column(children: [
            for (final s in v.strengths)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.check_circle, size: 18, color: AppColors.good)),
                  const SizedBox(width: 10),
                  Expanded(child: Text.rich(TextSpan(children: [TextSpan(text: '${s.title}: ', style: const TextStyle(fontWeight: FontWeight.w800)), TextSpan(text: s.text)]), style: const TextStyle(fontSize: 14, height: 1.35))),
                ]),
              ),
          ]),
        ),
      ],
      if (v.plan.isNotEmpty) ...[
        const SectionTitle('Plan for your next session', subtitle: 'Small, specific things to try'),
        AppCard(
          child: Column(children: [
            for (var i = 0; i < v.plan.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(width: 24, height: 24, alignment: Alignment.center, decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.16), shape: BoxShape.circle), child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12.5, color: AppColors.accent))),
                  const SizedBox(width: 12),
                  Expanded(child: Text(v.plan[i], style: const TextStyle(fontSize: 14, height: 1.4))),
                ]),
              ),
          ]),
        ),
      ],
      if (v.best != null && v.worst != null) ...[
        const SectionTitle('Best and worst match'),
        _bestWorst(context, v.best!, v.worst!),
      ],
      const SectionTitle('Your score over time', subtitle: 'Older matches on the left'),
      improvementCard(context, r),
      ..._patternsTeaser(context),
    ];
  }

  /// The strongest pattern across all matches, and the way to the rest, so the Stats tab is found.
  List<Widget> _patternsTeaser(BuildContext context) {
    final s = widget.state;
    final p = cachedPatterns(s.replays, s.playerName, population: s.population);
    if (p.rounds < 10) return const [];
    final top = p.findings.isEmpty ? null : p.findings.first;
    return [
      const SectionTitle('Patterns', subtitle: 'Squad, enemy operators, spawns, pressure and more'),
      AppCard(
        onTap: () => AppNav.maybeOf(context)?.goTab(Tabs.stats),
        child: Row(children: [
          const Icon(Icons.auto_graph, color: AppColors.accent2),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(top?.title ?? 'See what your replays say across all matches', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, height: 1.3)),
              const SizedBox(height: 4),
              Text(p.findings.length > 1 ? '${p.findings.length - 1} more finding${p.findings.length == 2 ? '' : 's'} in Stats' : 'Open Stats to explore', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5)),
            ]),
          ),
          const Icon(Icons.chevron_right, color: AppColors.textDim),
        ]),
      ),
    ];
  }

  Widget _gapCard(Reason g) => AppCard(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 1), child: Icon(Icons.warning_amber_rounded, color: AppColors.warn)),
          const SizedBox(width: 10),
          Expanded(child: Text.rich(TextSpan(children: [const TextSpan(text: 'Your weakest part is '), TextSpan(text: g.title.toLowerCase(), style: const TextStyle(fontWeight: FontWeight.w800)), TextSpan(text: '. ${g.text}. It is the lowest of your seven score parts.')]), style: const TextStyle(height: 1.4))),
        ]),
      );

  Widget _bestWorst(BuildContext context, MatchReview best, MatchReview worst) {
    Widget tile(String label, MatchReview m, Color c) => Expanded(
          child: AppCard(
            padding: const EdgeInsets.all(14),
            onTap: () => _openMatch(context, m),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 12)),
              const SizedBox(height: 4),
              Text('${m.score!.round()}', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: scoreColor(m.score), fontFeatures: tabular)),
              Text(m.map, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              Text(m.at == null ? m.type : dayLabel(m.at!.toLocal()), style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
            ]),
          ),
        );
    return IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [tile('Best', best, AppColors.good), const SizedBox(width: 10), tile('Worst', worst, AppColors.bad)]));
  }

  void _openMatch(BuildContext context, MatchReview m) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReplayMatchScreen(state: widget.state, matchId: m.matchId)));

  // ---------------------------------------------------------------- matches
  List<Widget> _matches(BuildContext context, MatchCoach c) {
    final scored = [for (final m in c.reviews) if (m.score != null) m.score!];
    final avg = scored.isEmpty ? null : scored.reduce((a, b) => a + b) / scored.length;
    return [
      if (c.reviews.isEmpty)
        const EmptyState(icon: Icons.history, title: 'No scored matches yet', message: 'A match needs at least 3 rounds you played.')
      else ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text('${c.reviews.length} match${c.reviews.length == 1 ? '' : 'es'}${avg == null ? '' : ' · average score ${avg.round()}'}. Each one is compared with your own usual level.', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.35)),
        ),
        for (final m in c.reviews) Padding(padding: const EdgeInsets.only(bottom: 10), child: _reviewCard(context, m, c.verdict)),
      ],
    ];
  }

  Widget _reasonRow(Reason r, bool good) => Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(good ? Icons.arrow_upward : Icons.arrow_downward, size: 15, color: good ? AppColors.good : AppColors.bad)),
          const SizedBox(width: 8),
          Expanded(child: Text(r.text, style: const TextStyle(fontSize: 13, height: 1.35))),
        ]),
      );

  Widget _reviewCard(BuildContext context, MatchReview m, CoachVerdict v) {
    final tag = v.best?.matchId == m.matchId ? 'Best' : (v.worst?.matchId == m.matchId ? 'Worst' : null);
    return AppCard(
      onTap: () => _openMatch(context, m),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.map, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 2),
              Text('${m.type}${m.at == null ? '' : ' · ${dayLabel(m.at!.toLocal())}'} · ${m.rounds} rounds', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5)),
            ]),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(m.score == null ? '—' : '${m.score!.round()}', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, height: 1, color: scoreColor(m.score), fontFeatures: tabular)),
            Text(m.label, style: const TextStyle(color: AppColors.textDim, fontSize: 11.5)),
          ]),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Pill(m.won == null ? '${m.wins}W ${m.losses}L' : '${m.won! ? 'Won' : 'Lost'} ${m.wins}–${m.losses}', color: m.won == null ? AppColors.textDim : (m.won! ? AppColors.good : AppColors.bad)),
          if (m.vsUsual != null) DeltaChip('${_plus(m.vsUsual!)} vs usual', up: m.vsUsual! >= 0, neutral: m.vsUsual!.abs() < 8),
          if (tag != null) Pill(tag, color: tag == 'Best' ? AppColors.good : AppColors.bad),
          Text('${m.kills}K ${m.deaths}D', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 10),
        Text(m.headline, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, height: 1.35)),
        for (final r in m.strengths) _reasonRow(r, true),
        for (final r in m.weaknesses) _reasonRow(r, false),
      ]),
    );
  }

  // ---------------------------------------------------------------- details
  List<Widget> _details(BuildContext context, MatchCoach c) => [
        const Padding(padding: EdgeInsets.fromLTRB(4, 0, 4, 12), child: Text('The numbers behind the coach. Open a section to see it.', style: TextStyle(color: AppColors.textDim, fontSize: 12.5))),
        for (final s in detailSections(context, c.report)) _section(s),
      ];

  Widget _section(DetailSection s) {
    final open = _open.contains(s.title);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppCard(
          padding: EdgeInsets.zero,
          child: Semantics(
            button: true,
            expanded: open,
            label: '${s.title}. ${s.preview}',
            excludeSemantics: true,
            child: InkWell(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => open ? _open.remove(s.title) : _open.add(s.title));
              },
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  Icon(s.icon, color: AppColors.accent2, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(s.preview, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.3)),
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
          child: open ? Padding(padding: const EdgeInsets.only(top: 8), child: s.body) : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }
}
