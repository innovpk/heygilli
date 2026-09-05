import 'package:flutter/services.dart';

/// Kid mode is landscape: a 16:9 video, Gilli beside it and three big pick
/// cards all need width. The parent app is portrait like every other phone
/// app a parent uses.
///
/// Set on entering and leaving kid mode, never per screen, so a dialog opened
/// inside kid mode (the PIN gate) does not fight the mode it was opened from.
abstract final class ScreenOrientation {
  static Future<void> kidMode() => SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  static Future<void> parentMode() => SystemChrome.setPreferredOrientations(
    const [DeviceOrientation.portraitUp],
  );
}
