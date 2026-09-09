import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/speech.dart';
import 'package:heygilli/features/parent/sign_in_screen.dart';
import 'package:heygilli/main.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The sign-in screen at both widths.
///
/// A phone gets one column. A browser window gets the pitch beside the card
/// rather than a phone screen stranded in the middle of it.
void main() {
  late LocalSettings settings;
  late FakeGateway gateway;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await LocalSettings.load();
    gateway = FakeGateway();
  });

  Widget host(AppState app) => MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<GilliVoice>(create: (_) => _SilentVoice()),
    ],
    child: const MaterialApp(home: ParentRoot()),
  );

  Future<void> sized(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('a signed-out parent lands on sign-in, nothing in front of it', (
    tester,
  ) async {
    // There used to be an intro here. The landing page says all of it now,
    // and better, so the app opens on the thing it is asking for.
    await sized(tester, 1200);
    await tester.pumpWidget(
      host(AppState(gateway: gateway, settings: settings)),
    );

    expect(find.byType(SignInScreen), findsOneWidget);
  });

  testWidgets('both doors are offered on a wide window', (tester) async {
    await sized(tester, 1200);
    await tester.pumpWidget(
      host(AppState(gateway: gateway, settings: settings)),
    );

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Set up without Google'), findsOneWidget);
    // Both doors exist in either layout; the tight "Sign in" card heading
    // exists only in the wide split panel, so this is what actually tells
    // the two layouts apart rather than just checking the buttons are there.
    expect(find.text('Sign in'), findsOneWidget);
    expect(
      find.text('A buddy who watches YouTube with your kid'),
      findsNothing,
    );
    expect(
      find.text('A buddy who watches YouTube with your kid.'),
      findsOneWidget,
    );
  });

  testWidgets('a narrow window stays a single phone column', (tester) async {
    await sized(tester, 500);
    await tester.pumpWidget(
      host(AppState(gateway: gateway, settings: settings)),
    );

    expect(find.byType(SignInScreen), findsOneWidget);
    expect(
      find.text('Sign in'),
      findsNothing,
      reason: 'the tight card heading is wide-only',
    );
    expect(
      find.text('A buddy who watches YouTube with your kid'),
      findsOneWidget,
    );
  });
}

class _SilentVoice extends GilliVoice {
  @override
  Future<void> say({
    required String url,
    String? fallbackText,
    String language = 'en',
    bool slow = false,
  }) async {}
}
