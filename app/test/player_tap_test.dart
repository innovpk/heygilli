import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/features/kid/session_screen.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

/// The one tap a child gets on the video.
///
/// `pointerEvents: none` keeps them out of "Watch on YouTube" and the
/// related-videos panel, and it takes the ordinary tap with it. These are the
/// rules for the tap we hand back in our own layer.
void main() {
  group('what a tap does', () {
    test('pauses what is playing', () {
      expect(
        playerTapFor(
          gilliHasVideo: false,
          onBreak: false,
          ended: false,
          state: PlayerState.playing,
        ),
        PlayerTap.pause,
      );
    });

    test('starts what never started, which is the whole reason it exists', () {
      // A browser that refuses to autoplay leaves the embed sitting on its
      // poster. `_nudge` calls playVideo() five seconds in and cannot help:
      // that is not a user gesture, and a gesture is exactly what is being
      // withheld. A real tap is one, so this is the only way out of it.
      for (final state in [PlayerState.unStarted, PlayerState.cued]) {
        expect(
          playerTapFor(
            gilliHasVideo: false,
            onBreak: false,
            ended: false,
            state: state,
          ),
          PlayerTap.start,
          reason: '$state has to be startable by a tap',
        );
      }
    });

    test('does nothing at all while Gilli has the video', () {
      // The pause IS the question. A child who taps it away has skipped it,
      // and would learn within one session that tapping skips questions.
      for (final state in PlayerState.values) {
        expect(
          playerTapFor(
            gilliHasVideo: true,
            onBreak: false,
            ended: false,
            state: state,
          ),
          PlayerTap.nothing,
          reason: 'a tap must not resume a question, even in $state',
        );
      }
    });

    test('does nothing on a break or after the end', () {
      // A break is the limit the parent set. Tapping is not a way past it.
      expect(
        playerTapFor(
          gilliHasVideo: false,
          onBreak: true,
          ended: false,
          state: PlayerState.paused,
        ),
        PlayerTap.nothing,
      );
      expect(
        playerTapFor(
          gilliHasVideo: false,
          onBreak: false,
          ended: true,
          state: PlayerState.paused,
        ),
        PlayerTap.nothing,
      );
    });
  });

  group('when the play glyph is drawn', () {
    test('never over playing video', () {
      // YouTube's terms forbid an overlay on playing video. It is why the
      // question strip lives under the player and not on it.
      expect(
        showsPlayGlyph(
          gilliHasVideo: false,
          onBreak: false,
          ended: false,
          childPaused: false,
          state: PlayerState.playing,
        ),
        isFalse,
      );
    });

    test('on a video the child paused', () {
      expect(
        showsPlayGlyph(
          gilliHasVideo: false,
          onBreak: false,
          ended: false,
          childPaused: true,
          state: PlayerState.paused,
        ),
        isTrue,
      );
    });

    test('on a video that never started, so there is something to press', () {
      expect(
        showsPlayGlyph(
          gilliHasVideo: false,
          onBreak: false,
          ended: false,
          childPaused: false,
          state: PlayerState.unStarted,
        ),
        isTrue,
      );
    });

    test('never while Gilli is asking, however the video got stopped', () {
      // A play button on the frame during a question reads as the way out of
      // the question. Gilli's pause is answered by answering, not by pressing.
      expect(
        showsPlayGlyph(
          gilliHasVideo: true,
          onBreak: false,
          ended: false,
          childPaused: true,
          state: PlayerState.paused,
        ),
        isFalse,
      );
    });

    test('never on a break or after the end', () {
      expect(
        showsPlayGlyph(
          gilliHasVideo: false,
          onBreak: true,
          ended: false,
          childPaused: true,
          state: PlayerState.paused,
        ),
        isFalse,
      );
      expect(
        showsPlayGlyph(
          gilliHasVideo: false,
          onBreak: false,
          ended: true,
          childPaused: true,
          state: PlayerState.paused,
        ),
        isFalse,
      );
    });
  });
}
