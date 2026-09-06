import 'package:flutter/widgets.dart';
import 'package:google_sign_in_web/web_only.dart' as web;

/// The GIS SDK's own button. Its width is fixed by the SDK, so it is centred
/// rather than stretched; forcing it wider only clips the iframe it lives in.
Widget? googleRenderedButton() => Center(
  child: web.renderButton(
    configuration: web.GSIButtonConfiguration(
      theme: web.GSIButtonTheme.outline,
      size: web.GSIButtonSize.large,
      text: web.GSIButtonText.continueWith,
      shape: web.GSIButtonShape.pill,
      minimumWidth: 320,
      // Pinned, or the SDK follows the browser or Google account language and
      // a German button lands under English copy. This works only once the
      // page's origin is registered on the OAuth client: before that the SDK
      // renders an unverified fallback button that ignores the setting, which
      // looks exactly like the setting not working.
      locale: 'en',
    ),
  ),
);
