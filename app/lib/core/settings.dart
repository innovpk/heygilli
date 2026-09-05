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

  /// The **web** OAuth client id, passed to google_sign_in as `serverClientId`
  /// so Android will issue a server auth code. Empty in builds with no Google
  /// credentials, which is a supported state: the Google button is hidden and
  /// the name-based dev sign-in carries the whole flow.
  ///
  ///   flutter build apk --dart-define=HEYGILLI_GOOGLE_SERVER_CLIENT_ID=...
  ///
  /// No client id or secret is ever hardcoded in this repo.
  static const googleServerClientId = String.fromEnvironment(
    'HEYGILLI_GOOGLE_SERVER_CLIENT_ID',
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
