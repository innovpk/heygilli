import 'package:flutter/foundation.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

/// Mobile and desktop: the webview is running the player's own wrapper page,
/// so `player` is right there.
Future<void> hideCaptionsImpl(YoutubePlayerController controller) async {
  try {
    await controller.webViewController.runJavaScript(
      "player.unloadModule('captions'); player.unloadModule('cc');",
    );
  } catch (e) {
    // Best effort: a platform that will not run this keeps its captions and
    // nothing else breaks.
    debugPrint('[yt] could not turn captions off: $e');
  }
}
