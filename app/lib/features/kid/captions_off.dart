import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import 'captions_off_stub.dart'
    if (dart.library.js_interop) 'captions_off_web.dart';

/// Turn YouTube's subtitles off, and keep them off.
///
/// A child does not need the transcript of what they are watching read at
/// them, and for a pre-reader it is a wall of text on a screen their band says
/// has none.
///
/// `enableCaption: false` is not enough. It sets `cc_load_policy=0`, and
/// YouTube documents only `1`: the off value is a request, not an instruction,
/// so a viewer whose device or account prefers captions gets them anyway —
/// which is exactly what a screenshot from a session showed.
///
/// `unloadModule` is the API's own way to say it and the only thing that
/// holds. Getting to it differs by platform, which is the whole reason this
/// file exists: on mobile the webview runs the wrapper page, where `player` is
/// a real object; on web the wrapper is a cross-origin-ish iframe that
/// `runJavaScript` cannot reach at all — it fails silently, which is how this
/// shipped once already looking fixed.
Future<void> hideCaptions(YoutubePlayerController controller) =>
    hideCaptionsImpl(controller);
