import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Build-time configuration.
///
///   flutter run --dart-define=HEYGILLI_API_URL=http://10.0.2.2:8080
///   flutter run --dart-define=HEYGILLI_DEMO=true
abstract final class BuildConfig {
  static const _apiUrl = String.fromEnvironment('HEYGILLI_API_URL');

  /// Where the gateway is. A define wins; otherwise it is the local one, at
  /// whatever address *this* platform calls the host machine.
  static String get apiUrl => _apiUrl.isEmpty ? _localGateway : _apiUrl;

  /// The dev gateway, addressed the way each platform can reach it.
  ///
  /// The Android emulator is the odd one out: it runs behind its own NAT and
  /// `localhost` is the emulated phone, not the Mac. 10.0.2.2 is its alias for
  /// the host. Everywhere else — iOS simulator, web, desktop — shares the
  /// host's loopback and `localhost` is right. A real phone reaches neither
  /// and needs the define.
  static String get _localGateway =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? 'http://10.0.2.2:8080'
      : 'http://localhost:8080';

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

  /// Device label sent with `POST /sessions`, so a digest can say where a
  /// session happened rather than guessing.
  static String get device =>
      kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase();
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
  static const _kidDeviceKey = 'kid_device_kid_id';
  static const _daylightKey = 'kid_daylight_';
  static const _kidBackgroundKey = 'kid_background_';
  static const _trialKey = 'trial_household';

  String? get pin => _prefs.getString(_pinKey);
  Future<void> setPin(String pin) => _prefs.setString(_pinKey, pin);

  /// Forget the PIN, so the next gate asks for a new one.
  ///
  /// There was no way to do this. The PIN is chosen once, kept only on this
  /// device, and never sent anywhere, so a parent who mistyped it at setup or
  /// simply forgot it could not leave kid mode again on that device — with no
  /// reset, no recovery and nothing to email. The confirm step at setup was
  /// the only thing standing between a household and that.
  Future<void> clearPin() => _prefs.remove(_pinKey);

  String? get token => _prefs.getString(_tokenKey);
  Future<void> setToken(String? token) => token == null
      ? _prefs.remove(_tokenKey)
      : _prefs.setString(_tokenKey, token);

  String? get parentName => _prefs.getString(_parentNameKey);
  Future<void> setParentName(String name) =>
      _prefs.setString(_parentNameKey, name);

  /// Used by the without-Google door, whose household name is 32 random hex
  /// characters. It is an identifier, not a person, and the parent home greets
  /// whatever is stored here by name.
  Future<void> clearParentName() => _prefs.remove(_parentNameKey);

  /// The child this device belongs to, or null when it is a parent's device.
  ///
  /// The parent app is not behind the PIN — the PIN guards *leaving* kid mode,
  /// not entering the app — so on a child's own tablet the first screen was
  /// the household's kid list, with every child's digest, progress, watch
  /// history and limits one tap away and nothing in front of them. A device
  /// with this set boots straight into that child's videos and never shows
  /// the parent app until someone types the PIN.
  ///
  /// Stored on the device, not the account: which tablet belongs to whom is a
  /// fact about this tablet, and a parent signing in on their own phone must
  /// not inherit it.
  String? get kidDeviceId => _prefs.getString(_kidDeviceKey);
  Future<void> setKidDeviceId(String? kidId) => kidId == null || kidId.isEmpty
      ? _prefs.remove(_kidDeviceKey)
      : _prefs.setString(_kidDeviceKey, kidId);

  /// Whether this child picked the light ground for kid mode.
  ///
  /// Per child and per device, like the device owner above: two siblings
  /// sharing a tablet get their own answer, and the choice does not follow
  /// them onto a screen in a different room with different light. Absent means
  /// the dark ground, which is the default and always was.
  bool kidLikesDaylight(String kidId) =>
      _prefs.getBool('$_daylightKey$kidId') ?? false;

  Future<void> setKidLikesDaylight(String kidId, bool daylight) => daylight
      ? _prefs.setBool('$_daylightKey$kidId', true)
      : _prefs.remove('$_daylightKey$kidId');

  /// Which background wallpaper theme this child picked for the shelf.
  ///
  /// Per child and per device. Absent means the default space/cosmic theme.
  String? kidBackground(String kidId) =>
      _prefs.getString('$_kidBackgroundKey$kidId');

  Future<void> setKidBackground(String kidId, String themeId) =>
      _prefs.setString('$_kidBackgroundKey$kidId', themeId);

  /// The household name used by the without-Google path, kept so that closing
  /// the app and coming back lands in the same household rather than a new
  /// empty one.
  ///
  /// Generated, never typed. The server derives the household id by hashing
  /// this name, so a name a person would choose — "test", a first name — is a
  /// household anyone else who picks it walks straight into. 128 bits from a
  /// secure generator makes that collision unreachable.
  String? get trialHousehold => _prefs.getString(_trialKey);

  Future<String> ensureTrialHousehold() async {
    final existing = _prefs.getString(_trialKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final rng = Random.secure();
    final name =
        'trial-'
        '${List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    await _prefs.setString(_trialKey, name);
    return name;
  }
}
