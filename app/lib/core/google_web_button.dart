/// The Google sign-in button, on the one platform that insists on drawing it
/// itself.
///
/// The GIS SDK will not accept a click from an app's own widget: on the web
/// `supportsAuthenticate()` is false and `authenticate()` throws, and the only
/// way in is the button the SDK renders. Everywhere else HeyGilli draws its
/// own, so this returns null and the caller falls back to it.
///
/// Conditional export rather than a runtime check: `google_sign_in_web` is a
/// web-only package and importing it into an Android build does not compile.
library;

export 'google_web_button_stub.dart'
    if (dart.library.js_interop) 'google_web_button_web.dart';
