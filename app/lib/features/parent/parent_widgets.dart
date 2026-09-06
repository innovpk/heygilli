import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/demo_badge.dart';
import '../../core/google_auth.dart';
import '../../core/models.dart';
import '../../core/theme.dart';

/// Cream phone surface for every parent screen (design/Phone*.dc.html).
/// The kid side stays deep teal; the parent side is a normal light app.
class ParentScaffold extends StatelessWidget {
  const ParentScaffold({
    super.key,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions = const [],
    this.bottom,
    this.floating,
    this.leading,
  });

  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget> actions;
  final Widget? bottom;
  final Widget? floating;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final isDemo = context.select<AppState, bool>((s) => s.isDemo);
    final canPop = Navigator.of(context).canPop();
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      // This is a phone layout that is now also opened in a browser window.
      // Unconstrained, one kid's row stretches across 1400 px of cream and the
      // page reads as broken rather than as an app. The constraint wraps the
      // whole Scaffold rather than its body, so the bottom bar and the add
      // button stay with the content instead of hugging the window's edges;
      // the cream behind it is the same ground, so no seam shows.
      child: ColoredBox(
        color: HgColors.cream,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Scaffold(
              backgroundColor: HgColors.cream,
              floatingActionButton: floating,
              bottomNavigationBar: bottom,
              body: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                      child: Row(
                        spacing: 12,
                        children: [
                          if (leading != null)
                            leading!
                          else if (canPop)
                            IconButton(
                              onPressed: () => Navigator.of(context).maybePop(),
                              icon: const Icon(Icons.arrow_back_rounded),
                              color: HgColors.ink,
                              tooltip: 'Back',
                            ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (subtitle != null)
                                  Text(subtitle!, style: HgText.label()),
                                Text(
                                  title,
                                  style: HgText.display(
                                    size: 32,
                                    color: HgColors.ink,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isDemo) const DemoBadge(),
                          ...actions,
                        ],
                      ),
                    ),
                    Expanded(child: body),
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

/// White rounded card, matching `.card` in the mockups.
class PCard extends StatelessWidget {
  const PCard({
    super.key,
    required this.child,
    this.color = HgColors.white,
    this.padding = const EdgeInsets.all(20),
    this.onTap,
  });

  final Widget child;
  final Color color;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(22),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Round avatar with the kid's initial. Mango is the single accent so every
/// kid avatar reads as "tap me" the same way.
class KidAvatar extends StatelessWidget {
  const KidAvatar({super.key, required this.kid, this.size = 56});

  final Kid kid;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = kid.nickname.isEmpty ? '?' : kid.nickname[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: HgColors.mango,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: HgText.display(size: size * 0.5, color: HgColors.teal),
      ),
    );
  }
}

/// Small Gilli in a white circle, used as the parent-side mascot.
class GilliMini extends StatelessWidget {
  const GilliMini({super.key, this.size = 56});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: HgColors.white,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.bottomCenter,
      child: SvgPicture.asset(
        'assets/gilli.svg',
        width: size * 0.86,
        height: size * 0.86,
      ),
    );
  }
}

/// Word chips shared by the digest and the Progress screen so vocabulary looks
/// the same wherever a parent meets it. Filled mango = the child said it;
/// outlined = Gilli modelled it and the child has not said it back yet.
class WordChips extends StatelessWidget {
  const WordChips({
    super.key,
    required this.words,
    required this.filled,
    required this.empty,
  });

  final List<String> words;
  final bool filled;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (words.isEmpty) {
      return Text(empty, style: HgText.body(color: HgColors.muted));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final w in words)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: filled ? HgColors.mango : null,
              border: filled
                  ? null
                  : Border.all(color: const Color(0xFFC9B7A0), width: 2),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              w,
              style: HgText.body(
                size: 17,
                weight: FontWeight.w800,
                color: filled ? HgColors.ink : const Color(0xFF6B5A48),
              ),
            ),
          ),
      ],
    );
  }
}

/// White pill for "Continue with Google", used on sign-in and again in the
/// import screen's empty state so the same action always looks the same.
///
/// [reason] is shown under a disabled button: a build with no Google client id
/// says so plainly instead of offering a button that cannot work.
class GoogleButton extends StatelessWidget {
  const GoogleButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.reason,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        SizedBox(
          height: 56,
          child: FilledButton(
            onPressed: busy ? null : onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: HgColors.white,
              foregroundColor: HgColors.ink,
              disabledBackgroundColor: HgColors.line,
              disabledForegroundColor: HgColors.muted,
              shape: const StadiumBorder(),
              side: const BorderSide(color: HgColors.line, width: 2),
            ),
            child: busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: HgColors.brown,
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 12,
                    children: [
                      const _GoogleG(),
                      Text(
                        label,
                        style: HgText.body(
                          size: 17,
                          color: onPressed == null
                              ? HgColors.muted
                              : HgColors.ink,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        if (reason != null)
          Text(
            reason!,
            textAlign: TextAlign.center,
            style: HgText.body(size: 13, color: HgColors.muted),
          ),
      ],
    );
  }
}

class _GoogleG extends StatelessWidget {
  const _GoogleG();

  @override
  Widget build(BuildContext context) {
    return Text(
      'G',
      style: HgText.display(size: 24, color: const Color(0xFF4285F4)),
    );
  }
}

/// Runs Google sign-in and hands the server auth code to the gateway.
///
/// Returns a message to show the parent, or null when there is nothing to say:
/// either it worked, or they backed out of Google's own screen.
///
/// Call this straight from a button handler. google_sign_in requires scope
/// authorization to be initiated by a user interaction.
Future<String?> runGoogleSignIn(BuildContext context) async {
  final state = context.read<AppState>();

  // Demo mode has no OAuth client and must never be blocked by one, so the
  // fake gateway stands in for the whole exchange.
  if (state.isDemo) {
    await state.signInWithGoogle('demo_server_auth_code');
    return null;
  }

  return handleGoogleResult(state, await GoogleAuth.shared.signIn());
}

/// Turns a finished [GoogleAuthResult] into a session, or into the one line
/// the screen should show. Shared by the two shapes the flow comes in: a
/// phone's awaited call, and the web's stream of sign-ins the SDK pushes.
///
/// Returns null when there is nothing to say — including a cancellation, which
/// is a decision, not an error.
Future<String?> handleGoogleResult(
  AppState state,
  GoogleAuthResult result,
) async {
  switch (result) {
    case GoogleAuthSuccess(:final serverAuthCode, :final displayName):
      try {
        await state.signInWithGoogle(serverAuthCode, displayName: displayName);
        return null;
      } catch (e) {
        return 'Signed in with Google, but HeyGilli could not be reached: $e';
      }
    case GoogleAuthNeedsAuthorization():
      // Half-done, and only in a browser. The screen holds the account and
      // puts up the button that finishes it; there is nothing to say here.
      return null;
    case GoogleAuthCancelled():
      return null;
    case GoogleAuthNotConfigured(:final reason):
      return reason;
    case GoogleAuthScopeDenied():
      return 'Without YouTube access there are no subscriptions to import. '
          'You can still paste channel links.';
    case GoogleAuthUnavailable(:final message):
      return message;
    case GoogleAuthFailed(:final message):
      return message;
  }
}

/// "English, Urdu" from ["en", "ur"].
String languageNames(List<String> codes) => codes
    .map(
      (c) => switch (c) {
        'ur' => 'Urdu',
        'en' => 'English',
        _ => c,
      },
    )
    .join(', ');

/// Brief inline error used by the parent screens' FutureBuilders.
class LoadError extends StatelessWidget {
  const LoadError(this.error, {super.key, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          Text(
            'Could not load: $error',
            textAlign: TextAlign.center,
            style: HgText.body(color: HgColors.brown),
          ),
          if (onRetry != null)
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}
