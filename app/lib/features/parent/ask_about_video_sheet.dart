import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';

/// Asking about one video, and being answered.
///
/// The screening writes a few sentences and then the parent decides. That is
/// enough when their question happens to be the one it answered, and no use at
/// all when it is not — "is the dog hurt in it?", "does it sell them something
/// at the end?", "why is this one being kept from her?".
///
/// Nothing here decides anything. The switch the parent came from is still
/// where they left it, and still theirs; this only tells them what is in the
/// video. The conversation lives in this widget and dies with it: the server
/// keeps no record of what a parent was worried about.
class AskAboutVideoSheet extends StatefulWidget {
  const AskAboutVideoSheet({
    super.key,
    required this.kidId,
    required this.video,
    this.channelTitle = '',
  });

  final String kidId;
  final Video video;
  final String channelTitle;

  static Future<void> open(
    BuildContext context, {
    required String kidId,
    required Video video,
    String channelTitle = '',
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: HgColors.cream,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => AskAboutVideoSheet(
      kidId: kidId,
      video: video,
      channelTitle: channelTitle,
    ),
  );

  @override
  State<AskAboutVideoSheet> createState() => _AskAboutVideoSheetState();
}

class _Turn {
  const _Turn(this.question, this.answer, this.answeredFrom);
  final String question;
  final String answer;
  final String answeredFrom;
}

class _AskAboutVideoSheetState extends State<AskAboutVideoSheet> {
  /// Held on the State, not built in `build`: a controller made during a build
  /// is disposed while the sheet is still using it.
  final _field = TextEditingController();
  final _scroll = ScrollController();
  final _turns = <_Turn>[];
  bool _asking = false;
  String? _error;

  /// Openers, so a parent who does not know what this can answer is not staring
  /// at an empty box. They are the questions the screening cannot anticipate.
  static const _openers = [
    'Is anything scary in it?',
    'Does it try to sell them something?',
    'What would they actually learn?',
  ];

  @override
  void dispose() {
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _ask(String question) async {
    final q = question.trim();
    if (q.isEmpty || _asking) return;
    setState(() {
      _asking = true;
      _error = null;
      _field.clear();
    });
    try {
      final answer = await context.read<AppState>().gateway.askAboutVideo(
        widget.kidId,
        widget.video.id,
        q,
        // Oldest first, so a follow-up like "and how long is that bit?" has
        // something to be a follow-up to.
        history: [for (final t in _turns) (t.question, t.answer)],
      );
      if (!mounted) return;
      setState(() {
        _turns.add(_Turn(q, answer.answer, answer.answeredFrom));
        _asking = false;
      });
      await _toBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _asking = false;
        _error = 'Could not ask just now: $e';
      });
    }
  }

  Future<void> _toBottom() async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted || !_scroll.hasClients) return;
    await _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, sheetScroll) => Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: HgColors.muted,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ask about this video',
                    style: HgText.display(size: 20, color: HgColors.ink),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HgText.body(size: 14, color: HgColors.brown),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: _turns.isEmpty ? sheetScroll : _scroll,
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                children: [
                  if (_turns.isEmpty) ...[
                    Text(
                      'Answered from what is actually said in the video, and from '
                      'what Gilli decided about it. Nothing you ask here changes '
                      'anything — the choice stays yours.',
                      style: HgText.body(size: 14, color: HgColors.brown),
                    ),
                    const SizedBox(height: 14),
                    for (final opener in _openers)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton(
                            onPressed: _asking ? null : () => _ask(opener),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: HgColors.ink,
                              side: const BorderSide(color: HgColors.muted),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                            ),
                            child: Text(
                              opener,
                              style: HgText.body(size: 14, color: HgColors.ink),
                            ),
                          ),
                        ),
                      ),
                  ],
                  for (final turn in _turns) _TurnView(turn: turn),
                  if (_asking)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: HgColors.mango,
                          ),
                        ),
                      ),
                    ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: HgText.body(size: 13, color: HgColors.coral),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _field,
                      enabled: !_asking,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _ask,
                      style: HgText.body(size: 15, color: HgColors.ink),
                      decoration: InputDecoration(
                        hintText: 'Ask anything about it',
                        hintStyle: HgText.body(size: 15, color: HgColors.muted),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: const BorderSide(color: HgColors.muted),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _asking ? null : () => _ask(_field.text),
                    style: IconButton.styleFrom(
                      backgroundColor: HgColors.mango,
                      foregroundColor: HgColors.white,
                      minimumSize: const Size(48, 48),
                    ),
                    icon: const Icon(Icons.arrow_upward_rounded),
                    tooltip: 'Ask',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TurnView extends StatelessWidget {
  const _TurnView({required this.turn});
  final _Turn turn;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 320),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: HgColors.mango,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                turn.question,
                style: HgText.body(size: 15, color: HgColors.ink),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(turn.answer, style: HgText.body(size: 15, color: HgColors.ink)),
          const SizedBox(height: 4),
          // Not a footnote. An answer drawn from a video nobody could read
          // reads exactly like a good one, so what it rests on is said every
          // time — and the server decides this, not the model.
          Text(
            switch (turn.answeredFrom) {
              'the words of the video' =>
                'Answered from what is said in the video',
              'the title and description only' =>
                'Answered from the title and description only — nobody could read this one',
              _ => 'Answered from nothing readable',
            },
            style: HgText.body(
              size: 12,
              color: turn.answeredFrom == 'the words of the video'
                  ? HgColors.muted
                  : HgColors.coral,
            ),
          ),
        ],
      ),
    );
  }
}
