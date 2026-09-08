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

  test('nothing this app sends reaches the embed', () {
    // The control bar is gone, but "Watch on YouTube", the share button and
    // "More videos" live in a hover overlay that survives `controls=0`. On a
    // tablet nothing summons it; on the web build a mouse does. The player is
    // not hidden, moved or covered — it renders as YouTube serves it — we just
    // stop forwarding pointer events into it.
    expect(kidPlayerParams.pointerEvents, PointerEvents.none);
  });

  test('no settings, captions or keyboard seeking for a child to find', () {
    // The settings gear and the CC toggle are the child changing how the video
    // plays; the keyboard is them scrubbing past a question.
    expect(kidPlayerParams.enableCaption, isFalse);
    expect(kidPlayerParams.enableKeyboard, isFalse);
  });
}
