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

  static const _height = 22.0;
  static const _barHeight = 6.0;
  static const _dot = 12.0;

  @override
  Widget build(BuildContext context) {
    if (durationS <= 0 || questionTimes.isEmpty) return const SizedBox.shrink();
    final progress = (positionS / durationS).clamp(0.0, 1.0);

    return Semantics(
      label: '${questionTimes.length} questions in this video, '
          '$askedCount answered so far',
      child: SizedBox(
        height: _height,
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            return Stack(
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
                  child: Container(
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
              ],
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
