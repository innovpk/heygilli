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
    expect(kidPlayerParams.showVideoAnnotations, isFalse, reason: 'cards link out');
    expect(kidPlayerParams.strictRelatedVideos, isTrue);
    expect(kidPlayerParams.showFullscreenButton, isFalse);
  });

  test('the player can still be started by the child in front of it', () {
    // `pointerEvents: none` is the obvious way to keep a child away from
    // "Watch on YouTube", and it shipped once. It also stops the video ever
    // playing: the setting is on before the first frame, and a browser that
    // will not autoplay sound — every mobile browser, and Safari — leaves the
    // embed CUED, waiting for a tap that can no longer reach it. It came back
    // as "the video never starts", which is the whole product gone.
    //
    // So this is not a style preference. Turning it on again means a player a
    // child cannot start.
    expect(kidPlayerParams.pointerEvents, isNot(PointerEvents.none));
  });

  test('no settings, captions or keyboard seeking for a child to find', () {
    // The settings gear and the CC toggle are the child changing how the video
    // plays; the keyboard is them scrubbing past a question.
    expect(kidPlayerParams.enableCaption, isFalse);
    expect(kidPlayerParams.enableKeyboard, isFalse);
  });
}
