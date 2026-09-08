import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

/// Web: `runJavaScript` cannot reach inside the player's iframe, and fails
/// without throwing — so this went in once looking correct and changed
/// nothing on the only platform anyone had looked at.
///
/// The wrapper page listens for `message` and forwards `player.<method>(...)`
/// to the real player, which is the same road the package's own calls take.
/// Sent to every iframe on the page: anything that is not the player ignores a
/// message it has no listener for, and hunting for the right one by parsing a
/// `data:` URL would break the first time the package changed it.
Future<void> hideCaptionsImpl(YoutubePlayerController controller) async {
  const calls = [
    'player.unloadModule("captions")',
    'player.unloadModule("cc")',
  ];
  try {
    final frames = web.document.querySelectorAll('iframe');
    for (var i = 0; i < frames.length; i++) {
      final frame = frames.item(i) as web.HTMLIFrameElement?;
      final window = frame?.contentWindow;
      if (window == null) continue;
      for (final call in calls) {
        window.postMessage(
          jsonEncode({'function': call}).toJS,
          '*'.toJS,
        );
      }
    }
  } catch (e) {
    debugPrint('[yt] could not turn captions off: $e');
  }
}
