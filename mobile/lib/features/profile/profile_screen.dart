import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../analytics/scoring.dart';
import '../../app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../common/guide.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.state});
  final AppState state;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final _key = TextEditingController(text: widget.state.apiKey);
  late final _name = TextEditingController(text: widget.state.username);
  late final _srvUrl = TextEditingController(text: widget.state.replayServerUrl);
  late final _srvTok = TextEditingController(text: widget.state.replayServerToken);
  bool _srvHide = true, _srvBusy = false;
  String? _srvMsg;
  bool _srvOk = false;
  late String _platform = widget.state.platform;
  bool _hide = true;
  String? _usage;

  @override
  void dispose() {
    _key.dispose();
    _name.dispose();
    _srvUrl.dispose();
    _srvTok.dispose();
    super.dispose();
  }

  Future<void> _saveServer() async {
    setState(() {
      _srvBusy = true;
      _srvMsg = null;
    });
    await widget.state.saveReplayServer(_srvUrl.text, _srvTok.text);
    final c = await widget.state.testReplayServer();
    if (!mounted) return;
    setState(() {
      _srvBusy = false;
      _srvOk = c.ok;
      _srvMsg = c.message;
      _srvUrl.text = widget.state.replayServerUrl;
    });
  }

  Future<void> _checkUsage() async {
    try {
      final u = await widget.state.serverUsage();
      setState(
        () => _usage =
            '${u['usage']?['total_calls'] ?? '?'} of ${u['limit']} used · resets ${(u['reset_at'] as String?)?.substring(0, 10) ?? '?'}',
      );
    } on Object catch (e) {
      setState(() => _usage = e.toString());
    }
  }

  String get _confirmedName => widget.state.detected?.name ?? '';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) {
      final s = widget.state;
      final p = s.profile;
      final used = s.callsThisMonth;
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 8, 4, 12),
            child: Text(
              'Profile',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
            ),
          ),
          if (!nextStepFor(s).complete) ...[NextStepCard(step: nextStepFor(s), onAction: (id) => runStep(context, s, id)), const SizedBox(height: 4)],
          if (p != null)
            AppCard(
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: AppColors.surfaceHi,
                    backgroundImage: p.avatarUrl == null
                        ? null
                        : NetworkImage(p.avatarUrl!),
                    onBackgroundImageError: p.avatarUrl == null
                        ? null
                        : (_, _) {},
                    child: p.avatarUrl == null
                        ? const Icon(Icons.person)
                        : null,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.name,
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          'Level ${p.level ?? '—'} · ${p.platform}',
                          style: const TextStyle(color: AppColors.textDim),
                        ),
                        const SizedBox(height: 6),
                        Pill(
                          p.banned ? 'Account banned' : 'No bans on record',
                          color: p.banned ? AppColors.bad : AppColors.good,
                          icon: p.banned
                              ? Icons.block
                              : Icons.verified_user_outlined,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SectionTitle('Connect your PC', subtitle: 'Step 1: this is how your matches get here'),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('The R6 Replay Uploader on your gaming PC sends each replay to your replay server. This phone collects the small analysed data from it. Enter the same server address here.', style: TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.4)),
              const SizedBox(height: 12),
              TextField(controller: _srvUrl, keyboardType: TextInputType.url, autocorrect: false, decoration: const InputDecoration(labelText: 'Server address', hintText: 'https://…', prefixIcon: Icon(Icons.dns_outlined))),
              const SizedBox(height: 10),
              TextField(
                controller: _srvTok,
                obscureText: _srvHide,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Read token',
                  helperText: 'The phone uses the read token. The PC uses a different, upload-only token.',
                  helperMaxLines: 2,
                  prefixIcon: const Icon(Icons.vpn_key_outlined),
                  suffixIcon: IconButton(icon: Icon(_srvHide ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _srvHide = !_srvHide)),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _srvBusy ? null : _saveServer,
                icon: _srvBusy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_done_outlined),
                label: Text(_srvBusy ? 'Testing…' : 'Save and test'),
              ),
              if (_srvMsg != null) ...[const SizedBox(height: 10), Notice(_srvMsg!, color: _srvOk ? AppColors.good : AppColors.bad, icon: _srvOk ? Icons.check_circle_outline : Icons.error_outline)],
              if (s.lastReplaySync != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Last synced ${ago(s.lastReplaySync)}', style: const TextStyle(color: AppColors.textDim, fontSize: 12))),
            ]),
          ),
          const SectionTitle('Your account', subtitle: 'How the coach finds you in your replays'),
          if (s.detected != null && _name.text.trim().toLowerCase() != s.detected!.name.toLowerCase()) ...[
            Notice(
              s.username.isEmpty ? 'Your replays say you are ${s.detected!.name}. Save it to keep it.' : (s.nameFromReplays ? 'Using ${s.detected!.name}, found in your replays, because ${s.username} is not in them.' : 'Your replays were recorded by ${s.detected!.name}.'),
              color: AppColors.accent,
              icon: Icons.auto_awesome_outlined,
              action: TextButton(onPressed: () { setState(() => _name.text = s.detected!.name); s.saveSettings(key: _key.text, name: s.detected!.name, plat: _platform); }, child: const Text('Use it')),
            ),
            const SizedBox(height: 12),
          ] else if (s.detected != null && s.username.isNotEmpty) ...[
            Notice('Confirmed: your replays were recorded by $_confirmedName.', color: AppColors.good, icon: Icons.verified_outlined),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _name,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Username',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _platform,
            decoration: const InputDecoration(
              labelText: 'Platform',
              prefixIcon: Icon(Icons.sports_esports_outlined),
            ),
            items: const [
              DropdownMenuItem(
                value: 'uplay',
                child: Text('Ubisoft Connect (PC)', overflow: TextOverflow.ellipsis),
              ),
              DropdownMenuItem(value: 'psn', child: Text('PlayStation')),
              DropdownMenuItem(value: 'xbl', child: Text('Xbox')),
            ],
            onChanged: (v) => setState(() => _platform = v ?? 'uplay'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: s.loading
                ? null
                : () => s.saveSettings(
                    key: _key.text,
                    name: _name.text,
                    plat: _platform,
                  ),
            icon: s.loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            label: Text(s.loading ? 'Saving…' : 'Save'),
          ),
          if (s.error != null) ...[
            const SizedBox(height: 12),
            Notice(s.error!, color: AppColors.bad, icon: Icons.error_outline),
          ],
          const SectionTitle('Lifetime stats (optional)', subtitle: 'Not needed for your coach'),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Adds your all-time rank and stats on the Home and Stats tabs. They come from a free third-party service (Arenyze) that gives out its own key, which is why this is optional. Skip it and everything about your replays still works.', style: TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.4)),
              const SizedBox(height: 12),
              TextField(
            controller: _key,
            obscureText: _hide,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Stats key',
              helperText: 'Stored on this device only.',
              helperMaxLines: 2,
              prefixIcon: const Icon(Icons.key_rounded),
              suffixIcon: IconButton(
                icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _hide = !_hide),
              ),
            ),
          ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: s.loading ? null : () => s.saveSettings(key: _key.text, name: _name.text, plat: _platform),
                icon: const Icon(Icons.key_rounded, size: 18),
                label: Text(s.hasStatsKey ? 'Update key' : 'Turn on lifetime stats'),
              ),
            ]),
          ),
          const SectionTitle(
            'API budget',
            subtitle:
                'The free plan allows ${AppState.monthlyQuota} calls a month',
          ),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '$used',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Flexible(
                      child: Text(
                        ' / ${AppState.monthlyQuota} used on this device',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.textDim),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: used / AppState.monthlyQuota,
                    minHeight: 8,
                    backgroundColor: AppColors.surfaceHi,
                    valueColor: AlwaysStoppedAnimation(
                      used > 1500 ? AppColors.warn : AppColors.accent,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'A refresh costs 2 calls and the app only auto-refreshes when data is over 30 minutes old. Operator roles, icons and counters are bundled and cost nothing.',
                  style: TextStyle(
                    color: AppColors.textDim,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: s.configured ? _checkUsage : null,
                    icon: const Icon(Icons.speed, size: 18),
                    label: const Text('Check server count (1 call)'),
                  ),
                ),
                if (_usage != null)
                  Text(
                    _usage!,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
              ],
            ),
          ),
          const SectionTitle('Saved history'),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${s.snapshots.length} snapshots · ${s.matchLog.length} logged matches · ${s.goals.length} goals',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Snapshots power your match log and goal progress. They stay on this device.',
                  style: TextStyle(color: AppColors.textDim, fontSize: 12.5),
                ),
                const SizedBox(height: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: s.snapshots.length < 2 && s.goals.isEmpty
                        ? null
                        : () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: const Text('Clear saved history?'),
                                content: const Text(
                                  'Your match log and goals will be removed from this device. Your stats stay.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c, false),
                                    child: const Text('Cancel'),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(c, true),
                                    child: const Text('Clear'),
                                  ),
                                ],
                              ),
                            );
                            if (ok == true) await s.clearHistory();
                          },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Clear match log and goals'),
                  ),
                ),
              ],
            ),
          ),
          const SectionTitle('Backup', subtitle: 'Match log, notes, goals and RP history live only on this device'),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Copy a backup before reinstalling or switching phones, and paste it back later. It contains no API key.', style: TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.4)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: s.exportBackup()));
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Backup copied. Paste it into a note to keep it.')));
                  },
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  label: const Text('Copy backup'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final data = await Clipboard.getData('text/plain');
                    final err = await s.importBackup(data?.text ?? '');
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Backup restored.')));
                  },
                  icon: const Icon(Icons.restore, size: 18),
                  label: const Text('Restore from clipboard'),
                ),
              ]),
            ]),
          ),
          const SectionTitle('About'),
          const AppCard(
            child: Text(
              'Scoring model $scoringVersion. Reference values are assumptions, not measurements.\n\n'
              'Data: Arenyze (R6Data) API. Operator counters: github.com/BurkusCat/r6-operator-counters (MIT). Not affiliated with Ubisoft.',
              style: TextStyle(
                color: AppColors.textDim,
                height: 1.45,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      );
    },
  );
}
