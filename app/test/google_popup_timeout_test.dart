import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:heygilli/core/google_auth.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// A pop-up that never returns.
///
/// The web sign-in awaited `serverAuthorizationTokensForScopes` with nothing
/// bounding it. When a browser blocks the pop-up the call simply never
/// settles, so the button span for as long as anyone was willing to watch and
/// the parent was told nothing at all — which is exactly what a screen
/// recording of the flow caught, spinning from one end of the take to the
/// other.
void main() {
  test('a pop-up that never returns eventually says so', () {
    fakeAsync((async) {
      GoogleSignInPlatform.instance = _SilentPlatform();
      GoogleAuthResult? result;
      GoogleAuth(
        serverClientId: 'test-client',
      ).signIn().then((r) => result = r);

      async.elapse(GoogleAuth.popupWait - const Duration(seconds: 1));
      expect(
        result,
        isNull,
        reason: 'gave up while a person was still reading',
      );

      async.elapse(const Duration(seconds: 2));
      expect(result, isA<GoogleAuthFailed>());
      expect(
        (result! as GoogleAuthFailed).message.toLowerCase(),
        contains('pop-up'),
        reason: 'the parent needs to know what to actually do about it',
      );
    });
  });

  test('the wait is long enough for a person to read a consent screen', () {
    // Account chooser, then the unverified-app warning while the project is
    // in review, then consent. A minute is not enough for that.
    expect(
      GoogleAuth.popupWait,
      greaterThanOrEqualTo(const Duration(minutes: 2)),
    );
  });
}

/// Answers nothing, forever — a blocked pop-up.
class _SilentPlatform extends GoogleSignInPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) => Completer<ServerAuthorizationTokenData?>().future;

  // The rest of the interface: this fake exists to hold one call open.
  @override
  Future<void> init(InitParameters params) async {}
  // False is what a browser reports, which is what sends signIn down the
  // pop-up path this test is about.
  @override
  bool supportsAuthenticate() => false;
  @override
  Future<AuthenticationResults?> attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) async => null;
  @override
  Future<AuthenticationResults> authenticate(AuthenticateParameters params) =>
      Completer<AuthenticationResults>().future;
  @override
  bool authorizationRequiresUserInteraction() => false;
  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async => null;
  @override
  Future<void> signOut(SignOutParams params) async {}
  @override
  Future<void> disconnect(DisconnectParams params) async {}
}
