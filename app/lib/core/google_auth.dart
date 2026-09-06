import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
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
///
/// **The web is a different shape and cannot be made to look like the others.**
/// The GIS SDK refuses to sign anyone in from an app's own button:
/// `supportsAuthenticate()` is false there and `authenticate()` throws. The
/// browser flow is therefore push, not pull — render the SDK's button, wait on
/// [signIns] for the account it produces — while a phone stays a single
/// awaited [signIn] call. Everything after authentication is identical on both:
/// the same `authorizeServer`, the same server auth code, the same
/// `POST /auth/google`.
class GoogleAuth {
  GoogleAuth({String? serverClientId})
    : serverClientId = serverClientId ?? BuildConfig.googleServerClientId;

  /// The one instance the app uses. `initialize` may only be called once per
  /// process, so the UI must not build a fresh [GoogleAuth] per button press.
  static final GoogleAuth shared = GoogleAuth();

  /// The **web** OAuth client id. Android needs it as `serverClientId` before
  /// the platform will issue a server auth code at all; in a browser the same
  /// id is the `clientId`, because there the app *is* the web client.
  final String serverClientId;

  /// PROTOCOL: the only scope we ask for. Read-only, the parent's own account.
  static const youtubeReadonlyScope =
      'https://www.googleapis.com/auth/youtube.readonly';

  /// False when the build carries no `HEYGILLI_GOOGLE_SERVER_CLIENT_ID`. The
  /// UI then hides the button instead of showing one that cannot work.
  bool get isConfigured => serverClientId.isNotEmpty;

  /// True where the SDK insists on drawing the button itself, so the screen
  /// must render [googleRenderedButton] and listen to [signIns] instead of
  /// calling [signIn] on a tap of its own.
  bool get usesRenderedButton => kIsWeb;

  /// `initialize` must be called exactly once per process, so the future is
  /// cached and awaited rather than the call repeated.
  Future<void>? _initialized;

  Future<void> _initialize() {
    return _initialized ??= GoogleSignIn.instance.initialize(
      // In a browser the id identifies this app to Google directly; on a
      // phone it names the server the auth code is minted for.
      clientId: kIsWeb ? serverClientId : null,
      serverClientId: kIsWeb ? null : serverClientId,
    );
  }

  /// Brings up the SDK so the rendered button has something to attach to.
  /// Safe to call more than once. Only meaningful where
  /// [usesRenderedButton] is true; a phone initializes inside [signIn].
  Future<void> ensureInitialized() async {
    if (!isConfigured) return;
    await _initialize();
  }

  /// Sign-ins that arrive without this app having asked for them — which on
  /// the web is every one of them, because the SDK owns the button.
  ///
  /// Each account is carried through the same authorization step a phone runs,
  /// so a listener gets the finished [GoogleAuthResult] and not a half-done
  /// one. Errors from the SDK arrive here too rather than as a raw exception.
  Stream<GoogleAuthResult> get signIns => GoogleSignIn
      .instance
      .authenticationEvents
      .where((e) => e is GoogleSignInAuthenticationEventSignIn)
      .cast<GoogleSignInAuthenticationEventSignIn>()
      .asyncMap(_afterAuthentication)
      // The SDK reports its failures as errors on this stream. They become
      // results like every other outcome, so a listener has one thing to
      // handle and a dead subscription is impossible.
      .transform(
        StreamTransformer<GoogleAuthResult, GoogleAuthResult>.fromHandlers(
          handleError: (error, stack, sink) => sink.add(_asResult(error)),
        ),
      );

  /// What can be done with a freshly authenticated account, without a gesture.
  ///
  /// On a phone, everything: the OS shows the consent sheet whenever we ask.
  /// In a browser, nothing — the scope consent is a popup, and a popup opened
  /// from a stream callback is blocked, which surfaces as `uiUnavailable` and
  /// reads to a parent as "Google could not show its sign-in screen". So the
  /// browser stops here and hands the account back for a button to finish.
  Future<GoogleAuthResult> _afterAuthentication(
    GoogleSignInAuthenticationEventSignIn e,
  ) async {
    if (GoogleSignIn.instance.authorizationRequiresUserInteraction()) {
      return GoogleAuthNeedsAuthorization(
        account: e.user,
        displayName: e.user.displayName ?? '',
        email: e.user.email,
      );
    }
    return authorize(e.user);
  }

  /// The half of the flow after Google knows who the parent is: ask for the
  /// scope with offline access and get back the code the gateway exchanges.
  ///
  /// **Call this from a button press.** Where
  /// `authorizationRequiresUserInteraction()` is true — the web — anything
  /// else is a popup the browser will not open.
  Future<GoogleAuthResult> authorize(GoogleSignInAccount user) async {
    try {
      // Can legitimately return null when the platform has no server auth code
      // to give. PROTOCOL requires one, so that is a failure for us, not a
      // silent success.
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
    } catch (e) {
      return _asResult(e);
    }
  }

  /// Every failure the SDK can raise, as one of our own results. Nothing that
  /// reaches a screen is ever a raw platform exception.
  static GoogleAuthResult _asResult(Object e) {
    if (e is! GoogleSignInException) return GoogleAuthFailed('$e');
    return switch (e.code) {
      GoogleSignInExceptionCode.canceled ||
      GoogleSignInExceptionCode.interrupted => const GoogleAuthCancelled(),
      GoogleSignInExceptionCode.clientConfigurationError ||
      GoogleSignInExceptionCode.providerConfigurationError =>
        const GoogleAuthNotConfigured(
          'Google rejected this build\'s client id. On the web that is '
          'usually the page\'s address missing from the client\'s '
          'Authorized JavaScript origins.',
        ),
      GoogleSignInExceptionCode.uiUnavailable => const GoogleAuthUnavailable(
        'Google could not show its sign-in screen just now.',
      ),
      _ => GoogleAuthFailed(e.description ?? 'Google sign-in failed.'),
    };
  }

  /// Runs the whole flow and returns the server auth code.
  ///
  /// Must be called from a user interaction (a button press): the scope and
  /// server-authorization calls are allowed to show platform UI.
  ///
  /// Never throws a raw platform exception; every outcome is a typed result.
  Future<GoogleAuthResult> signIn() async {
    if (!isConfigured) return const GoogleAuthNotConfigured();
    try {
      await _initialize();

      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        // The web. There is nothing wrong here and nothing to retry: the SDK
        // owns the button, so the screen should be showing that one.
        return const GoogleAuthUnavailable(
          'Use the Google button above to sign in.',
        );
      }

      // Authentication first; authorization is a separate step in 7.x.
      final user = await GoogleSignIn.instance.authenticate(
        scopeHint: const [youtubeReadonlyScope],
      );
      return authorize(user);
    } catch (e) {
      // MissingPluginException on a platform without the plugin, and anything
      // else the SDK throws: the caller only ever sees a result.
      return _asResult(e);
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

/// Google knows who the parent is, and now the scope has to be asked for from
/// a button press. Only ever emitted where a gesture is required — a browser.
///
/// Not a failure and not a success: the flow is half done, and the screen owes
/// the parent one more tap.
class GoogleAuthNeedsAuthorization extends GoogleAuthResult {
  const GoogleAuthNeedsAuthorization({
    required this.account,
    required this.displayName,
    required this.email,
  });

  /// Pass back to [GoogleAuth.authorize] from the button's handler.
  final GoogleSignInAccount account;
  final String displayName;
  final String email;
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
