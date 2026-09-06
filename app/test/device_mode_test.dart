import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/speech.dart';
import 'package:heygilli/features/kid/home_screen.dart';
import 'package:heygilli/features/parent/parent_home.dart';
import 'package:heygilli/main.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whose device this is.
///
/// The parent app has never been behind the PIN — the PIN guards *leaving*
/// kid mode — so a tablet handed to a child opened on the household's kid
/// list: every child's digest, progress, watch history and limits, one tap
/// away, in front of a five-year-old.
void main() {
  late FakeGateway gateway;
  late LocalSettings settings;
  late Kid abeeha;
  late Kid abu;

  /// The three states the widget tests need, built here because everything
  /// that reaches FakeGateway has a real delay behind it and the clock inside
  /// testWidgets is the tester's: awaiting one from a test body never returns,
  /// and it fails as a five-minute hang rather than an error.
  late AppState onKidDevice;
  late AppState onKidDeviceWithParentVisiting;
  late AppState onParentDevice;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    settings = await LocalSettings.load();
    await settings.setPin('1234');
    final app = AppState(gateway: gateway, settings: settings);
    abeeha = await gateway.createKid(
      nickname: 'Abeeha',
      age: 6,
      languages: const ['en'],
    );
    abu = await gateway.createKid(
      nickname: 'Abu',
      age: 8,
      languages: const ['en'],
    );
    await app.refreshKids();

    onParentDevice = await _launch(gateway, settings);

    await app.setDeviceKid(abeeha);
    onKidDevice = await _launch(gateway, settings);
    onKidDeviceWithParentVisiting = await _launch(gateway, settings)
      ..leaveKidMode();
    await app.setDeviceKid(null);
  });

  Future<AppState> freshApp() => _launch(gateway, settings);

  /// The kid home starts a gateway call as soon as it builds, and FakeGateway's
  /// lag is a real delay: a bare pump leaves it pending and the test fails on
  /// the timer rather than the assertion.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Widget host(AppState app) => MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<GilliVoice>(create: (_) => _SilentVoice()),
    ],
    child: const MaterialApp(home: ParentRoot()),
  );

  test('a device belongs to nobody until a parent says so', () async {
    final app = await freshApp();
    expect(app.isKidDevice, isFalse);
    expect(app.deviceKid, isNull);
  });

  test('giving it to a child is remembered across a restart', () async {
    final app = await freshApp();
    await app.setDeviceKid(abeeha);

    // A new AppState over the same stored settings: the next app launch.
    final relaunched = await freshApp();
    expect(relaunched.isKidDevice, isTrue);
    expect(relaunched.deviceKid?.id, abeeha.id);
    expect(
      relaunched.kidMode,
      isTrue,
      reason: 'a child\'s device must come up already in kid mode',
    );
    expect(relaunched.activeKid?.id, abeeha.id);
  });

  test('handing it to the other child takes it from the first', () async {
    final app = await freshApp();
    await app.setDeviceKid(abeeha);
    await app.setDeviceKid(abu);
    expect((await freshApp()).deviceKid?.id, abu.id);
  });

  test('taking it back makes it a parent device again', () async {
    final app = await freshApp();
    await app.setDeviceKid(abeeha);
    await app.setDeviceKid(null);
    expect((await freshApp()).isKidDevice, isFalse);
  });

  test('a device left to a deleted child is not stuck', () async {
    // Otherwise the tablet boots forever into kid mode for nobody, and the
    // only screen that could fix it is the one it will not show.
    await settings.setKidDeviceId('kid_that_no_longer_exists');
    final app = await freshApp();
    expect(app.isKidDevice, isFalse);
    expect(app.deviceKid, isNull);
  });

  testWidgets('the parent app is not reachable on a child\'s device', (
    tester,
  ) async {
    // The guard that matters. The boot route sends this device to the videos,
    // but a route is one line: a deep link, or any pushNamedAndRemoveUntil to
    // the root, walks straight past it. This asks at the door instead.
    await tester.pumpWidget(host(onKidDevice));
    await settle(tester);

    expect(find.byType(KidHomeScreen), findsOneWidget);
    expect(find.byType(ParentHome), findsNothing);
  });

  testWidgets('a parent who typed the PIN gets through', (tester) async {
    // leaveKidMode is what the PIN gate calls on the way out.
    await tester.pumpWidget(host(onKidDeviceWithParentVisiting));
    await tester.pump();

    expect(find.byType(ParentHome), findsOneWidget);
  });

  testWidgets('and the visit ends, rather than handing the device over', (
    tester,
  ) async {
    expect(onKidDeviceWithParentVisiting.parentVisiting, isTrue);

    // The next launch is the child's again: a visit is not a change of owner.
    expect(onKidDevice.parentVisiting, isFalse);
    await tester.pumpWidget(host(onKidDevice));
    await settle(tester);
    expect(find.byType(KidHomeScreen), findsOneWidget);
  });

  test('signing out ends the session on this device', () async {
    // There was no way to do this at all: GoogleAuth.signOut existed and
    // nothing called it, so a parent signed in on the wrong account was stuck.
    final app = await freshApp();
    expect(app.signedIn, isTrue);
    expect(app.kids, isNotEmpty);

    await app.signOut();

    expect(app.signedIn, isFalse, reason: 'the gateway kept its token');
    expect(settings.token, isNull, reason: 'the token survived on disk');
    expect(app.kids, isEmpty, reason: 'another parent could see the children');
    expect(app.kidMode, isFalse);
  });

  test('signing out does not hand a child device back to the child', () async {
    // The dangerous one. If signing out cleared the device owner, a child
    // whose parent signed out would get the parent app on their own tablet.
    final app = await freshApp();
    await app.setDeviceKid(abeeha);
    await app.signOut();

    expect(app.settings.kidDeviceId, abeeha.id);
    expect((await freshApp()).deviceKid?.id, abeeha.id);
  });

  test('signing out leaves the PIN alone', () async {
    // Otherwise the way back into the parent app is gone with it.
    final app = await freshApp();
    await app.signOut();
    expect(app.settings.pin, '1234');
  });

  testWidgets('a child device still offers the way back to a parent', (
    tester,
  ) async {
    // The control a parent hunts for, and the one they could not find. It has
    // to be present and tappable however wide the window is: a lock in the
    // far corner of a two-thousand-pixel screen is not an affordance.
    tester.view.physicalSize = const Size(2000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(onKidDevice));
    await settle(tester);

    final lock = find.byTooltip('Parent');
    expect(lock, findsOneWidget, reason: 'no way back to the parent app');
    expect(
      tester.getSize(lock).shortestSide,
      greaterThanOrEqualTo(48),
      reason: 'below the minimum touch target',
    );
  });

  testWidgets('a parent device still opens on the household', (tester) async {
    await tester.pumpWidget(host(onParentDevice));
    await tester.pump();
    expect(find.byType(ParentHome), findsOneWidget);
    expect(find.byType(KidHomeScreen), findsNothing);
  });
}

/// One app launch over the stored settings, exactly as `AppState.bootstrap`
/// does it: read the kids, then enter kid mode if this device has an owner.
Future<AppState> _launch(FakeGateway gateway, LocalSettings settings) async {
  final app = AppState(gateway: gateway, settings: settings);
  await app.refreshKids();
  final owner = app.deviceKid;
  if (owner != null) app.enterKidMode(owner);
  return app;
}

/// Gilli with the sound off: a real GilliVoice reaches for a platform channel
/// and a widget test waits on it forever.
class _SilentVoice extends GilliVoice {
  @override
  Future<void> say({
    required String url,
    String? fallbackText,
    String language = 'en',
    bool slow = false,
  }) async {}
}
