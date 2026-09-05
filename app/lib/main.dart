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
  /// Probes the gateway (2 s), falls back to the in-app demo, and loads the
  /// bundled pick-it icon library, all before the first screen.
  late final Future<(AppState, IconLibrary)> _boot = () async {
    final results = await Future.wait([
      AppState.bootstrap(),
      IconLibrary.load(),
    ]);
    return (results[0] as AppState, results[1] as IconLibrary);
  }();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _boot,
      builder: (context, snap) {
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
            initialRoute: Routes.parent,
            routes: {
              Routes.parent: (_) => const _ParentRoot(),
              Routes.kid: (_) => const KidHomeScreen(),
            },
          ),
        );
      },
    );
  }
}

/// Sign-in until the gateway has a token, then the parent home.
class _ParentRoot extends StatelessWidget {
  const _ParentRoot();

  @override
  Widget build(BuildContext context) {
    final signedIn = context.select<AppState, bool>((s) => s.signedIn);
    return signedIn ? const ParentHome() : const SignInScreen();
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
          ],
        ),
      ),
    );
  }
}
