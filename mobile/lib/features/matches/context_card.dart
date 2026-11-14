import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/match_notes.dart';
import '../../data/snapshots.dart';

/// Lets the player add what the API cannot know about a match: map, party size, mood and a note.
class ContextCard extends StatefulWidget {
  const ContextCard({super.key, required this.record, required this.state});
  final MatchRecord record;
  final AppState state;

  @override
  State<ContextCard> createState() => _ContextCardState();
}

class _ContextCardState extends State<ContextCard> {
  late final _text = TextEditingController(text: widget.state.noteFor(widget.record)?.text ?? '');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  MatchNote get _note => widget.state.noteFor(widget.record) ?? const MatchNote();
  void _save(MatchNote n) => widget.state.saveNote(widget.record, n);

  Future<void> _pickMap() async {
    HapticFeedback.selectionClick();
    final picked = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _MapPicker(maps: widget.state.maps, current: _note.map),
    );
    if (picked != null) _save(_note.copyWith(map: picked.isEmpty ? null : picked));
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.record.exact) {
      return const Notice('Map, party and notes can be added to exact single matches. This entry covers several.', color: AppColors.textDim);
    }
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final n = _note;
        return AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('The API does not know your map or team. Add it here and your Maps view fills in.', style: TextStyle(color: AppColors.textDim, fontSize: 12.5, height: 1.4)),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: widget.state.maps.isEmpty ? null : _pickMap,
              icon: const Icon(Icons.map_outlined, size: 18),
              label: Text(n.map ?? 'Choose map'),
            ),
            const SizedBox(height: 14),
            const Text('Who you played with', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in partySizes) ChoiceChip(label: Text(partyLabel(p)), selected: n.party == p, onSelected: (sel) => _save(n.copyWith(party: sel ? p : null))),
            ]),
            const SizedBox(height: 14),
            const Text('How did you feel?', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 8),
            Row(children: [
              for (var i = 1; i <= 5; i++) ...[
                if (i > 1) const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: n.feeling == i,
                    label: 'Feeling $i of 5',
                    child: InkWell(
                      onTap: () => _save(n.copyWith(feeling: n.feeling == i ? null : i)),
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        height: 44,
                        decoration: BoxDecoration(
                          color: n.feeling == i ? AppColors.accent.withValues(alpha: 0.2) : AppColors.surfaceHi,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          const [Icons.sentiment_very_dissatisfied, Icons.sentiment_dissatisfied, Icons.sentiment_neutral, Icons.sentiment_satisfied, Icons.sentiment_very_satisfied][i - 1],
                          color: n.feeling == i ? AppColors.accent : AppColors.textDim,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ]),
            const SizedBox(height: 14),
            TextField(
              controller: _text,
              maxLines: 3,
              minLines: 1,
              maxLength: 280,
              onChanged: (v) => _save(n.copyWith(text: v.isEmpty ? null : v)),
              decoration: const InputDecoration(labelText: 'Note (what went wrong or right?)', alignLabelWithHint: true),
            ),
          ]),
        );
      },
    );
  }
}

class _MapPicker extends StatefulWidget {
  const _MapPicker({required this.maps, required this.current});
  final List<GameMap> maps;
  final String? current;

  @override
  State<_MapPicker> createState() => _MapPickerState();
}

class _MapPickerState extends State<_MapPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final list = widget.maps.where((m) => m.name.toLowerCase().contains(_q.toLowerCase())).toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: TextField(autofocus: false, onChanged: (v) => setState(() => _q = v), decoration: const InputDecoration(hintText: 'Search maps', prefixIcon: Icon(Icons.search))),
          ),
          Expanded(
            child: ListView(children: [
              if (widget.current != null) ListTile(leading: const Icon(Icons.close), title: const Text('Clear map'), onTap: () => Navigator.pop(context, '')),
              for (final m in list)
                ListTile(
                  title: Text(m.name),
                  subtitle: Text('${m.location}${m.ranked ? '' : ' · not in Ranked'}', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                  trailing: m.name == widget.current ? const Icon(Icons.check, color: AppColors.accent) : null,
                  onTap: () => Navigator.pop(context, m.name),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
