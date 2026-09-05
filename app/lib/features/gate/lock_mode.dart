import 'package:flutter/services.dart';

/// Best-effort Android screen pinning (SPEC 6.4 "lock mode").
///
/// `startLockTask` only locks silently when the app is a device owner;
/// otherwise Android shows its own "pin this app?" confirmation, and on some
/// builds it is simply ignored. We call it and never let a failure reach the
/// kid screen. The parent PIN gate is the real exit control.
abstract final class LockMode {
  static const _channel = MethodChannel('heygilli/lock');

  static Future<bool> start() async {
    try {
      return await _channel.invokeMethod<bool>('startLockTask') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stopLockTask');
    } on PlatformException {
      // Not pinned; nothing to do.
    } on MissingPluginException {
      // Non-Android host.
    }
  }
}
