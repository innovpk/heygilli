import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/features/kid/session_screen.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

/// What YouTube's own player is allowed to show a child.
///
/// These are documented IFrame Player API parameters, not anything drawn over
/// the player — the terms forbid overlaying it, not configuring it.
void main() {
  test('the control bar is off, and that is an allowlist rule', () {
    // On pause, the control bar brings YouTube's "More videos" panel with it.
    // Every video on a child's shelf was read against what their household
    // said; one tap there put them in an unscreened video in the same frame,
    // which is the allowlist gone from the one screen built to enforce it.
    expect(kidPlayerParams.showControls, isFalse);
  });

  test('nothing on the player invites a child somewhere else', () {
    expect(
      kidPlayerParams.showVideoAnnotations,
      isFalse,
      reason: 'cards link out',
    );
    expect(kidPlayerParams.strictRelatedVideos, isTrue);
    expect(kidPlayerParams.showFullscreenButton, isFalse);
  });

  test('nothing this app sends reaches the embed', () {
    // The control bar is gone, but "Watch on YouTube", the share button and,
    // on pause, "More videos" live in an overlay that survives `controls=0`.
    // That panel is the allowlist gone: one tap and the child is in a video
    // nobody screened, inside the same frame.
    expect(kidPlayerParams.pointerEvents, PointerEvents.none);
  });

  test('and so the video has to start without a tap', () {
    // These two go together, and separating them broke the app once.
    //
    // `pointerEvents: none` is written into the wrapper before the first
    // frame, so it is already on while the embed is CUED — and every mobile
    // browser, and Safari, refuses to autoplay anything with sound. The player
    // sat on its poster waiting for a tap that could never arrive, and the
    // video never began at all.
    //
    // Muted autoplay is permitted everywhere. The sound is turned back on as
    // soon as it is playing, and `SoundButton` covers the browsers that refuse
    // to be told.
    expect(
      kidPlayerParams.mute,
      isTrue,
      reason: 'unmuted + pointerEvents:none is a player that never starts',
    );
  });

  test('no settings, captions or keyboard seeking for a child to find', () {
    // The settings gear and the CC toggle are the child changing how the video
    // plays; the keyboard is them scrubbing past a question.
    expect(kidPlayerParams.enableCaption, isFalse);
    expect(kidPlayerParams.enableKeyboard, isFalse);
  });
}
