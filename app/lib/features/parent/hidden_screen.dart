import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'ask_about_video_sheet.dart';
import 'parent_widgets.dart';

/// What Gilli kept from a child, and why it did.
///
/// Screening that only ever shows its successes is a screening a parent has to
/// take on trust. The child never sees any of this — a hidden video is simply
/// not on their shelf, with nothing to say it was ever there, which is the
/// right answer for them and the wrong one for the person who set the rules.
///
/// So: parent-only, every hidden video, each with the sentence Gilli wrote
/// when it decided. A parent who disagrees can put any of them back from here,
/// because a rule they cannot overrule is a rule they cannot trust either.
class HiddenScreen extends StatefulWidget {
  const HiddenScreen({super.key, required this.kid});
  final Kid kid;

  @override
  State<HiddenScreen> createState() => _HiddenScreenState();
}

class _HiddenScreenState extends State<HiddenScreen> {
  late Future<ReviewQueue> _queue = _load();
  final _restoring = <String>{};

  Future<ReviewQueue> _load() =>
      context.read<AppState>().gateway.reviewQueue(widget.kid.id);

  Future<void> _restore(ReviewItem item) async {
    setState(() => _restoring.add(item.video.id));
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AppState>().gateway.reviewDecide(
        widget.kid.id,
        approve: [item.video.id],
      );
      if (!mounted) return;
      setState(() => _queue = _load());
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${item.video.title} is on ${widget.kid.nickname}\'s shelf.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _restoring.remove(item.video.id));
      messenger.showSnackBar(SnackBar(content: Text('Could not allow it: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ParentScaffold(
      title: 'Kept from ${widget.kid.nickname}',
      body: FutureBuilder<ReviewQueue>(
        future: _queue,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(color: HgColors.mango),
            );
          }
          if (snap.hasError) {
            return _Note(text: 'Could not load it: ${snap.error}');
          }
          final hidden = [
            for (final i in snap.data?.items ?? const <ReviewItem>[])
              if (i.status == 'hide') i,
          ];
          if (hidden.isEmpty) {
            return _Note(
              text:
                  'Nothing has been kept from ${widget.kid.nickname} yet. '
                  'When Gilli hides a video, it will be here with its reason.',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Text(
                '${widget.kid.nickname} never sees these and is never told '
                'about them. You can put any of them back.',
                style: HgText.body(size: 14, color: HgColors.brown),
              ),
              const SizedBox(height: 12),
              for (final item in hidden)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: PCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 8,
                      children: [
                        Text(
                          item.video.title,
                          style: HgText.body(size: 15, color: HgColors.ink),
                        ),
                        Text(
                          item.channelTitle,
                          style: HgText.body(size: 13, color: HgColors.muted),
                        ),
                        Text(
                          item.reason,
                          style: HgText.body(size: 14, color: HgColors.coral),
                        ),
                        Text(
                          item.read == 'title only'
                              ? 'Read: the title and description only'
                              : 'Read: what is said in the video',
                          style: HgText.body(size: 12, color: HgColors.muted),
                        ),
                        Row(
                          children: [
                            TextButton(
                              onPressed: _restoring.contains(item.video.id)
                                  ? null
                                  : () => _restore(item),
                              child: Text(
                                'Allow it anyway',
                                style: HgText.body(size: 14),
                              ),
                            ),
                            // "Why is this one being kept from her?" is the
                            // question this screen exists to raise and could
                            // not answer beyond the one line it was given.
                            TextButton.icon(
                              onPressed: () => AskAboutVideoSheet.open(
                                context,
                                kidId: widget.kid.id,
                                video: item.video,
                                channelTitle: item.channelTitle,
                              ),
                              icon: const Icon(
                                Icons.help_outline_rounded,
                                size: 18,
                              ),
                              label: const Text('Ask about this'),
                              style: TextButton.styleFrom(
                                foregroundColor: HgColors.ink,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: HgText.body(size: 15, color: HgColors.brown),
      ),
    ),
  );
}
