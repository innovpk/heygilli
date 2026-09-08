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
    // "More videos" live in an overlay that survives `controls=0`. That
    // overlay is summoned by a pointer — a mouse over the web build, a tap on
    // a tablet — so refusing to forward pointer events is what keeps it away,
    // and measurably does: a player paused by Gilli shows a clean frame.
    //
    // It does not deal with the poster the embed shows *before* it plays,
    // which carries the same links and needs no pointer at all. `PosterCover`
    // is that half, and `poster_cover_test.dart` is where it is checked.
    expect(kidPlayerParams.pointerEvents, PointerEvents.none);
  });

  test('no settings, captions or keyboard seeking for a child to find', () {
    // The settings gear and the CC toggle are the child changing how the video
    // plays; the keyboard is them scrubbing past a question.
    expect(kidPlayerParams.enableCaption, isFalse);
    expect(kidPlayerParams.enableKeyboard, isFalse);
  });
}
