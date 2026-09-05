import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'fake_gateway.dart';
import 'gateway.dart';
import 'models.dart';
import 'settings.dart';

/// App-wide state: which gateway we talk to, who is signed in, which kid is
/// active, and whether the device is handed over to a kid.
///
/// Plain ChangeNotifier on purpose: the whole app has a handful of screens
/// and one shared object is easier for a reviewer to follow than a framework.
class AppState extends ChangeNotifier {
  AppState({required this.gateway, required this.settings});

  final Gateway gateway;
  final LocalSettings settings;

  /// Picks live or demo. Live wins when the gateway answers within 2 s; the
  /// demo is used otherwise, or always when HEYGILLI_DEMO=true.
  static Future<AppState> bootstrap() async {
    final settings = await LocalSettings.load();
    Gateway gateway;
    if (BuildConfig.forceDemo) {
      gateway = FakeGateway();
    } else {
      final api = ApiClient(baseUrl: BuildConfig.apiUrl, token: settings.token);
      api.onToken = settings.setToken;
      gateway = await api.reachable() ? api : FakeGateway();
    }
    final state = AppState(gateway: gateway, settings: settings);
    if (gateway.signedIn) {
      await state.refreshKids();
    }
    return state;
  }

  bool get isDemo => gateway.isDemo;
  bool get signedIn => gateway.signedIn;

  List<Kid> _kids = const [];
  List<Kid> get kids => _kids;

  Kid? _activeKid;
  Kid? get activeKid => _activeKid;

  bool _kidMode = false;

  /// True while the device is handed to a kid; leaving needs the parent PIN.
  bool get kidMode => _kidMode;

  Future<void> signIn(String name) async {
    await gateway.signInDev(name);
    await settings.setParentName(name);
    await refreshKids();
  }

  /// Signs in with the server auth code from [GoogleAuth]. The gateway
  /// exchanges the code and keeps the refresh token; nothing of the sort ever
  /// reaches this object (PROTOCOL).
  Future<Session> signInWithGoogle(
    String serverAuthCode, {
    String displayName = '',
  }) async {
    final session = await gateway.signInWithGoogle(serverAuthCode);
    final name = displayName.trim().isNotEmpty
        ? displayName.trim()
        : _nameFromEmail(session.email);
    if (name.isNotEmpty) await settings.setParentName(name);
    await refreshKids();
    return session;
  }

  /// "asma.khan@gmail.com" → "Asma". A greeting, not an identity.
  static String _nameFromEmail(String email) {
    final local = email.split('@').first.split(RegExp(r'[._-]')).first;
    if (local.isEmpty) return '';
    return local[0].toUpperCase() + local.substring(1);
  }

  Future<void> refreshKids() async {
    _kids = await gateway.kids();
    notifyListeners();
  }

  Future<Kid> addKid({
    required String nickname,
    required int age,
    required List<String> languages,
  }) async {
    final kid = await gateway.createKid(
      nickname: nickname,
      age: age,
      languages: languages,
    );
    await refreshKids();
    return kid;
  }

  void enterKidMode(Kid kid) {
    _activeKid = kid;
    _kidMode = true;
    notifyListeners();
  }

  void leaveKidMode() {
    _kidMode = false;
    notifyListeners();
  }

  bool get hasPin => settings.pin != null;
  bool checkPin(String pin) => settings.pin == pin;
  Future<void> setPin(String pin) => settings.setPin(pin);
}
