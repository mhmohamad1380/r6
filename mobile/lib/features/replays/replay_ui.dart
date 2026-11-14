import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../analytics/replay_report.dart';
import '../../analytics/replay_stats.dart';
import '../../app_state.dart';
import '../../core/charts.dart';
import '../../core/replay_charts.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/replay.dart';
import '../../analytics/match_coach.dart';
import 'coach_screen.dart';
import 'replay_insights_ui.dart';

/// The player the replay analysis is about: the Ubisoft name from the profile, else the one typed at setup.
String replayPlayerName(AppState s) => s.playerName;

String _name(AppState s) => replayPlayerName(s);

void _snack(BuildContext c, String m) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

String _resultText(ReplayImport r) => r.message ?? 'Imported ${r.added} round${r.added == 1 ? '' : 's'}${r.duplicates > 0 ? ', ${r.duplicates} already saved' : ''}${r.errors > 0 ? ', ${r.errors} skipped' : ''}.';

Future<void> _upload(BuildContext context, AppState s) async {
  final picked = await FilePicker.pickFiles(); // any type: Android does not know the .rec extension
  if (picked.isEmpty || !context.mounted) return;
  final paths = [for (final f in picked) if (f.path != null && f.name.toLowerCase().endsWith('.rec')) f.path!];
  if (paths.isEmpty) {
    _snack(context, 'Choose .rec replay files.');
    return;
  }
  final left = s.replayQuota?.remaining;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Upload ${paths.length} file${paths.length == 1 ? '' : 's'}?'),
      content: Text('Each file uses one replay credit${left == null ? '' : ' (you have $left left)'}. Choose rounds from a single match. Uploading can take about 30 seconds per file.'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Upload'))],
    ),
  );
  if (ok != true || !context.mounted) return;
  final r = await s.uploadReplays(paths);
  if (context.mounted) _snack(context, _resultText(r));
}

Future<void> _importJson(BuildContext context, AppState s) async {
  final how = await showModalBottomSheet<String>(
    context: context,
    builder: (c) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.folder_open), title: const Text('Choose a .json file'), subtitle: const Text('Made on a PC with r6-dissect'), onTap: () => Navigator.pop(c, 'file')),
        ListTile(leading: const Icon(Icons.content_paste), title: const Text('Paste from clipboard'), onTap: () => Navigator.pop(c, 'paste')),
      ]),
    ),
  );
  if (how == null || !context.mounted) return;
  String? text;
  if (how == 'file') {
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    final buf = StringBuffer('[');
    var first = true;
    for (final f in picked.where((f) => f.path != null && f.name.toLowerCase().endsWith('.json'))) {
      if (!first) buf.write(',');
      buf.write(await File(f.path!).readAsString());
      first = false;
    }
    buf.write(']');
    text = first ? null : buf.toString();
  } else {
    text = (await Clipboard.getData('text/plain'))?.text;
  }
  if (text == null || text.trim().isEmpty) {
    if (context.mounted) _snack(context, 'Nothing to import.');
    return;
  }
  final r = await s.importReplayJson(text);
  if (context.mounted) _snack(context, _resultText(r));
}

void showKostInfo(BuildContext context) => showInfo(
      context,
      'KOST',
      'The share of rounds where you made a difference: a Kill, an Objective play (plant or defuse), you Survived, or you were Traded (a teammate killed your killer within 5 seconds).\\n\\n'
      'Replays uploaded through Arenyze have the right kill order but no usable kill times, so Traded cannot be counted and KOST is a minimum. Import the JSON made by r6-dissect for exact timing.',
    );

/// The Replays tab of Matches.
List<Widget> replaysSection(BuildContext context, AppState s) {
  final matches = groupMatches(s.replays);
  final coach = matches.isEmpty ? null : buildMatchCoach(s.replays, _name(s));
  final q = s.replayQuota;
  return [
    AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.movie_filter_outlined, color: AppColors.accent2),
          const SizedBox(width: 8),
          const Expanded(child: Text('Replay analysis', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          if (q != null) Pill('${q.remaining} of ${q.limit} credits', color: q.remaining > 3 ? AppColors.good : AppColors.warn),
        ]),
        const SizedBox(height: 8),
        const Text('Siege saves one .rec file per round. Collect them from your PC automatically, or add them by hand, and this tab turns them into a score, charts and coaching.', style: TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.4)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 36), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            onPressed: () => showInfo(
              context,
              'Where are my replay files?',
              'Siege saves a .rec file for each round of your recent matches in the MatchReplay folder inside the game\'s install folder on your PC (for example ...\\Tom Clancy\'s Rainbow Six Siege\\MatchReplay), not in Documents.\n\n'
              'The game only keeps about the last 10 to 12 matches, so copy them soon. The Windows uploader does this for you and sends them to your replay server.',
            ),
            child: const Text('Where are my replay files?'),
          ),
        ),
        const SizedBox(height: 12),
        if (s.replayServerConfigured) ...[
          FilledButton.icon(
            onPressed: s.replaySyncing ? null : () async {
              final r = await s.syncReplayServer();
              if (context.mounted) _snack(context, r.summary);
            },
            icon: s.replaySyncing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_download_outlined),
            label: Text(s.replaySyncing ? 'Syncing…' : 'Sync from server'),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 12),
            child: Text(s.lastReplaySync == null ? 'Not synced yet. Syncs automatically when you open the app.' : 'Last synced ${ago(s.lastReplaySync)}. Syncs automatically when you open the app.', style: const TextStyle(color: AppColors.textDim, fontSize: 11.5)),
          ),
        ] else
          const Padding(padding: EdgeInsets.only(bottom: 12), child: Notice('Set up the replay server in Profile to collect replays from your PC automatically.', color: AppColors.accent, icon: Icons.cloud_outlined)),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: s.replayBusy ? null : () => _upload(context, s),
              icon: s.replayBusy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_file, size: 18),
              label: Text(s.replayBusy ? 'Uploading…' : 'Upload .rec'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: OutlinedButton.icon(onPressed: () => _importJson(context, s), icon: const Icon(Icons.data_object, size: 18), label: const Text('Import JSON'))),
        ]),
        const SizedBox(height: 8),
        const Text('Uploads use one free replay credit per file, not API requests. JSON import is free.', style: TextStyle(color: AppColors.textDim, fontSize: 11.5)),
      ]),
    ),
    if (matches.isEmpty) ...[
      const SizedBox(height: 16),
      const EmptyState(icon: Icons.slow_motion_video_outlined, title: 'No replays yet', message: 'Import a few rounds and this tab fills with your KOST, opening duels and results by bombsite.'),
    ] else ...[
      if (!coach!.report.hasRounds)
        Padding(padding: const EdgeInsets.only(top: 16), child: Notice('${_name(s)} is not in these replays. Open a match and pick a player to view their rounds.', color: AppColors.textDim))
      else ...[
        const SizedBox(height: 16),
        CoachEntryCard(state: s, coach: coach),
      ],
      const SectionTitle('Matches', subtitle: 'Tap one to replay it round by round'),
      for (final g in matches)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _MatchCard(rounds: g, state: s),
        ),
    ],
  ];
}

Widget _big(String v, String l) => statTile(v, l);

class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.rounds, required this.state});
  final List<ReplayRound> rounds;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final f = rounds.first;
    final rep = buildReplayReport(rounds, _name(state), withFindings: false);
    final sum = rep.summary;
    return AppCard(
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReplayMatchScreen(state: state, matchId: f.matchId))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(f.map, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          if (rep.score.score != null) ...[Pill('Score ${rep.score.score!.round()}', color: scoreColor(rep.score.score)), const SizedBox(width: 6)],
          Pill(f.matchType, color: AppColors.accent),
        ]),
        const SizedBox(height: 4),
        Text('${rounds.length} round${rounds.length == 1 ? '' : 's'} · ${f.at == null ? '' : '${dayLabel(f.at!.toLocal())} · '}${f.timed ? 'exact timing' : 'kill order only'}', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5)),
        if (sum.rounds > 0) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 14, runSpacing: 4, children: [
            Text('${sum.wins}W ${sum.losses}L', style: const TextStyle(fontWeight: FontWeight.w800)),
            Text('KOST ${pct(sum.kost)}${sum.kostIsLowerBound ? '+' : ''}', style: const TextStyle(fontWeight: FontWeight.w800)),
            Text('${sum.kills}K ${sum.deaths}D', style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 4, runSpacing: 4, children: [
            for (final x in rep.extras)
              Tooltip(
                message: 'Round ${x.my.round.number}: ${x.my.won == null ? 'unknown' : (x.my.won! ? 'won' : 'lost')}',
                child: Container(width: 14, height: 6, decoration: BoxDecoration(color: x.my.won == null ? AppColors.textDim : (x.my.won! ? AppColors.good : AppColors.bad), borderRadius: BorderRadius.circular(3))),
              ),
          ]),
        ] else
          const Padding(padding: EdgeInsets.only(top: 8), child: Text('You are not in this match. Tap to view another player.', style: TextStyle(color: AppColors.textDim, fontSize: 12))),
      ]),
    );
  }
}

class ReplayMatchScreen extends StatefulWidget {
  const ReplayMatchScreen({super.key, required this.state, required this.matchId});
  final AppState state;
  final String matchId;

  @override
  State<ReplayMatchScreen> createState() => _ReplayMatchScreenState();
}

class _ReplayMatchScreenState extends State<ReplayMatchScreen> {
  String? _who;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final rounds = groupMatches(widget.state.replays).where((g) => g.first.matchId == widget.matchId).firstOrNull;
          if (rounds == null) return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.delete_outline, title: 'Replay removed', message: 'This match is no longer saved.'));
          final players = <String, int>{};
          for (final r in rounds) {
            for (final p in r.players) {
              players.putIfAbsent(p.name, () => p.team);
            }
          }
          final preferred = _name(widget.state);
          final who = _who ?? players.keys.where((n) => n.toLowerCase() == preferred.toLowerCase()).firstOrNull ?? rounds.first.players.first.name;
          final mine = [for (final r in rounds) analyzeRound(r, who)];
          final sum = summarize(mine);
          final rep = buildReplayReport(rounds, who, withFindings: false);
          final board = leaderboard(rounds);
          final f = rounds.first;
          return Scaffold(
            appBar: AppBar(title: Text('${f.map} · ${f.matchType}'), backgroundColor: AppColors.bg, surfaceTintColor: Colors.transparent, actions: [
              IconButton(
                tooltip: 'Remove this replay',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Remove this replay?'),
                      content: const Text('It is removed from this device. Your replay credits are not refunded.'),
                      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove'))],
                    ),
                  );
                  if (ok == true) {
                    await widget.state.deleteReplayMatch(widget.matchId);
                    if (context.mounted) Navigator.of(context).pop();
                  }
                },
              ),
            ]),
            body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
              DropdownButtonFormField<String>(
                initialValue: who,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Viewing', prefixIcon: Icon(Icons.person_outline)),
                items: [for (final n in players.keys) DropdownMenuItem(value: n, child: Text('$n  ·  team ${players[n]! + 1}', overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _who = v),
              ),
              const SizedBox(height: 12),
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('${rounds.length} round${rounds.length == 1 ? '' : 's'} · ${sum.wins}W ${sum.losses}L', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
                    Pill(f.timed ? 'exact timing' : 'kill order only', color: f.timed ? AppColors.good : AppColors.warn),
                  ]),
                  const SizedBox(height: 14),
                  Row(children: [
                    Expanded(child: _big('${sum.kost == null ? '—' : (sum.kost! * 100).toStringAsFixed(0)}%${sum.kostIsLowerBound ? '+' : ''}', 'KOST')),
                    Expanded(child: _big('${sum.kills}/${sum.deaths}${sum.assists == null ? '' : '/${sum.assists}'}', sum.assists == null ? 'K / D' : 'K / D / A')),
                    Expanded(child: _big(pct(sum.headshotRate), 'Headshots')),
                    Expanded(child: _big(sum.openingKills + sum.openingDeaths == 0 ? '—' : '${sum.openingKills}-${sum.openingDeaths}', 'Opening')),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: _big(pct(sum.survival), 'Survived')),
                    Expanded(child: _big(pct(sum.avengedRate), 'Avenged')),
                    Expanded(child: _big(sum.allTimed ? pct(sum.tradedRate) : 'n/a', 'Traded ≤5s')),
                  ]),
                  if (sum.kostIsLowerBound) const Padding(padding: EdgeInsets.only(top: 10), child: Text('Kill times are missing from this source, so KOST is a minimum and trades are shown as "avenged" (a teammate got your killer, at any time). Import the r6-dissect JSON for exact timing.', style: TextStyle(color: AppColors.textDim, fontSize: 11.5, height: 1.4))),
                ]),
              ),
              if (sum.rounds == 0) const Padding(padding: EdgeInsets.only(top: 12), child: Notice('That player is not in any of these rounds.', color: AppColors.textDim)),
              if (sum.rounds > 0) ...[
                const SizedBox(height: 12),
                ScoreHero(report: rep, title: 'Match score', showBreakdown: false),
                const SectionTitle('Round by round', subtitle: 'Tap a round below for its kill feed'),
                AppCard(child: RoundFlow(rounds: flowOf(rep))),
                if (rep.clutch.attempts > 0 || rep.multikills.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  AppCard(
                    child: Wrap(spacing: 8, runSpacing: 8, children: [
                      if (rep.clutch.attempts > 0) Pill('Clutch ${rep.clutch.wins}/${rep.clutch.attempts}', color: AppColors.warn, icon: Icons.bolt),
                      for (final e in (rep.multikills.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))) Pill('${e.value}× ${e.key >= 5 ? 'Ace' : '${e.key}K'}', color: AppColors.good),
                    ]),
                  ),
                ],
              ],
              const SectionTitle('Rounds'),
              for (final m in mine.where((m) => m.present)) _RoundTile(m: m),
              const SectionTitle('Everyone in the match', subtitle: 'Same rules for all players'),
              AppCard(
                child: Column(children: [
                  for (final p in board)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: p.team == 0 ? AppColors.accent : AppColors.attack)),
                        const SizedBox(width: 10),
                        Expanded(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: p.name == who ? FontWeight.w900 : FontWeight.w600, color: p.name == who ? AppColors.accent : AppColors.text))),
                        Text('${p.kills}/${p.deaths}', style: const TextStyle(fontFeatures: tabular, fontWeight: FontWeight.w700)),
                        const SizedBox(width: 12),
                        SizedBox(width: 48, child: Text('${(p.kost * 100).toStringAsFixed(0)}%', textAlign: TextAlign.right, style: const TextStyle(color: AppColors.textDim, fontFeatures: tabular))),
                      ]),
                    ),
                ]),
              ),
            ]),
          );
        },
      );
}

class _RoundTile extends StatelessWidget {
  const _RoundTile({required this.m});
  final MyRound m;

  Widget _k(String l, bool on, String help) => Tooltip(
        message: help,
        child: Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: on ? AppColors.good.withValues(alpha: 0.2) : AppColors.surfaceHi, borderRadius: BorderRadius.circular(6)),
          child: Text(l, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: on ? AppColors.good : AppColors.textDim)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final r = m.round;
    final c = m.won == null ? AppColors.textDim : (m.won! ? AppColors.good : AppColors.bad);
    final name = m.name.toLowerCase();
    final teamOf = {for (final p in r.players) p.name.toLowerCase(): p.team};
    String clockOf(ReplayEvent e) => e.remaining == null ? '' : '${((180 - e.remaining!) ~/ 60)}:${((180 - e.remaining!) % 60).toString().padLeft(2, '0')}';
    final kills = [for (final e in r.events) if (e.isKill) e];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        padding: EdgeInsets.zero,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            title: Row(children: [
              Expanded(
                child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text('Round ${r.number}', style: const TextStyle(fontWeight: FontWeight.w800)),
                  Pill(m.attack ? 'Attack' : 'Defense', color: m.attack ? AppColors.attack : AppColors.defense),
                ]),
              ),
              const SizedBox(width: 8),
              Text(m.won == null ? '' : (m.won! ? 'Won' : 'Lost'), style: TextStyle(color: c, fontWeight: FontWeight.w900)),
            ]),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                _k('K', m.kills > 0, 'Kill'),
                const SizedBox(width: 4),
                _k('O', m.objective, 'Objective play'),
                const SizedBox(width: 4),
                _k('S', m.survived, 'Survived'),
                const SizedBox(width: 4),
                _k('T', m.traded == true, m.traded == null ? 'Traded (needs kill times)' : 'Traded within 5 seconds'),
                const SizedBox(width: 10),
                Expanded(child: Text('${m.kills} kill${m.kills == 1 ? '' : 's'}${m.died ? ' · died' : ''}${m.opening == Opening.kill ? ' · opening kill' : (m.opening == Opening.death ? ' · opening death' : '')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textDim, fontSize: 12))),
              ]),
            ),
            children: [
              if (r.site != null) Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Site: ${r.site}', style: const TextStyle(color: AppColors.textDim, fontSize: 12)))),
              for (var i = 0; i < kills.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    SizedBox(width: 38, child: Text(clockOf(kills[i]).isEmpty ? '#${i + 1}' : clockOf(kills[i]), style: const TextStyle(color: AppColors.textDim, fontSize: 12, fontFeatures: tabular))),
                    Expanded(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(text: kills[i].actor ?? '?', style: TextStyle(fontWeight: FontWeight.w800, color: (kills[i].actor ?? '').toLowerCase() == name ? AppColors.accent : (teamOf[(kills[i].actor ?? '').toLowerCase()] == m.player?.team ? AppColors.text : AppColors.textDim))),
                          const TextSpan(text: '  killed  ', style: TextStyle(color: AppColors.textDim)),
                          TextSpan(text: kills[i].target ?? '?', style: TextStyle(fontWeight: FontWeight.w800, color: (kills[i].target ?? '').toLowerCase() == name ? AppColors.bad : (teamOf[(kills[i].target ?? '').toLowerCase()] == m.player?.team ? AppColors.text : AppColors.textDim))),
                          if (kills[i].headshot) const TextSpan(text: '  headshot', style: TextStyle(color: AppColors.warn, fontSize: 11.5)),
                        ]),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ]),
                ),
              if (kills.isEmpty) const Text('No kills in this round.', style: TextStyle(color: AppColors.textDim)),
            ],
          ),
        ),
      ),
    );
  }
}
