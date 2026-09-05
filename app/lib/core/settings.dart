import 'package:shared_preferences/shared_preferences.dart';

/// Build-time configuration.
///
///   flutter run --dart-define=HEYGILLI_API_URL=http://10.0.2.2:8080
///   flutter run --dart-define=HEYGILLI_DEMO=true
///
/// 10.0.2.2 is the Android emulator's alias for the host machine, where the
/// gateway runs during development.
abstract final class BuildConfig {
  static const apiUrl = String.fromEnvironment(
    'HEYGILLI_API_URL',
    defaultValue: 'http://10.0.2.2:8080',
  );

  static const forceDemo = bool.fromEnvironment(
    'HEYGILLI_DEMO',
    defaultValue: false,
  );

  /// Device label sent with POST /sessions.
  static const device = 'android';
}

/// Small persisted settings. Nothing a child says is ever stored here.
class LocalSettings {
  LocalSettings(this._prefs);

  static Future<LocalSettings> load() async =>
      LocalSettings(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  static const _pinKey = 'parent_pin';
  static const _tokenKey = 'auth_token';
  static const _parentNameKey = 'parent_name';

  String? get pin => _prefs.getString(_pinKey);
  Future<void> setPin(String pin) => _prefs.setString(_pinKey, pin);

  String? get token => _prefs.getString(_tokenKey);
  Future<void> setToken(String? token) => token == null
      ? _prefs.remove(_tokenKey)
      : _prefs.setString(_tokenKey, token);

  String? get parentName => _prefs.getString(_parentNameKey);
  Future<void> setParentName(String name) =>
      _prefs.setString(_parentNameKey, name);
}
