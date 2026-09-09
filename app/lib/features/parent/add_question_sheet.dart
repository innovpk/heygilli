import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';

/// Where a parent writes a question of their own for one video.
///
/// The Planner is good at "what happened in this video". It cannot know that
/// this child has been asking about volcanoes all week, or that the woman
/// about to appear is the grandmother they call Nani. So the parent may add
/// their own, and it is asked exactly as they wrote it — nothing rewrites it,
/// and no model reads it before the child hears it.
class AddQuestionSheet extends StatefulWidget {
  const AddQuestionSheet({
    super.key,
    required this.kidId,
    required this.videoId,
    required this.videoTitle,
  });

  final String kidId;
  final String videoId;
  final String videoTitle;

  static Future<void> show(
    BuildContext context, {
    required String kidId,
    required String videoId,
    required String videoTitle,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => AddQuestionSheet(
      kidId: kidId,
      videoId: videoId,
      videoTitle: videoTitle,
    ),
  );

  @override
  State<AddQuestionSheet> createState() => _AddQuestionSheetState();
}

class _AddQuestionSheetState extends State<AddQuestionSheet> {
  final _controller = TextEditingController();
  List<ParentQuestion> _mine = const [];
  bool _yesNo = false;
  bool _busy = false;
  String? _error;

  /// Matches `parent_questions.MAX_PER_VIDEO` on the server, which is the one
  /// that actually holds. This only stops a parent typing a fourth and being
  /// told no afterwards.
  static const maxPerVideo = 3;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final mine = await context.read<AppState>().gateway.parentQuestions(
        widget.kidId,
        widget.videoId,
      );
      if (mounted) setState(() => _mine = mine);
    } catch (_) {
      // An empty list is the right thing to show; a parent who cannot read
      // their own questions can still add one.
    }
  }

  Future<void> _add() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final added = await context.read<AppState>().gateway.addParentQuestion(
        widget.kidId,
        widget.videoId,
        text,
        yesNo: _yesNo,
      );
      if (!mounted) return;
      setState(() {
        _mine = [..._mine, added];
        _controller.clear();
        _yesNo = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'That did not save. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(ParentQuestion q) async {
    setState(() => _mine = _mine.where((x) => x.id != q.id).toList());
    try {
      await context.read<AppState>().gateway.removeParentQuestion(
        widget.kidId,
        widget.videoId,
        q.id,
      );
    } catch (_) {
      if (mounted) _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final full = _mine.length >= maxPerVideo;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: HgColors.cream,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: HgColors.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Ask something of your own',
              style: HgText.display(size: 20, color: HgColors.ink),
            ),
            const SizedBox(height: 4),
            Text(
              widget.videoTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: HgText.body(size: 13, color: HgColors.brown),
            ),
            const SizedBox(height: 14),
            for (final q in _mine)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(
                      q.yesNo
                          ? Icons.rule_rounded
                          : Icons.record_voice_over_rounded,
                      size: 18,
                      color: HgColors.brown,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        q.text,
                        style: HgText.body(size: 14, color: HgColors.ink),
                      ),
                    ),
                    IconButton(
                      onPressed: () => _remove(q),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      color: HgColors.brown,
                      tooltip: 'Remove',
                    ),
                  ],
                ),
              ),
            if (full)
              Text(
                'Three is the most for one video. Past that it stops being '
                'something they are watching.',
                style: HgText.body(size: 13, color: HgColors.brown),
              )
            else ...[
              TextField(
                controller: _controller,
                maxLength: 200,
                minLines: 2,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Which animal was the fastest?',
                  filled: true,
                  fillColor: HgColors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              Row(
                children: [
                  Switch(
                    value: _yesNo,
                    activeThumbColor: HgColors.mango,
                    onChanged: (v) => setState(() => _yesNo = v),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Answer by tapping yes or no',
                      style: HgText.body(size: 14, color: HgColors.ink),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text(
                  _error!,
                  style: HgText.body(size: 13, color: HgColors.coral),
                ),
              ],
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _add,
                  style: FilledButton.styleFrom(
                    backgroundColor: HgColors.mango,
                    foregroundColor: HgColors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(_busy ? 'Saving…' : 'Add it'),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Gilli asks this in your words, where it fits in the video.',
              style: HgText.body(size: 12, color: HgColors.brown),
            ),
          ],
        ),
      ),
    );
  }
}
