import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'fake_gateway.dart';
import 'gateway.dart';
import 'google_auth.dart';
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

  /// Live, unless this build was explicitly made as a demo.
  ///
  /// This used to fall back to the canned demo whenever the gateway did not
  /// answer, which meant a parent on bad wifi was silently shown invented
  /// children and reviews that were not theirs, marked only by a small chip.
  /// An unreachable gateway is now an error the parent can see and retry;
  /// canned data ships only when someone asked for it at build time.
  static Future<AppState> bootstrap() async {
    final settings = await LocalSettings.load();
    Gateway gateway;
    if (BuildConfig.forceDemo) {
      gateway = FakeGateway();
    } else {
      final api = ApiClient(baseUrl: BuildConfig.apiUrl, token: settings.token);
      api.onToken = settings.setToken;
      if (!await api.reachable()) {
        throw GatewayUnreachable(BuildConfig.apiUrl);
      }
      gateway = api;
    }
    final state = AppState(gateway: gateway, settings: settings);
    if (gateway.signedIn) {
      await state.refreshKids();
    }
    // A child's own device comes up already in kid mode, so the first frame is
    // their videos rather than the parent app deciding to redirect.
    final owner = state.deviceKid;
    if (owner != null) state.enterKidMode(owner);
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
    String redirectUri = '',
  }) async {
    final session = await gateway.signInWithGoogle(
      serverAuthCode,
      redirectUri: redirectUri,
    );
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

  /// Correct a child who already exists. The list is refreshed so every screen
  /// holding the old age — the band drives what the child is even shown — sees
  /// the new one.
  Future<Kid> editKid(
    String kidId, {
    String? nickname,
    int? age,
    List<String>? languages,
    String? avatar,
  }) async {
    final kid = await gateway.editKid(
      kidId,
      nickname: nickname,
      age: age,
      languages: languages,
      avatar: avatar,
    );
    await refreshKids();
    if (_activeKid?.id == kidId) _activeKid = kid;
    return kid;
  }

  void enterKidMode(Kid kid) {
    _activeKid = kid;
    _kidMode = true;
    _parentVisiting = false;
    notifyListeners();
  }

  void leaveKidMode() {
    _kidMode = false;
    // Only reached through the PIN gate, so this is a parent standing at the
    // tablet. It lasts until the app is next launched: a visit, not a change
    // of ownership.
    _parentVisiting = true;
    notifyListeners();
  }

  bool _parentVisiting = false;

  /// True while a parent is looking at a child's device, having typed the PIN.
  ///
  /// The boot route sends a kid device to its videos, but a route is one line
  /// and every other way into the parent app would walk straight past it. The
  /// parent root asks this instead, so on a child's device the answer is their
  /// videos unless a parent is standing there.
  bool get parentVisiting => _parentVisiting;

  /// Back to the child, ending the visit.
  void endParentVisit() {
    _parentVisiting = false;
    notifyListeners();
  }

  /// Whose device this is, read once at launch.
  ///
  /// Not re-read from settings on every call: which child a tablet belongs to
  /// is decided when the app starts and must not change under a session that
  /// is already running.
  late String? _deviceKidId = settings.kidDeviceId;

  /// The child this device belongs to, or null on a parent's device.
  ///
  /// Null is also the answer when the stored id names a child who no longer
  /// exists — a deleted profile must not leave a tablet stuck on a boot screen
  /// for nobody.
  Kid? get deviceKid {
    final id = _deviceKidId;
    if (id == null) return null;
    return _kids.where((k) => k.id == id).firstOrNull;
  }

  bool get isKidDevice => deviceKid != null;

  /// Hands this device to one child, or takes it back. Behind the PIN at every
  /// call site: a child who could undo it has no boundary at all.
  Future<void> setDeviceKid(Kid? kid) async {
    await settings.setKidDeviceId(kid?.id);
    _deviceKidId = kid?.id;
    notifyListeners();
  }

  /// Ends the session on this device: the household token, the parent's name,
  /// and Google's own local session.
  ///
  /// Deliberately leaves the PIN and the device owner alone. Signing out is
  /// about this account, not about whose tablet this is — a parent signing out
  /// on a child's device must not quietly hand them the parent app back.
  Future<void> signOut() async {
    await GoogleAuth.shared.signOut();
    await settings.setToken(null);
    _kids = const [];
    _activeKid = null;
    _kidMode = false;
    gateway.forgetToken();
    notifyListeners();
  }

  bool get hasPin => settings.pin != null;
  bool checkPin(String pin) => settings.pin == pin;
  Future<void> setPin(String pin) => settings.setPin(pin);

  /// Forget this device's parent PIN. The next gate asks for a new one.
  ///
  /// Only reachable from the parent app, which is behind the PIN on a child's
  /// device — so this is a parent who is already past the gate choosing a new
  /// number, never a child clearing their way out.
  Future<void> clearPin() async {
    await settings.clearPin();
    notifyListeners();
  }
}

/// HeyGilli could not be reached at startup.
///
/// Deliberately not silent: showing canned data instead would mean a parent
/// looking at children and channels that are not theirs.
class GatewayUnreachable implements Exception {
  const GatewayUnreachable(this.url);
  final String url;

  @override
  String toString() => 'Could not reach HeyGilli at $url';
}
