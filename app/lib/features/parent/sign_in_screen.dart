import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/demo_badge.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

/// Parent sign-in.
///
/// Google sign-in is built and works, but is not offered. It only ever
/// fetched the *parent's* own subscriptions, while the children's YouTube
/// Kids profiles — the thing this product is actually about — are reachable
/// only through a Takeout export. So the convenient path was the weaker one,
/// and it carried OAuth verification, an unverified-app warning on every
/// sign-in, and the YouTube API Services terms with it.
///
/// Nothing is deleted: [GoogleAuth], `/auth/google` and the token exchange
/// are all intact. Restoring it is putting [GoogleButton] back in [_card].
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

  /// Makes the household. The name is generated and remembered, never typed:
  /// the server hashes it into the household id, so a name a person would pick
  /// is a household the next person who picks it walks straight into.
  Future<void> _start() async {
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

  @override
  Widget build(BuildContext context) {
    final isDemo = context.select<AppState, bool>((s) => s.isDemo);
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
                          _card(),
                        ],
                      ),
                    ),
                  ),
                );
              }
              // A phone sign-in screen is one column because a phone only has
              // one column to give it: logo, then pitch, then the button
              // underneath. A window this wide has room to say what HeyGilli
              // is on one side while the much shorter thing being asked for
              // sits on the other — the shape an auth page on a real website
              // takes, not a form stretched down the middle of empty cream.
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
                                'You pick the channels, and every new upload '
                                'is screened against what you say you are '
                                'fine with. Only you set it up; your child '
                                'never signs in to anything.',
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
                            child: PCard(child: _card(tight: true)),
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

  /// The one action, shared by the phone column and the desktop card.
  Widget _card({bool tight = false}) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 16,
    children: [
      if (tight)
        Text('Start', style: HgText.display(size: 22, color: HgColors.ink)),
      SizedBox(
        height: 52,
        child: FilledButton(
          onPressed: _busy ? null : _start,
          child: _busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              : Text(
                  'Set up your household',
                  style: HgText.body(size: 16, color: HgColors.ink),
                ),
        ),
      ),
      Text(
        'No account, no password, nothing to sign in to. You bring '
        'your channels across from a YouTube export, or add them '
        'yourself — the next screen shows you how.',
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
