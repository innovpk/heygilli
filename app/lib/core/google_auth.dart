import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart'
    show
        AuthorizationRequestDetails,
        GoogleSignInPlatform,
        ServerAuthorizationTokensForScopesParameters;

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
/// **The web takes a different route to the same place.** GIS will not let an
/// app authenticate from its own button, and its identity button hands back
/// only an id_token — the YouTube scope then needs a second popup, and so a
/// second tap, for something a parent has already agreed to. So a browser skips
/// identity as a separate step and goes straight to the authorization-code
/// flow, which asks for the account and the scope in one window. The code that
/// comes back is exchanged for a refresh token exactly as a phone's is, and the
/// gateway reads who the parent is out of that exchange. One button, one popup,
/// on every platform.
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

  /// Google's own reserved word for a code minted by a popup, which is the
  /// only flow a browser has. A phone sends nothing instead.
  static const popupRedirect = 'postmessage';

  /// What a browser's one popup asks for.
  ///
  /// The YouTube scope is the same one a phone asks for. The three identity
  /// scopes come with it because the browser has no separate sign-in step to
  /// get them from, and without an `id_token` the gateway cannot tell which
  /// Google account this is — it would mint a fresh household on every sign-in
  /// rather than returning the parent to their own.
  static const webScopes = ['openid', 'email', 'profile', youtubeReadonlyScope];

  /// False when the build carries no `HEYGILLI_GOOGLE_SERVER_CLIENT_ID`. The
  /// UI then hides the button instead of showing one that cannot work.
  bool get isConfigured => serverClientId.isNotEmpty;

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

  /// A browser, in one window: pick the account and grant the scope together.
  ///
  /// Goes to the platform directly because the high-level API has no way to
  /// ask for a server auth code without an already-authenticated account, and
  /// requiring one is exactly the second tap this avoids. With no `userId` the
  /// SDK prompts for the account as part of the flow, which is what makes it a
  /// single window.
  /// How long to wait on the popup before saying something.
  ///
  /// Long, because this is a person reading: the account chooser, then the
  /// unverified-app warning while the project is in review, then consent.
  /// Bounded, because a popup the browser blocked never returns at all, and
  /// waiting on it forever left the button spinning with nothing said — which
  /// is what it did, silently, for the whole of one screen recording.
  static const popupWait = Duration(minutes: 3);

  Future<GoogleAuthResult> _webSignIn() async {
    try {
      final tokens = await GoogleSignInPlatform.instance
          .serverAuthorizationTokensForScopes(
            const ServerAuthorizationTokensForScopesParameters(
              request: AuthorizationRequestDetails(
                scopes: webScopes,
                userId: null,
                email: null,
                promptIfUnauthorized: true,
              ),
            ),
          )
          .timeout(popupWait);
      // Null is the parent closing the window, which is a decision, not a fault.
      if (tokens == null || tokens.serverAuthCode.isEmpty) {
        return const GoogleAuthCancelled();
      }
      // Name and email are left to the gateway: they come out of the same
      // token exchange, so asking Google for them twice would be a second
      // round trip for something the next response already carries.
      return GoogleAuthSuccess(
        serverAuthCode: tokens.serverAuthCode,
        email: '',
        redirectUri: popupRedirect,
      );
    } on TimeoutException {
      return const GoogleAuthFailed(
        'Google never answered. If no window opened, your browser probably '
        'blocked the pop-up — allow pop-ups for this site and try again.',
      );
    }
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
        redirectUri: kIsWeb ? popupRedirect : '',
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

      if (!GoogleSignIn.instance.supportsAuthenticate()) return _webSignIn();

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
    this.redirectUri = '',
  });

  /// Sent to `POST /auth/google`. Single use, exchanged server-side.
  final String serverAuthCode;

  /// What Google minted the code against, travelling with the code because
  /// only the side that asked for it knows: empty from a phone, `postmessage`
  /// from a browser popup. The token exchange fails without a match.
  final String redirectUri;
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
