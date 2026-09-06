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
      // Asked for, but not guaranteed: the GIS SDK takes the language from
      // the signed-in Google account before it takes this, so a parent whose
      // Google is set to German gets a German button under English copy.
      // Verified: `document.documentElement.lang` and `navigator.language`
      // are both en-US here and the button still renders "Weiter mit Google".
      // Nothing in the page can override it, so it is left asked-for rather
      // than claimed.
      locale: 'en',
    ),
  ),
);
