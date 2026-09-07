import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/speech.dart';
import 'package:heygilli/features/kid/home_screen.dart';
import 'package:heygilli/features/parent/intro_screen.dart';
import 'package:heygilli/features/parent/sign_in_screen.dart';
import 'package:heygilli/main.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What HeyGilli is, answered before a parent is asked to hand over their
/// child's YouTube.
void main() {
  late LocalSettings settings;
  late FakeGateway gateway;

  /// Built here, not inside testWidgets: everything that reaches FakeGateway
  /// has a real delay behind it, and awaiting one from a test body never
  /// returns — it fails as a ten-minute hang rather than an error.
  late AppState onKidDevice;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await LocalSettings.load();
    gateway = FakeGateway();

    // Its own gateway: signing in on the shared one would put every other
    // test past the sign-in screen, which is the thing they are checking.
    final kidGateway = FakeGateway();
    await kidGateway.signInDev('parent');
    final seed = AppState(gateway: kidGateway, settings: settings);
    final kid = await kidGateway.createKid(
      nickname: 'Abeeha',
      age: 6,
      languages: const ['en'],
    );
    await seed.refreshKids();
    await seed.setDeviceKid(kid);

    onKidDevice = AppState(gateway: kidGateway, settings: settings);
    await onKidDevice.refreshKids();
    onKidDevice.enterKidMode(kid);
    // AppState reads the device owner from settings through a `late` field,
    // and `late` is lazy: without touching it here it would first be read
    // after the line below, by which point the device belongs to nobody.
    expect(onKidDevice.isKidDevice, isTrue);

    // Back to a plain device for every other test in this file.
    await seed.setDeviceKid(null);
  });

  Widget host(AppState app) => MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<GilliVoice>(create: (_) => _SilentVoice()),
    ],
    child: const MaterialApp(home: ParentRoot()),
  );

  Future<void> wide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// Tall enough to render everything, but under the desktop breakpoint: the
  /// phone-paged intro is what several tests here actually mean to exercise.
  Future<void> narrow(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('a stranger is told what this is before being asked to sign in', (
    tester,
  ) async {
    await wide(tester);
    await tester.pumpWidget(host(AppState(gateway: gateway, settings: settings)));

    expect(find.byType(IntroScreen), findsOneWidget);
    expect(find.byType(SignInScreen), findsNothing);
    expect(find.text('A buddy who watches along'), findsOneWidget);
  });

  testWidgets('skipping goes straight to sign-in and does not come back', (
    tester,
  ) async {
    await wide(tester);
    final app = AppState(gateway: gateway, settings: settings);
    await tester.pumpWidget(host(app));

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(find.byType(SignInScreen), findsOneWidget);
    expect(app.introSeen, isTrue);
    expect(settings.introSeen, isTrue, reason: 'it will reappear next launch');
  });

  testWidgets('reading it through reaches sign-in on the last panel', (
    tester,
  ) async {
    await narrow(tester);
    await tester.pumpWidget(host(AppState(gateway: gateway, settings: settings)));

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // Last panel offers to finish rather than to go on.
    expect(find.text('Next'), findsNothing);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(find.byType(SignInScreen), findsOneWidget);
  });

  testWidgets('a parent who has seen it never sees it again', (tester) async {
    await wide(tester);
    await settings.setIntroSeen();
    await tester.pumpWidget(host(AppState(gateway: gateway, settings: settings)));

    expect(find.byType(IntroScreen), findsNothing);
    expect(find.byType(SignInScreen), findsOneWidget);
  });

  testWidgets('it never appears on a child\'s device', (tester) async {
    // The kid-device guard has to win: a tablet handed to a five-year-old
    // opens on their videos, not on a pitch written for their parent.
    await wide(tester);
    await tester.pumpWidget(host(onKidDevice));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.byType(IntroScreen), findsNothing);
    expect(find.byType(KidHomeScreen), findsOneWidget);
  });

  testWidgets('on a wide window all three panels show at once, unpaged', (
    tester,
  ) async {
    await wide(tester);
    await tester.pumpWidget(host(AppState(gateway: gateway, settings: settings)));

    // Nothing to page to when everything is already on screen.
    expect(find.text('Next'), findsNothing);
    expect(find.text('A buddy who watches along'), findsOneWidget);
    expect(find.text('You decide what is allowed'), findsOneWidget);
    expect(find.text('Watching becomes talking'), findsOneWidget);

    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(find.byType(SignInScreen), findsOneWidget);
  });

  testWidgets('a narrow window still pages one panel at a time', (
    tester,
  ) async {
    await narrow(tester);
    await tester.pumpWidget(host(AppState(gateway: gateway, settings: settings)));

    expect(find.text('A buddy who watches along'), findsOneWidget);
    expect(find.text('You decide what is allowed'), findsNothing);
  });

  testWidgets('sign-in offers both doors on a wide window too', (
    tester,
  ) async {
    await wide(tester);
    await settings.setIntroSeen();
    await tester.pumpWidget(host(AppState(gateway: gateway, settings: settings)));

    expect(find.byType(SignInScreen), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Set up without Google'), findsOneWidget);
    // Both doors exist in either layout; the tight "Sign in" card heading
    // exists only in the wide split panel, so this is what actually tells
    // the two layouts apart rather than just checking the buttons are there.
    expect(find.text('Sign in'), findsOneWidget);
    // The pitch is long-form beside the card on wide, not repeated above it.
    expect(find.text('A buddy who watches YouTube with your kid'), findsNothing);
    expect(
      find.text('A buddy who watches YouTube with your kid.'),
      findsOneWidget,
    );
  });

  testWidgets('sign-in stays a single phone column on a narrow window', (
    tester,
  ) async {
    await narrow(tester);
    await settings.setIntroSeen();
    await tester.pumpWidget(host(AppState(gateway: gateway, settings: settings)));

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
