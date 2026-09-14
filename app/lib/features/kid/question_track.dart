import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Where the questions are in this video, and how far along the child is.
///
/// Under the player, never on it. HeyGilli plays by YouTube's rules and those
/// forbid overlays during playback (SPEC "YouTube API Services terms"), so this
/// is its own strip below the video rather than marks on YouTube's own bar.
///
/// It exists because a video that stops dead to ask something is a small shock
/// the first few times. A child who can see the next dot coming is waiting for
/// it instead — and the ones already answered stay filled, which is the only
/// running account of the session a child gets.
class QuestionTrack extends StatelessWidget {
  const QuestionTrack({
    super.key,
    required this.positionS,
    required this.durationS,
    required this.questionTimes,
    required this.askedCount,
    this.onScrub,
    this.onScrubEnd,
    this.scrubbing = false,
  });

  /// Where the video is now, in seconds.
  final double positionS;

  /// The video's length. Zero when nobody could look it up, which is common
  /// enough to matter: without it there is no scale to place a dot on, and the
  /// strip shows nothing rather than putting dots somewhere invented.
  final int durationS;
  final List<int> questionTimes;

  /// How many have been asked so far. The server asks them in order, so this
  /// says which dots are behind the child.
  final int askedCount;

  /// Where the finger is now, in seconds — a preview, not a seek. Null while
  /// Gilli has the video: the strip still shows where they are, it just cannot
  /// be moved.
  final ValueChanged<double>? onScrub;

  /// The finger came off. No position: the last [onScrub] already said where
  /// it was, and `DragEndDetails` does not carry one.
  final VoidCallback? onScrubEnd;

  /// A finger is on the strip. Two things change: the fill stops being
  /// animated, because the only thing slower than a finger is a tween chasing
  /// one, and the thumb grows so it can be seen under the finger holding it.
  final bool scrubbing;

  // A four-year-old drags this on a moving video, so the target is much taller
  // than the bar it draws.
  static const _height = 34.0;
  static const _barHeight = 6.0;
  static const _dot = 12.0;
  static const _thumb = 16.0;
  static const _thumbHeld = 24.0;

  /// The player reports its position every 100ms, so an un-animated fill
  /// advances in visible steps on a short video. Tweening between reports at
  /// the same rate turns the steps back into movement. Linear, because
  /// anything with easing in it reads as the video changing speed.
  static const _catchUp = Duration(milliseconds: 110);

  @override
  Widget build(BuildContext context) {
    if (durationS <= 0 || questionTimes.isEmpty) return const SizedBox.shrink();
    final progress = (positionS / durationS).clamp(0.0, 1.0);

    return Semantics(
      label:
          '${questionTimes.length} questions in this video, '
          '$askedCount answered so far',
      child: SizedBox(
        height: _height,
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            double secondsAt(double dx) => (dx / w).clamp(0.0, 1.0) * durationS;

            final enabled = onScrub != null && onScrubEnd != null;
            return GestureDetector(
              // The whole strip is the target, not the six-pixel bar: this is
              // dragged by a four-year-old with the video still playing.
              behavior: HitTestBehavior.opaque,
              // A tap is a scrub that starts and ends in the same place.
              onTapDown: enabled
                  ? (d) => onScrub!(secondsAt(d.localPosition.dx))
                  : null,
              onTapUp: enabled ? (_) => onScrubEnd!() : null,
              onHorizontalDragStart: enabled
                  ? (d) => onScrub!(secondsAt(d.localPosition.dx))
                  : null,
              onHorizontalDragUpdate: enabled
                  ? (d) => onScrub!(secondsAt(d.localPosition.dx))
                  : null,
              onHorizontalDragEnd: enabled ? (_) => onScrubEnd!() : null,
              onHorizontalDragCancel: enabled ? onScrubEnd : null,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  // The track.
                  Container(
                    height: _barHeight,
                    decoration: BoxDecoration(
                      color: HgColors.tealDeep,
                      borderRadius: BorderRadius.circular(_barHeight / 2),
                    ),
                  ),
                  // How far the child has got.
                  Align(
                    alignment: Alignment.centerLeft,
                    child: AnimatedContainer(
                      duration: scrubbing ? Duration.zero : _catchUp,
                      curve: Curves.linear,
                      height: _barHeight,
                      width: w * progress,
                      decoration: BoxDecoration(
                        color: HgColors.sky,
                        borderRadius: BorderRadius.circular(_barHeight / 2),
                      ),
                    ),
                  ),
                  for (var i = 0; i < questionTimes.length; i++)
                    _Dot(
                      left: (questionTimes[i] / durationS).clamp(0.0, 1.0) * w,
                      done: i < askedCount,
                      size: _dot,
                      width: w,
                    ),
                  // Last, so a question dot never paints over the thing the
                  // finger is holding.
                  if (onScrub != null)
                    AnimatedPositioned(
                      duration: scrubbing ? Duration.zero : _catchUp,
                      curve: Curves.linear,
                      left:
                          (w * progress) -
                          (scrubbing ? _thumbHeld : _thumb) / 2,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOut,
                        width: scrubbing ? _thumbHeld : _thumb,
                        height: scrubbing ? _thumbHeld : _thumb,
                        decoration: BoxDecoration(
                          color: HgColors.sky,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: HgColors.tealDeep,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({
    required this.left,
    required this.done,
    required this.size,
    required this.width,
  });

  final double left;
  final bool done;
  final double size;
  final double width;

  @override
  Widget build(BuildContext context) {
    // Kept whole inside the strip: a question three seconds from the end sits
    // at the very right, and half a dot hanging off the edge reads as a bug.
    final x = (left - size / 2).clamp(0.0, width - size);
    return Positioned(
      left: x,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: done ? HgColors.mango : HgColors.cream,
          shape: BoxShape.circle,
          border: Border.all(color: HgColors.tealDeep, width: 2),
        ),
        child: done
            ? const Icon(Icons.check_rounded, size: 7, color: HgColors.ink)
            : null,
      ),
    );
  }
}
