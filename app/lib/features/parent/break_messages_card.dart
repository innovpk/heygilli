import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

/// What Gilli says to one child when the video stops (PROTOCOL "Time limits
/// and break periods"), saved with `PUT /kids/{id}/break-messages`.
///
/// This card is the whole of HeyGilli's answer to "what should happen during
/// a break". The app has no view on it. A parent types sentences; Gilli reads
/// them out and does nothing else. Three things follow from that and are
/// enforced here rather than described in a prompt:
///
///  - **Nothing is suggested into a child's ear.** "Ask Gilli for ideas"
///    fills the boxes with drafts the parent can edit or throw away. Only the
///    save button puts a word in front of a child.
///  - **Empty is a real answer.** A parent who wants a plain, silent pause
///    saves nothing, and Gilli says only that it is break time.
///  - **Nothing here is enforcement.** Gilli cannot check that anyone stood
///    up, so the copy never claims it will. Whether the break holds is the
///    firm/soft setting on the limits card, and that is the parent's too.
class BreakMessagesCard extends StatefulWidget {
  const BreakMessagesCard({super.key, required this.kid});

  final Kid kid;

  @override
  State<BreakMessagesCard> createState() => _BreakMessagesCardState();
}

class _BreakMessagesCardState extends State<BreakMessagesCard> {
  /// One controller per line, so a parent can edit any of them in place.
  late List<TextEditingController> _lines = _controllersFor(
    widget.kid.breakMessages,
  );

  /// The ids of the saved lines, kept alongside so an edit updates a line
  /// rather than replacing it with a new one.
  late List<String> _ids = [for (final m in widget.kid.breakMessages) m.id];

  late List<String> _saved = _texts;

  bool _saving = false;
  bool _asking = false;
  String? _error;

  static List<TextEditingController> _controllersFor(
    List<BreakMessage> messages,
  ) => [for (final m in messages) TextEditingController(text: m.text)];

  List<String> get _texts => [
    for (final c in _lines) c.text.trim(),
  ].where((t) => t.isNotEmpty).toList();

  bool get _dirty => !_sameAs(_saved, _texts);

  static bool _sameAs(List<String> a, List<String> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => a[i] == b[i]).every((x) => x);

  @override
  void dispose() {
    for (final c in _lines) {
      c.dispose();
    }
    super.dispose();
  }

  void _add([String text = '']) => setState(() {
    _lines.add(TextEditingController(text: text));
    _ids.add('');
  });

  void _removeAt(int i) => setState(() {
    _lines.removeAt(i).dispose();
    if (i < _ids.length) _ids.removeAt(i);
  });

  /// Drafts, into the boxes, for the parent to read. This does not save, and
  /// it never touches lines the parent already wrote.
  Future<void> _askGilli() async {
    setState(() {
      _asking = true;
      _error = null;
    });
    try {
      final drafts = await context
          .read<AppState>()
          .gateway
          .suggestBreakMessages(widget.kid.id);
      if (!mounted) return;
      setState(() {
        for (final d in drafts) {
          _lines.add(TextEditingController(text: d.text));
          _ids.add('');
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not get ideas: $e');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Blank boxes are dropped rather than saved as empty lines: a break
      // where Gilli says nothing at all is what saving none of them means.
      final messages = <BreakMessage>[];
      for (var i = 0; i < _lines.length; i++) {
        final text = _lines[i].text.trim();
        if (text.isEmpty) continue;
        messages.add(
          BreakMessage(id: i < _ids.length ? _ids[i] : '', text: text),
        );
      }
      final state = context.read<AppState>();
      final updated = await state.gateway.saveBreakMessages(
        widget.kid.id,
        messages,
      );
      await state.refreshKids();
      if (!mounted) return;
      setState(() {
        for (final c in _lines) {
          c.dispose();
        }
        _lines = _controllersFor(updated.breakMessages);
        _ids = [for (final m in updated.breakMessages) m.id];
        _saved = _texts;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.kid.nickname;
    final preReader = widget.kid.band == AgeBand.b4to6;
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'What Gilli says at break time',
            style: HgText.display(size: 22, color: HgColors.ink),
          ),
          const SizedBox(height: 4),
          Text(
            preReader
                ? 'Gilli reads one of these out loud when the video stops. '
                      '$name is too young to read, so they hear it and see '
                      'nothing.'
                : 'Gilli reads one of these out when the video stops, and '
                      'shows it on screen. A different one each time.',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < _lines.length; i++)
            _MessageRow(
              controller: _lines[i],
              hint: _hints[i % _hints.length],
              onChanged: () => setState(() {}),
              onRemove: () => _removeAt(i),
            ),
          if (_lines.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: HgColors.cream,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                // Not an error state. Some households want the video to stop
                // and nothing more, and that is a setting, not a gap.
                'Nothing yet. Breaks will be quiet: Gilli stops the video and '
                'says only that it is break time.',
                style: HgText.body(size: 14, color: HgColors.brown),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            spacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: () => _add(),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: Text(
                  'Add a line',
                  style: HgText.body(size: 15, color: HgColors.ink),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _asking ? null : _askGilli,
                icon: _asking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_rounded, size: 20),
                label: Text(
                  'Ideas',
                  style: HgText.body(size: 15, color: HgColors.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            // Says plainly where the boundary is, because a parent should not
            // have to guess whether the model can reach their child.
            'Ideas are only put in the boxes above. Nothing reaches $name '
            'until you save it, and you can change every word first.',
            style: HgText.body(size: 13, color: HgColors.muted),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: HgText.body(size: 14, color: HgColors.coral)),
          ],
          const SizedBox(height: 12),
          SizedBox(
            height: 52,
            width: double.infinity,
            child: FilledButton(
              onPressed: _dirty && !_saving ? _save : null,
              style: FilledButton.styleFrom(
                disabledBackgroundColor: HgColors.line,
                disabledForegroundColor: HgColors.brown,
              ),
              child: _saving
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: HgColors.ink,
                      ),
                    )
                  : Text(
                      _dirty ? 'Save what Gilli says' : 'Saved',
                      style: HgText.body(
                        size: 16,
                        color: _dirty ? HgColors.ink : HgColors.brown,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// Examples in the empty boxes, in a parent's own voice rather than a
  /// product's. They are hints, never prefilled text.
  static const _hints = [
    'Break time. Come and drink some water.',
    'Time to stretch. Ammi is in the kitchen.',
    'Go and tell someone one thing you just learned.',
    'Break time. Go and find three blue things.',
  ];
}

/// One line, with a way to delete it.
class _MessageRow extends StatelessWidget {
  const _MessageRow({
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.onRemove,
  });

  final TextEditingController controller;
  final String hint;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: (_) => onChanged(),
              maxLines: null,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              style: HgText.body(size: 15, color: HgColors.ink),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: HgText.body(size: 15, color: HgColors.muted),
                filled: true,
                fillColor: HgColors.cream,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close_rounded),
            color: HgColors.brown,
            tooltip: 'Remove this line',
          ),
        ],
      ),
    );
  }
}
