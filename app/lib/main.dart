import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import 'core/app_state.dart';
import 'core/orientation.dart';
import 'core/icon_library.dart';
import 'core/speech.dart';
import 'core/theme.dart';
import 'features/kid/home_screen.dart';
import 'features/parent/parent_home.dart';
import 'features/parent/sign_in_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  ScreenOrientation.parentMode();
  runApp(const HeyGilliApp());
}

/// Named routes. Kid mode is a separate route stack root so the parent side
/// is never one back-press away from a child (the PIN gate is the only exit).
abstract final class Routes {
  static const parent = '/';
  static const kid = '/kid';
}

class HeyGilliApp extends StatefulWidget {
  const HeyGilliApp({super.key});

  @override
  State<HeyGilliApp> createState() => _HeyGilliAppState();
}

class _HeyGilliAppState extends State<HeyGilliApp> {
  /// Probes the gateway (2 s) and loads the bundled pick-it icon library
  /// before the first screen. An unreachable gateway surfaces as an error the
  /// parent can retry, never as canned data wearing a small badge.
  late Future<(AppState, IconLibrary)> _boot = _start();

  Future<(AppState, IconLibrary)> _start() async {
    final results = await Future.wait([
      AppState.bootstrap(),
      IconLibrary.load(),
    ]);
    return (results[0] as AppState, results[1] as IconLibrary);
  }

  void _retry() => setState(() => _boot = _start());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _boot,
      builder: (context, snap) {
        if (snap.hasError) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(),
            home: _CannotConnect(error: snap.error!, onRetry: _retry),
          );
        }
        final data = snap.data;
        if (data == null) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(),
            home: const _Splash(),
          );
        }
        final (state, icons) = data;
        return MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: state),
            Provider<IconLibrary>.value(value: icons),
            // One voice for the whole app so two screens never talk at once.
            ChangeNotifierProvider<GilliVoice>(create: (_) => GilliVoice()),
          ],
          child: MaterialApp(
            title: 'HeyGilli',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(),
            // A child's own device opens on their videos. Not a redirect
            // after the fact: the parent app must not be built even for one
            // frame, or the first thing on a tablet handed to a five-year-old
            // is the household's kid list.
            initialRoute: state.isKidDevice ? Routes.kid : Routes.parent,
            routes: {
              Routes.parent: (_) => const ParentRoot(),
              Routes.kid: (_) => const KidHomeScreen(),
            },
          ),
        );
      },
    );
  }
}

/// Sign-in until the gateway has a token, then the parent home — unless this
/// device belongs to a child.
///
/// The boot route already sends a child's device to their videos, but a route
/// is one line and every other way here would walk past it: a deep link, a
/// `pushNamedAndRemoveUntil` from anywhere, a future screen that pops to the
/// root. The guard is here because this is the one door, and what is behind it
/// is every child's digest, progress, watch history and limits.
///
/// A parent who typed the PIN is let through for as long as they are standing
/// there ([AppState.parentVisiting]); the next launch is the child's again.
class ParentRoot extends StatelessWidget {
  const ParentRoot({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.isKidDevice && !state.parentVisiting) {
      return const KidHomeScreen();
    }
    return state.signedIn ? const ParentHome() : const SignInScreen();
  }
}

class _Splash extends StatefulWidget {
  const _Splash();

  @override
  State<_Splash> createState() => _SplashState();
}

class _SplashState extends State<_Splash> {
  /// The gateway sleeps when nobody has used it, and the first request wakes
  /// it — around ten seconds of nothing. A spinner alone reads as a hang, and
  /// the person most likely to see it is the one opening the app for the first
  /// time. Said only after a few seconds, so a warm start never mentions it.
  bool _slow = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Same cream as the native launch background, so the handover from the
    // Android splash to Flutter is invisible rather than a colour flash.
    return Scaffold(
      backgroundColor: HgColors.cream,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            SvgPicture.asset('assets/gilli.svg', width: 140, height: 140),
            Text('HeyGilli', style: HgText.display(size: 36)),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: HgColors.mango,
              ),
            ),
            if (_slow)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  'Waking Gilli up. This takes a few seconds when nobody '
                  'has visited for a while.',
                  textAlign: TextAlign.center,
                  style: HgText.body(size: 14, color: HgColors.brown),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shown when HeyGilli cannot be reached at startup.
///
/// The alternative was falling back to canned data, which meant a parent on
/// bad wifi quietly browsing children and channels that were not theirs. An
/// honest dead end is better than a convincing wrong answer.
class _CannotConnect extends StatelessWidget {
  const _CannotConnect({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: HgColors.cream,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 14,
              children: [
                SvgPicture.asset('assets/gilli.svg', width: 120, height: 120),
                Text(
                  "Gilli can't connect",
                  textAlign: TextAlign.center,
                  style: HgText.display(size: 26, color: HgColors.ink),
                ),
                Text(
                  'Check the connection and try again. Nothing is shown until '
                  'your own kids and channels can be loaded.',
                  textAlign: TextAlign.center,
                  style: HgText.body(size: 16, color: HgColors.brown),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: onRetry,
                    child: Text(
                      'Try again',
                      style: HgText.body(size: 17, color: HgColors.white),
                    ),
                  ),
                ),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: HgText.body(size: 12, color: HgColors.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
