import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/highlight.dart';
import '../common/common.dart';

// Highlight clips: the list (in the Matches tab), the player, and a card for the home screen.

String _size(int bytes) => bytes >= 1 << 30 ? '${(bytes / (1 << 30)).toStringAsFixed(1)} GB' : '${(bytes / (1 << 20)).toStringAsFixed(bytes >= 10 << 20 ? 0 : 1)} MB';
String _secs(double? s) => s == null ? '' : '${s ~/ 60}:${(s.round() % 60).toString().padLeft(2, '0')}';

Color typeColor(Highlight h) => switch (h.type) {
      'ace' => AppColors.warn,
      'clutch' => AppColors.accent2,
      'multikill' => AppColors.good,
      _ => AppColors.accent,
    };

void openClip(BuildContext context, AppState s, Highlight h) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ClipPlayerScreen(state: s, id: h.id)));

/// The clip's picture, or a coloured stand-in when it has none or cannot load (offline).
class ClipThumb extends StatelessWidget {
  const ClipThumb({super.key, required this.state, required this.clip, this.radius = 14});
  final AppState state;
  final Highlight clip;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      decoration: BoxDecoration(gradient: LinearGradient(colors: [typeColor(clip).withValues(alpha: 0.35), AppColors.surfaceHi], begin: Alignment.topLeft, end: Alignment.bottomRight)),
    );   // the play button is drawn on top, so the stand-in itself stays plain
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(fit: StackFit.expand, children: [
          if (clip.thumbnailUrl == null)
            fallback
          else
            Image.network(state.serverUrl(clip.thumbnailUrl!), headers: state.serverHeaders, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback, gaplessPlayback: true),
          Positioned(
            right: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(6)),
              child: Text(_secs(clip.duration), style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
          const Center(child: Icon(Icons.play_circle_fill, size: 44, color: Colors.white70)),
        ]),
      ),
    );
  }
}

class ClipCard extends StatelessWidget {
  const ClipCard({super.key, required this.state, required this.clip});
  final AppState state;
  final Highlight clip;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: '${clip.displayTitle}, round ${clip.round}, ${clip.score} points. Play.',
        excludeSemantics: true,
        child: AppCard(
          padding: const EdgeInsets.all(10),
          onTap: () => openClip(context, state, clip),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipThumb(state: state, clip: clip),
            const SizedBox(height: 10),
            Row(children: [
              Pill(clip.label, color: typeColor(clip), filled: true),
              const SizedBox(width: 6),
              Pill('${clip.score} pts'),
              const Spacer(),
              if (clip.shared) const Icon(Icons.link, size: 18, color: AppColors.textDim),
            ]),
            const SizedBox(height: 6),
            Text(clip.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 2),
            Text(
              [
                'Round ${clip.round}',
                if (clip.operator.isNotEmpty) clip.operator,
                if (clip.playedAt != null) shortDate(clip.playedAt!.toLocal()),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textDim, fontSize: 12.5),
            ),
          ]),
        ),
      );
}

enum ClipSort { best, newest }

/// The Clips page in the Matches tab.
class ClipsSection extends StatefulWidget {
  const ClipsSection({super.key, required this.state});
  final AppState state;

  @override
  State<ClipsSection> createState() => _ClipsSectionState();
}

class _ClipsSectionState extends State<ClipsSection> {
  String _type = 'all';
  ClipSort _sort = ClipSort.best;

  static const _types = {'all': 'All', 'ace': 'Aces', 'clutch': 'Clutches', 'multikill': 'Multi-kills', 'entry': 'Entries', 'headshot': 'Headshots'};

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    if (!s.replayServerConfigured) {
      return EmptyState(
        icon: Icons.movie_creation_outlined,
        title: 'Your clips appear here',
        message: 'Clips are recorded on your PC by the Windows app and sent to your replay server. Connect this phone to the server first.',
        action: FilledButton(onPressed: () => AppNav.maybeOf(context)?.goTab(Tabs.profile), child: const Text('Connect to the server')),
      );
    }
    final all = s.highlights;
    if (all.isEmpty) {
      return EmptyState(
        icon: Icons.movie_creation_outlined,
        title: 'No clips yet',
        message: 'On your PC, tick "Record live clips while I play" in R6 Replay Uploader. '
            'After each round you play, your best moments are cut and show up here a minute or so later.',
        action: OutlinedButton.icon(onPressed: s.replaySyncing ? null : () => s.syncReplayServer(), icon: const Icon(Icons.sync), label: Text(s.replaySyncing ? 'Checking...' : 'Check now')),
      );
    }
    final shown = [for (final h in all) if (_type == 'all' || h.type == _type || h.tags.contains(_type)) h];
    if (_sort == ClipSort.best) {
      shown.sort((a, b) => b.score != a.score ? b.score.compareTo(a.score) : b.seq.compareTo(a.seq));
    }
    final used = s.clipsUsedBytes, quota = s.clipsQuotaBytes;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final e in _types.entries)
            if (e.key == 'all' || all.any((h) => h.type == e.key || h.tags.contains(e.key)))
              Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(e.value), selected: _type == e.key, onSelected: (_) => setState(() => _type = e.key))),
        ]),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: Text('${shown.length} clip${shown.length == 1 ? '' : 's'}', style: const TextStyle(color: AppColors.textDim, fontSize: 12.5))),
        TextButton.icon(
          onPressed: () => setState(() => _sort = _sort == ClipSort.best ? ClipSort.newest : ClipSort.best),
          icon: const Icon(Icons.sort, size: 18),
          label: Text(_sort == ClipSort.best ? 'Best first' : 'Newest first'),
        ),
      ]),
      for (final h in shown) Padding(padding: const EdgeInsets.only(bottom: 12), child: ClipCard(state: s, clip: h)),
      if (used != null && quota != null && quota > 0) ...[
        const SizedBox(height: 4),
        Text('Server storage: ${_size(used)} of ${_size(quota)} used', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
        const SizedBox(height: 6),
        ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: (used / quota).clamp(0.0, 1.0), minHeight: 6, backgroundColor: AppColors.surfaceHi)),
      ],
    ]);
  }
}

/// The best recent clip, for the home screen. Nothing when there are no clips.
class LatestClipCard extends StatelessWidget {
  const LatestClipCard({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final list = state.highlights;
    if (list.isEmpty) return const SizedBox.shrink();
    final h = list.first;
    return AppCard(
      onTap: () => openClip(context, state, h),
      child: Row(children: [
        SizedBox(width: 120, child: ClipThumb(state: state, clip: h, radius: 10)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Your latest clip', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            const SizedBox(height: 2),
            Text(h.displayTitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 4),
            Text('${list.length} clip${list.length == 1 ? '' : 's'} in all', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
          ]),
        ),
        const Icon(Icons.chevron_right, color: AppColors.textDim),
      ]),
    );
  }
}

/// Plays one clip, with what happened in it and what can be done with it.
class ClipPlayerScreen extends StatefulWidget {
  const ClipPlayerScreen({super.key, required this.state, required this.id, this.makeController});
  final AppState state;
  final String id;
  final VideoPlayerController Function(Uri url, Map<String, String> headers)? makeController; // tests swap the player

  @override
  State<ClipPlayerScreen> createState() => _ClipPlayerScreenState();
}

class _ClipPlayerScreenState extends State<ClipPlayerScreen> {
  VideoPlayerController? _c;
  String? _error;
  bool _busy = false;

  Highlight? get _clip {
    for (final h in widget.state.highlights) {
      if (h.id == widget.id) return h;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final h = _clip;
    if (h == null) return;
    final url = Uri.parse(widget.state.serverUrl(h.videoUrl));
    final c = (widget.makeController ?? (u, hd) => VideoPlayerController.networkUrl(u, httpHeaders: hd))(url, widget.state.serverHeaders);
    _c = c;
    c.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      c.play();
    }).catchError((Object _) {
      if (mounted) setState(() => _error = 'The clip could not be played. Check your connection and try again.');
    });
    c.addListener(_tick);
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c?.removeListener(_tick);
    _c?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _run(Future<String?> Function() f, String done) async {
    setState(() => _busy = true);
    final err = await f();
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(err ?? done);
  }

  Future<void> _rename(Highlight h) async {
    final ctl = TextEditingController(text: h.title ?? '');
    final title = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Name this clip'),
        content: TextField(controller: ctl, autofocus: true, maxLength: 80, decoration: InputDecoration(hintText: '${h.label} on ${h.map}')),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Save'))],
      ),
    );
    if (title != null) await _run(() => widget.state.renameHighlight(h.id, title), 'Saved.');
  }

  Future<void> _share(Highlight h) async {
    setState(() => _busy = true);
    final r = await widget.state.shareHighlight(h.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.url == null) return _snack(r.error!);
    await Clipboard.setData(ClipboardData(text: r.url!));
    if (!mounted) return;
    showInfo(context, 'Link copied', 'Anyone with this link can watch the clip for 7 days, without the app. Paste it into a chat.\n\nTo stop it working, make the clip private again.');
  }

  Future<void> _delete(Highlight h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this clip?'),
        content: const Text('It is removed from the server for good, and share links stop working. The recording on your PC is not touched.'),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')), FilledButton(style: FilledButton.styleFrom(backgroundColor: AppColors.bad), onPressed: () => Navigator.pop(c, true), child: const Text('Delete'))],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final err = await widget.state.deleteHighlight(h.id);
    if (!mounted) return;
    if (err != null) {
      setState(() => _busy = false);
      return _snack(err);
    }
    Navigator.of(context).pop();
  }

  void _fullscreen() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => Scaffold(backgroundColor: Colors.black, body: SafeArea(child: _video(c, fullscreen: true)))))
        .then((_) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    });
  }

  Widget _video(VideoPlayerController c, {bool fullscreen = false}) {
    final v = c.value;
    return GestureDetector(
      onTap: () => v.isPlaying ? c.pause() : c.play(),
      child: Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: Stack(alignment: Alignment.bottomCenter, children: [
          Center(child: AspectRatio(aspectRatio: v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio, child: VideoPlayer(c))),
          if (!v.isPlaying) const Center(child: Icon(Icons.play_circle_fill, size: 64, color: Colors.white70)),
          Container(
            padding: const EdgeInsets.fromLTRB(8, 0, 4, 4),
            decoration: const BoxDecoration(gradient: LinearGradient(colors: [Colors.transparent, Colors.black54], begin: Alignment.topCenter, end: Alignment.bottomCenter)),
            child: Row(children: [
              Text(_secs(v.position.inMilliseconds / 1000), style: const TextStyle(color: Colors.white, fontSize: 12)),
              const SizedBox(width: 8),
              Expanded(child: VideoProgressIndicator(c, allowScrubbing: true, padding: const EdgeInsets.symmetric(vertical: 12), colors: const VideoProgressColors(playedColor: AppColors.accent))),
              const SizedBox(width: 8),
              Text(_secs(v.duration.inMilliseconds / 1000), style: const TextStyle(color: Colors.white, fontSize: 12)),
              IconButton(
                tooltip: fullscreen ? 'Exit full screen' : 'Full screen',
                onPressed: fullscreen ? () => Navigator.of(context).pop() : _fullscreen,
                icon: Icon(fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final h = _clip;
          if (h == null) {
            return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.movie_outlined, title: 'Clip not found', message: 'It may have been deleted.'));
          }
          final c = _c;
          return Scaffold(
            appBar: AppBar(title: Text(h.displayTitle, overflow: TextOverflow.ellipsis), backgroundColor: AppColors.bg, surfaceTintColor: Colors.transparent),
            body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: _error != null
                    ? Container(color: Colors.black, alignment: Alignment.center, padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)))
                    : (c != null && c.value.isInitialized)
                        ? _video(c)
                        : Stack(fit: StackFit.expand, children: [ClipThumb(state: widget.state, clip: h, radius: 0), const Center(child: CircularProgressIndicator())]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    Pill(h.label, color: typeColor(h), filled: true),
                    Pill('${h.score} points'),
                    Pill(h.won ? 'Round won' : 'Round lost', color: h.won ? AppColors.good : AppColors.bad),
                    if (h.shared) const Pill('Link on', icon: Icons.link, color: AppColors.accent2),
                  ]),
                  const SizedBox(height: 10),
                  Text(h.displayTitle, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 4),
                  Text(
                    [
                      h.map,
                      'Round ${h.round}',
                      if (h.side.isNotEmpty) h.side,
                      if (h.operator.isNotEmpty) h.operator,
                      if (h.playedAt != null) dayLabel(h.playedAt!.toLocal()),
                    ].join(' · '),
                    style: const TextStyle(color: AppColors.textDim, height: 1.35),
                  ),
                  const SizedBox(height: 14),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton.icon(onPressed: _busy ? null : () => _share(h), icon: const Icon(Icons.link), label: const Text('Copy share link')),
                    OutlinedButton.icon(onPressed: _busy ? null : () => _rename(h), icon: const Icon(Icons.edit_outlined), label: const Text('Rename')),
                    if (h.shared)
                      OutlinedButton.icon(onPressed: _busy ? null : () => _run(() => widget.state.setHighlightPrivate(h.id), 'Private again: old links no longer work.'), icon: const Icon(Icons.link_off), label: const Text('Make private')),
                    TextButton.icon(onPressed: _busy ? null : () => _delete(h), icon: const Icon(Icons.delete_outline, color: AppColors.bad), label: const Text('Delete', style: TextStyle(color: AppColors.bad))),
                  ]),
                  const SectionTitle('What happened'),
                  AppCard(
                    child: Column(children: [
                      for (final k in h.kills)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(children: [
                            SizedBox(width: 44, child: Text(_secs(k.t), style: const TextStyle(color: AppColors.textDim, fontFeatures: tabular))),
                            Icon(k.headshot ? Icons.gps_fixed : Icons.close, size: 16, color: k.headshot ? AppColors.warn : AppColors.textDim),
                            const SizedBox(width: 8),
                            Expanded(child: Text('${k.victim}${k.victimOperator != null && !k.victimOperator!.startsWith('Operator(') ? ' (${k.victimOperator})' : ''}', overflow: TextOverflow.ellipsis)),
                            if (k.headshot) const Text('headshot', style: TextStyle(color: AppColors.warn, fontSize: 12)),
                          ]),
                        ),
                      if (h.approx)
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text('Kills after the plant are timed by the defuser clock, so this clip may start a little early or late.', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
                        ),
                    ]),
                  ),
                  Padding(padding: const EdgeInsets.only(top: 10), child: Text('Times are from the moment the round timer started. ${_size(h.size)}.', style: const TextStyle(color: AppColors.textDim, fontSize: 12))),
                ]),
              ),
            ]),
          );
        },
      );
}
