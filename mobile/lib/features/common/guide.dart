import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../analytics/next_step.dart';
import '../../analytics/replay_stats.dart';
import '../../app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../replays/replay_ui.dart';
import 'common.dart';

/// The step the user is on, worked out from what the app knows.
NextStep nextStepFor(AppState s) {
  final rounds = s.replays.length;
  return nextStep(hasAccount: s.hasAccount, serverConfigured: s.replayServerConfigured, rounds: rounds, playerFound: rounds == 0 || analyzedRounds(s) > 0);
}

/// Rounds the player actually appears in; the coach needs at least a few.
int analyzedRounds(AppState s) {
  final me = replayPlayerName(s);
  return s.replays.where((r) => analyzeRound(r, me).present).length;
}

/// What pressing the big button on the next-step card does.
Future<void> runStep(BuildContext context, AppState s, StepId id) async {
  final nav = AppNav.maybeOf(context);
  switch (id) {
    case StepId.account || StepId.connectPc || StepId.pickYourself:
      nav?.goTab(Tabs.profile);
    case StepId.waiting:
      final r = await s.syncReplayServer();
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.summary)));
    case StepId.coach:
      nav?.goTab(Tabs.coach);
  }
}

/// "Your next step": one clear thing to do, with the progress that led here, so nobody wonders what to press.
class NextStepCard extends StatelessWidget {
  const NextStepCard({super.key, required this.step, required this.onAction, this.onSecondary});
  final NextStep step;
  final ValueChanged<StepId> onAction;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final firstOpen = step.items.indexWhere((i) => !i.done);
    return AppCard(
      tint: AppColors.accent,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.flag_outlined, size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          const Expanded(child: Text('Your next step', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w800, fontSize: 12.5, letterSpacing: 0.4))),
          Pill('${step.doneCount} of ${step.items.length} done', color: step.complete ? AppColors.good : AppColors.textDim),
        ]),
        const SizedBox(height: 10),
        Text(step.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, height: 1.2)),
        const SizedBox(height: 6),
        Text(step.message, style: const TextStyle(color: AppColors.textDim, fontSize: 13.5, height: 1.4)),
        const SizedBox(height: 14),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () {
            HapticFeedback.selectionClick();
            onAction(step.id);
          },
          child: Text(step.action),
        ),
        if (step.secondary != null && onSecondary != null)
          Align(alignment: Alignment.center, child: TextButton(onPressed: onSecondary, child: Text(step.secondary!))),
        const SizedBox(height: 10),
        Wrap(spacing: 14, runSpacing: 6, children: [
          for (var i = 0; i < step.items.length; i++)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(step.items[i].done ? Icons.check_circle : (i == firstOpen ? Icons.radio_button_checked : Icons.radio_button_unchecked), size: 16, color: step.items[i].done ? AppColors.good : (i == firstOpen ? AppColors.accent : AppColors.textDim)),
              const SizedBox(width: 5),
              Text(step.items[i].label, style: TextStyle(fontSize: 12, color: step.items[i].done ? AppColors.text : AppColors.textDim, fontWeight: i == firstOpen ? FontWeight.w700 : FontWeight.w500)),
            ]),
        ]),
      ]),
    );
  }
}

/// First run: three short steps, no keys, no other websites.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.state});
  final AppState state;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _token = TextEditingController();
  String _platform = 'uplay';
  bool _busy = false;
  String? _result;
  bool _resultOk = false;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    setState(() => _busy = true);
    await widget.state.saveSettings(key: widget.state.apiKey, name: _name.text, plat: _platform);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _step = 2;
    });
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    await widget.state.saveReplayServer(_url.text, _token.text);
    final r = await widget.state.syncReplayServer();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _resultOk = !r.summary.toLowerCase().contains('could not') && !r.summary.toLowerCase().contains('rejected') && !r.summary.toLowerCase().contains('failed');
      _result = r.summary;
    });
    if (_resultOk) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) await widget.state.finishOnboarding();
    }
  }

  Widget _dots() => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < 3; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == _step ? 26 : 8,
            height: 8,
            decoration: BoxDecoration(color: i <= _step ? AppColors.accent : AppColors.outline, borderRadius: BorderRadius.circular(4)),
          ),
      ]);

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 0),
              child: Row(children: [
                Expanded(child: Semantics(label: 'Step ${_step + 1} of 3', child: _dots())),
                if (_step > 0) TextButton(onPressed: () => widget.state.finishOnboarding(), child: const Text('Skip')),
                if (_step == 0) const SizedBox(width: 48),
              ]),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: KeyedSubtree(key: ValueKey(_step), child: switch (_step) { 0 => _welcome(), 1 => _who(), _ => _connectPc() }),
              ),
            ),
          ]),
        ),
      );

  Widget _page(List<Widget> children, {required Widget footer}) => Column(children: [
        Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(24, 20, 24, 12), children: children)),
        Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 20), child: footer),
      ]);

  Widget _bullet(IconData icon, String title, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 40, height: 40, decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: AppColors.accent, size: 22)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 2),
              Text(text, style: const TextStyle(color: AppColors.textDim, fontSize: 13.5, height: 1.4)),
            ]),
          ),
        ]),
      );

  Widget _welcome() => _page([
        const SizedBox(height: 12),
        const Icon(Icons.school_outlined, size: 56, color: AppColors.accent),
        const SizedBox(height: 16),
        const Text('Welcome to R6 Coach', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, height: 1.15)),
        const SizedBox(height: 8),
        const Text('A coach that learns from your own matches.', style: TextStyle(color: AppColors.textDim, fontSize: 15, height: 1.4)),
        const SizedBox(height: 18),
        _bullet(Icons.speed, 'A score for every match', 'See how you played compared with your own usual level.'),
        _bullet(Icons.checklist, 'What to work on', 'Plain advice and a plan for your next session.'),
        _bullet(Icons.lock_outline, 'Nothing to sign up for', 'It uses your own replay files. No accounts or keys on other websites.'),
      ], footer: FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)), onPressed: () => setState(() => _step = 1), child: const Text('Get started')));

  Widget _who() => _page([
        const Text('Who are you in the game?', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, height: 1.15)),
        const SizedBox(height: 8),
        const Text('The coach uses your name to find you in each replay. Not sure, or do not want to type it? Skip: it is read from your replays the moment the first ones arrive.', style: TextStyle(color: AppColors.textDim, fontSize: 14.5, height: 1.4)),
        const SizedBox(height: 22),
        TextField(
          controller: _name,
          autocorrect: false,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Your Ubisoft name', helperText: 'Exactly as it shows in the game', prefixIcon: Icon(Icons.person_outline)),
        ),
        const SizedBox(height: 26),
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: _platform,
          decoration: const InputDecoration(labelText: 'Where do you play?', prefixIcon: Icon(Icons.sports_esports_outlined)),
          items: const [
            DropdownMenuItem(value: 'uplay', child: Text('PC (Ubisoft Connect)', overflow: TextOverflow.ellipsis)),
            DropdownMenuItem(value: 'psn', child: Text('PlayStation')),
            DropdownMenuItem(value: 'xbl', child: Text('Xbox')),
          ],
          onChanged: (v) => setState(() => _platform = v ?? 'uplay'),
        ),
      ], footer: Column(mainAxisSize: MainAxisSize.min, children: [
        FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)), onPressed: _name.text.trim().isEmpty || _busy ? null : _saveName, child: Text(_busy ? 'Saving…' : 'Continue')),
        TextButton(onPressed: () => setState(() => _step = 2), child: const Text('Skip: find me from my replays')),
      ]));

  Widget _connectPc() => _page([
        const Text('Connect your PC', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, height: 1.15)),
        const SizedBox(height: 8),
        const Text('Siege saves a replay file for every round. The R6 Replay Uploader on your gaming PC sends them to your replay server, and this app collects them from there.', style: TextStyle(color: AppColors.textDim, fontSize: 14.5, height: 1.4)),
        const SizedBox(height: 16),
        _bullet(Icons.looks_one_outlined, 'Install the uploader on your PC', 'Enter the server address and the upload token in it.'),
        _bullet(Icons.looks_two_outlined, 'Enter the same server here', 'Use the address and the read token you were given for your phone.'),
        const SizedBox(height: 6),
        TextField(controller: _url, keyboardType: TextInputType.url, autocorrect: false, decoration: const InputDecoration(labelText: 'Server address', hintText: 'https://…', prefixIcon: Icon(Icons.dns_outlined))),
        const SizedBox(height: 12),
        TextField(controller: _token, autocorrect: false, enableSuggestions: false, obscureText: true, decoration: const InputDecoration(labelText: 'Phone token (read token)', prefixIcon: Icon(Icons.key_rounded))),
        if (_result != null) ...[
          const SizedBox(height: 14),
          Notice(_result!, color: _resultOk ? AppColors.good : AppColors.bad, icon: _resultOk ? Icons.check_circle_outline : Icons.error_outline),
        ],
      ], footer: Column(mainAxisSize: MainAxisSize.min, children: [
        FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)), onPressed: _busy ? null : _connect, child: Text(_busy ? 'Connecting…' : 'Connect')),
        TextButton(onPressed: () => widget.state.finishOnboarding(), child: const Text("I'll do this later")),
      ]));
}
