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

  _seekRules();

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

/// Where a drag on the question track is allowed to land.
///
/// The questions are the product. A strip that scrubs past them is a skip
/// button, and a child finds a skip button in one afternoon.
void _seekRules() {
  group('dragging the track', () {
    const times = [120, 400, 800];

    test('backwards is free, because nothing is skipped by going back', () {
      expect(
        seekTargetFor(
          wanted: 30,
          durationS: 1000,
          positionS: 500,
          questionTimes: times,
          asked: 2,
        ),
        30,
      );
    });

    test('forwards stops at the next question they have not been asked', () {
      // Two asked, at 120 and 400. The child is at 410 and drags to the end.
      expect(
        seekTargetFor(
          wanted: 990,
          durationS: 1000,
          positionS: 410,
          questionTimes: times,
          asked: 2,
        ),
        800,
      );
    });

    test('forwards is free once every question has been asked', () {
      expect(
        seekTargetFor(
          wanted: 990,
          durationS: 1000,
          positionS: 810,
          questionTimes: times,
          asked: 3,
        ),
        990,
      );
    });

    test('a short hop forwards that clears no question is left alone', () {
      expect(
        seekTargetFor(
          wanted: 300,
          durationS: 1000,
          positionS: 200,
          questionTimes: times,
          asked: 1,
        ),
        300,
      );
    });

    test('never past the end, never before the start', () {
      expect(
        seekTargetFor(
          wanted: 5000,
          durationS: 1000,
          positionS: 999,
          questionTimes: const [],
          asked: 0,
        ),
        1000,
      );
      expect(
        seekTargetFor(
          wanted: -20,
          durationS: 1000,
          positionS: 500,
          questionTimes: const [],
          asked: 0,
        ),
        0,
      );
    });

    test('a question already behind the child does not pin them to it', () {
      // Asked 0, but the child is already at 300 — past the 120 dot, because
      // the server had not got round to asking yet. Clamping to 120 would drag
      // them backwards, which is not what a forward drag is for.
      expect(
        seekTargetFor(
          wanted: 350,
          durationS: 1000,
          positionS: 300,
          questionTimes: times,
          asked: 0,
        ),
        350,
      );
    });
  });
}
