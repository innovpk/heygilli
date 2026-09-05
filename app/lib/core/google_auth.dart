import 'package:google_sign_in/google_sign_in.dart';

import 'settings.dart';

/// Parent-side Google sign-in (SPEC 12: a child never signs in to anything).
///
/// One consent covers identity and `youtube.readonly`, which is what lets the
/// parent import the channels they already follow. What leaves the device is
/// the **server auth code**, never an access or refresh token: the gateway
/// exchanges the code and keeps the refresh token (docs/PROTOCOL.md).
///
/// Written against google_sign_in 7.2.0, whose API is not the 5.x/6.x one:
/// `GoogleSignIn.instance`, `initialize(...)`, `authenticate(...)`, and a
/// separate `authorizationClient` for scopes and server access.
class GoogleAuth {
  GoogleAuth({String? serverClientId})
    : serverClientId = serverClientId ?? BuildConfig.googleServerClientId;

  /// The one instance the app uses. `initialize` may only be called once per
  /// process, so the UI must not build a fresh [GoogleAuth] per button press.
  static final GoogleAuth shared = GoogleAuth();

  /// The **web** OAuth client id. Android needs it as `serverClientId` before
  /// the platform will issue a server auth code at all.
  final String serverClientId;

  /// PROTOCOL: the only scope we ask for. Read-only, the parent's own account.
  static const youtubeReadonlyScope =
      'https://www.googleapis.com/auth/youtube.readonly';

  /// False when the build carries no `HEYGILLI_GOOGLE_SERVER_CLIENT_ID`. The
  /// UI then hides the button instead of showing one that cannot work.
  bool get isConfigured => serverClientId.isNotEmpty;

  /// `initialize` must be called exactly once per process, so the future is
  /// cached and awaited rather than the call repeated.
  Future<void>? _initialized;

  /// Runs the whole flow and returns the server auth code.
  ///
  /// Must be called from a user interaction (a button press): the scope and
  /// server-authorization calls are allowed to show platform UI.
  ///
  /// Never throws a raw platform exception; every outcome is a typed result.
  Future<GoogleAuthResult> signIn() async {
    if (!isConfigured) return const GoogleAuthNotConfigured();
    try {
      _initialized ??= GoogleSignIn.instance.initialize(
        serverClientId: serverClientId,
      );
      await _initialized;

      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        return const GoogleAuthUnavailable(
          'Google sign-in is not available on this device.',
        );
      }

      // Authentication first; authorization is a separate step in 7.x.
      final user = await GoogleSignIn.instance.authenticate(
        scopeHint: const [youtubeReadonlyScope],
      );

      // `authorizeServer` asks for the scope with offline access and returns
      // the code the gateway exchanges. It can legitimately return null when
      // the platform has no server auth code to give (PROTOCOL requires one,
      // so that is a failure for us, not a silent success).
      final server = await user.authorizationClient.authorizeServer(const [
        youtubeReadonlyScope,
      ]);
      if (server == null || server.serverAuthCode.isEmpty) {
        return const GoogleAuthScopeDenied();
      }
      return GoogleAuthSuccess(
        serverAuthCode: server.serverAuthCode,
        email: user.email,
        displayName: user.displayName ?? '',
      );
    } on GoogleSignInException catch (e) {
      return switch (e.code) {
        GoogleSignInExceptionCode.canceled ||
        GoogleSignInExceptionCode.interrupted => const GoogleAuthCancelled(),
        GoogleSignInExceptionCode.clientConfigurationError ||
        GoogleSignInExceptionCode.providerConfigurationError =>
          const GoogleAuthNotConfigured(
            'This build\'s Google client id does not match the app signature.',
          ),
        GoogleSignInExceptionCode.uiUnavailable => const GoogleAuthUnavailable(
          'Google could not show its sign-in screen just now.',
        ),
        _ => GoogleAuthFailed(e.description ?? 'Google sign-in failed.'),
      };
    } catch (e) {
      // MissingPluginException on a platform without the plugin, and anything
      // else the SDK throws: the caller only ever sees a result.
      return GoogleAuthFailed('$e');
    }
  }

  /// Clears the local Google session. The gateway keeps its own link until the
  /// parent disconnects it there.
  Future<void> signOut() async {
    if (_initialized == null) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Signing out is best-effort; never block the UI on it.
    }
  }
}

/// Every outcome of [GoogleAuth.signIn], including the ones that are not bugs.
sealed class GoogleAuthResult {
  const GoogleAuthResult();
}

class GoogleAuthSuccess extends GoogleAuthResult {
  const GoogleAuthSuccess({
    required this.serverAuthCode,
    required this.email,
    this.displayName = '',
  });

  /// Sent to `POST /auth/google`. Single use, exchanged server-side.
  final String serverAuthCode;
  final String email;
  final String displayName;
}

/// The parent backed out. Not an error; say nothing.
class GoogleAuthCancelled extends GoogleAuthResult {
  const GoogleAuthCancelled();
}

/// No `HEYGILLI_GOOGLE_SERVER_CLIENT_ID` in this build, or the id does not
/// match the signing certificate.
class GoogleAuthNotConfigured extends GoogleAuthResult {
  const GoogleAuthNotConfigured([
    this.reason = 'Google sign-in is not set up in this build.',
  ]);
  final String reason;
}

/// Signed in, but YouTube access was not granted, so there is nothing to
/// import. The parent can still paste channel URLs.
class GoogleAuthScopeDenied extends GoogleAuthResult {
  const GoogleAuthScopeDenied();
}

/// Google Play services missing, no activity to show UI on, and similar.
class GoogleAuthUnavailable extends GoogleAuthResult {
  const GoogleAuthUnavailable(this.message);
  final String message;
}

class GoogleAuthFailed extends GoogleAuthResult {
  const GoogleAuthFailed(this.message);
  final String message;
}
