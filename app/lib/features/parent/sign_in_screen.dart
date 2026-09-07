import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/demo_badge.dart';
import '../../core/google_auth.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

/// Parent sign-in, by either of two doors.
///
/// Google is the front door: the same consent that identifies the parent also
/// brings across the channels they already follow.
///
/// It cannot be the only door. `youtube.readonly` is a Google *restricted*
/// scope, so until the OAuth app passes verification only accounts on the
/// test-user list may sign in — for everyone else the Google button leads to a
/// blocked page, and with one door that is the end of the app. The second door
/// asks for nothing, and the parent brings their channels across from a Takeout
/// export instead.
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

  /// The without-Google door. The household name is generated and remembered,
  /// never typed: the server hashes it into the household id, so a name a
  /// person would pick is a household the next person who picks it walks into.
  Future<void> _withoutGoogle() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = context.read<AppState>();
    try {
      await state.signIn(await state.settings.ensureTrialHousehold());
      // The household name is an identifier, not a person: without this the
      // parent home opens with "Hi trial-3c994baf52eab4ec...".
      await state.settings.clearParentName();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not start: $e';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
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
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= HgLayout.wideBreakpoint;
              if (!wide) {
                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 20,
                        children: [
                          _Brand(isDemo: isDemo, gilliSize: 122),
                          _card(canUseGoogle),
                        ],
                      ),
                    ),
                  ),
                );
              }
              // A phone sign-in screen is one column because a phone only has
              // one column to give it: logo, then pitch, then the button
              // underneath. A window this wide has room to say what HeyGilli
              // is on one side while the actual, much shorter, decision
              // ("sign in with this or that") sits on the other — the shape
              // an auth page on a real website takes, not a form stretched
              // down the middle of empty cream.
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1040),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(48),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 20,
                            children: [
                              SvgPicture.asset(
                                'assets/gilli.svg',
                                width: 96,
                                height: 96,
                              ),
                              Text(
                                'HeyGilli',
                                style: HgText.display(
                                  size: 44,
                                  color: HgColors.ink,
                                ),
                              ),
                              Text(
                                'A buddy who watches YouTube with your kid.',
                                style: HgText.body(
                                  size: 19,
                                  color: HgColors.brown,
                                ),
                              ),
                              Text(
                                'Use the account your kids already watch on, '
                                'usually the one signed in on the TV. Its '
                                'subscriptions become the channels you pick '
                                'from. Only you sign in; your child never '
                                'does.',
                                style: HgText.body(
                                  size: 15,
                                  color: HgColors.muted,
                                ),
                              ),
                              if (isDemo) const DemoBadge(),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 400),
                            child: PCard(child: _card(canUseGoogle, tight: true)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// The actual decision, shared by the phone column and the desktop card:
  /// sign in with Google, or without it.
  Widget _card(bool canUseGoogle, {bool tight = false}) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 16,
    children: [
      if (tight)
        Text(
          'Sign in',
          style: HgText.display(size: 22, color: HgColors.ink),
        ),
      _signInControl(canUseGoogle),
      if (!tight)
        Text(
          'Use the account your kids already watch on, usually '
          'the one signed in on the TV. Its subscriptions become '
          'the channels you pick from. Only you sign in; your '
          'child never does.',
          textAlign: TextAlign.center,
          style: HgText.body(size: 14, color: HgColors.brown),
        ),
      const _OrDivider(),
      SizedBox(
        height: 52,
        child: OutlinedButton(
          onPressed: _busy ? null : _withoutGoogle,
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: HgColors.line),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(26),
            ),
          ),
          child: Text(
            'Set up without Google',
            style: HgText.body(size: 16, color: HgColors.ink),
          ),
        ),
      ),
      Text(
        'Nothing to sign in to. You add channels yourself, or '
        'bring them across from a YouTube export — the next '
        'screen shows you how.',
        textAlign: tight ? TextAlign.start : TextAlign.center,
        style: HgText.body(size: 13, color: HgColors.muted),
      ),
      if (_error != null)
        Text(
          _error!,
          textAlign: tight ? TextAlign.start : TextAlign.center,
          style: HgText.body(size: 14, color: HgColors.coral),
        ),
    ],
  );

  /// One button, every platform. A browser reaches Google's account chooser
  /// and its consent in the same window; a phone gets the native sheet.
  Widget _signInControl(bool canUseGoogle) => GoogleButton(
    label: 'Continue with Google',
    busy: _busy,
    onPressed: canUseGoogle && !_busy ? _google : null,
    reason: canUseGoogle
        ? null
        : 'This build has no Google client id, so sign-in is unavailable.',
  );
}

/// Logo, wordmark and tagline — the phone column's header, unchanged from
/// before the desktop layout existed.
class _Brand extends StatelessWidget {
  const _Brand({required this.isDemo, required this.gilliSize});

  final bool isDemo;
  final double gilliSize;

  @override
  Widget build(BuildContext context) => Column(
    spacing: 6,
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
            width: gilliSize,
            height: gilliSize,
          ),
        ),
      ),
      const SizedBox(height: 14),
      Text('HeyGilli', style: HgText.display(size: 40, color: HgColors.ink)),
      Text(
        'A buddy who watches YouTube with your kid',
        textAlign: TextAlign.center,
        style: HgText.body(size: 16, color: HgColors.brown),
      ),
      if (isDemo) const DemoBadge(),
    ],
  );
}

/// A hairline with "or" set into it, separating the two doors.
class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Expanded(child: Divider(color: HgColors.line, height: 1)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text('or', style: HgText.body(size: 13, color: HgColors.muted)),
      ),
      const Expanded(child: Divider(color: HgColors.line, height: 1)),
    ],
  );
}
