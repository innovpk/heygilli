import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/demo_badge.dart';
import '../../core/google_auth.dart';
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
                    GoogleButton(
                      label: 'Continue with Google',
                      busy: _busy,
                      onPressed: canUseGoogle ? _google : null,
                      reason: canUseGoogle
                          ? null
                          : 'This build has no Google client id, so sign-in '
                                'is unavailable.',
                    ),
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
}
