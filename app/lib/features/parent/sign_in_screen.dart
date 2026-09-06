import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/demo_badge.dart';
import '../../core/google_auth.dart';
import '../../core/google_web_button.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

/// Parent sign-in. Google is the only way in: the same consent that identifies
/// the parent also brings across the channels they already follow, so there is
/// no second path to keep working and no name to type.
///
/// SPEC 12: only the parent ever signs in. Nothing here is shown to a child.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _busy = false;
  String? _error;

  /// Sign-ins the SDK pushes at us rather than ones we asked for. On the web
  /// this is the only way in; elsewhere it never fires.
  StreamSubscription<GoogleAuthResult>? _pushed;

  /// Whether the SDK's own button is ready to be drawn. It cannot be built
  /// before `initialize`, and initialize is a round trip.
  bool _sdkReady = false;

  /// A parent Google has already identified, waiting on the one tap that asks
  /// for YouTube access. Only ever set in a browser: the scope consent is a
  /// popup there, and a popup needs a gesture behind it.
  GoogleAuthNeedsAuthorization? _pending;

  @override
  void initState() {
    super.initState();
    if (GoogleAuth.shared.usesRenderedButton) _listenForPushedSignIn();
  }

  @override
  void dispose() {
    _pushed?.cancel();
    super.dispose();
  }

  /// The browser flow is push, not pull: the parent clicks Google's button,
  /// Google decides who they are, and the account arrives here. Subscribed
  /// before the button exists so a fast sign-in cannot land on nothing.
  Future<void> _listenForPushedSignIn() async {
    // Read once, here: the listener fires long after this frame, and reaching
    // through context at that point is a use across an async gap.
    final state = context.read<AppState>();
    _pushed = GoogleAuth.shared.signIns.listen((result) async {
      if (!mounted) return;
      // Authenticated but not yet authorized: stop and show the button that
      // finishes it, rather than opening a popup the browser will block.
      if (result is GoogleAuthNeedsAuthorization) {
        setState(() {
          _pending = result;
          _error = null;
        });
        return;
      }
      setState(() {
        _busy = true;
        _error = null;
      });
      final message = await handleGoogleResult(state, result);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = message;
      });
    });
    await GoogleAuth.shared.ensureInitialized();
    if (mounted) setState(() => _sdkReady = true);
  }

  /// The second half, from a real button press: ask for YouTube access and
  /// finish the exchange. A parent who declines keeps their session and can
  /// still paste channel links, so this never throws them back to the start.
  Future<void> _authorize(GoogleSignInAccount account) async {
    final state = context.read<AppState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    final message = await handleGoogleResult(
      state,
      await GoogleAuth.shared.authorize(account),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
      if (message != null) _pending = null;
    });
  }

  Future<void> _google() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    // Called straight from the button press: google_sign_in requires scope
    // authorization to be initiated by a user interaction.
    final message = await runGoogleSignIn(context);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDemo = context.select<AppState, bool>((s) => s.isDemo);
    // Without a web client id no server auth code can be issued, so the button
    // is disabled and says why rather than failing at the last step.
    final canUseGoogle = isDemo || GoogleAuth.shared.isConfigured;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: HgColors.cream,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 20,
                  children: [
                    Center(
                      child: Container(
                        width: 140,
                        height: 140,
                        decoration: const BoxDecoration(
                          color: HgColors.white,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.bottomCenter,
                        child: SvgPicture.asset(
                          'assets/gilli.svg',
                          width: 122,
                          height: 122,
                        ),
                      ),
                    ),
                    Column(
                      spacing: 6,
                      children: [
                        Text(
                          'HeyGilli',
                          style: HgText.display(size: 40, color: HgColors.ink),
                        ),
                        Text(
                          'A buddy who watches YouTube with your kid',
                          textAlign: TextAlign.center,
                          style: HgText.body(size: 16, color: HgColors.brown),
                        ),
                        if (isDemo) const DemoBadge(),
                      ],
                    ),
                    _signInControl(canUseGoogle),
                    Text(
                      'Use the account your kids already watch on, usually '
                      'the one signed in on the TV. Its subscriptions become '
                      'the channels you pick from. Only you sign in; your '
                      'child never does.',
                      textAlign: TextAlign.center,
                      style: HgText.body(size: 14, color: HgColors.brown),
                    ),
                    if (_error != null)
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: HgText.body(size: 14, color: HgColors.coral),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Whichever button can actually sign this parent in.
  ///
  /// The GIS SDK refuses a click from a widget we drew, so in a browser the
  /// button has to be its own. Everywhere else it is HeyGilli's, which is the
  /// one a parent should see wherever we are allowed to draw it.
  Widget _signInControl(bool canUseGoogle) {
    if (!canUseGoogle) {
      return GoogleButton(
        label: 'Continue with Google',
        busy: false,
        onPressed: null,
        reason:
            'This build has no Google client id, so sign-in is unavailable.',
      );
    }
    // Demo mode has no OAuth client at all, so it keeps our own button even in
    // a browser: the fake gateway stands in for the whole exchange.
    final isDemo = context.read<AppState>().isDemo;
    if (!GoogleAuth.shared.usesRenderedButton || isDemo) {
      return GoogleButton(
        label: 'Continue with Google',
        busy: _busy,
        onPressed: _busy ? null : _google,
      );
    }
    if (_busy) {
      return const SizedBox(
        height: 56,
        child: Center(child: CircularProgressIndicator(color: HgColors.mango)),
      );
    }
    // Google knows who they are; the scope still has to be asked for, and the
    // asking is a popup that only opens from a press. Ours to draw: the SDK
    // only insists on owning the *authentication* button.
    final pending = _pending;
    if (pending != null) {
      final who = pending.displayName.isNotEmpty
          ? pending.displayName
          : pending.email;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          GoogleButton(
            label: who.isEmpty ? 'Allow YouTube access' : 'Continue as $who',
            busy: false,
            onPressed: () => _authorize(pending.account),
          ),
          Text(
            'One more tap. HeyGilli asks to read the channels you already '
            'follow, and nothing else.',
            textAlign: TextAlign.center,
            style: HgText.body(size: 13, color: HgColors.muted),
          ),
        ],
      );
    }
    // Sized so the layout does not jump when the SDK's button appears.
    return SizedBox(
      height: 56,
      child: _sdkReady
          ? googleRenderedButton()
          : const Center(
              child: CircularProgressIndicator(color: HgColors.mango),
            ),
    );
  }
}
