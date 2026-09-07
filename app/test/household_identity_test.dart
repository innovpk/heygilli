import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/sign_in_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How a household is identified when nobody signs in to anything.
///
/// There is no account: the household is a name generated on the device and
/// remembered there. The server hashes it into the household id, so the
/// properties below are what stand between one family and another.
void main() {
  late LocalSettings settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await LocalSettings.load();
  });

  Widget host(AppState app) => ChangeNotifierProvider<AppState>.value(
    value: app,
    child: const MaterialApp(home: SignInScreen()),
  );

  test('the household name is generated, not a name a person would pick', () async {
    // The server hashes this into the household id. "test" or a first name is
    // a household the next person who picks it walks straight into.
    final name = await settings.ensureTrialHousehold();
    expect(name, startsWith('trial-'));
    expect(
      name.length,
      greaterThanOrEqualTo(38),
      reason: 'too short to be unguessable',
    );
    expect(RegExp(r'^trial-[0-9a-f]{32}$').hasMatch(name), isTrue);
  });

  test('coming back lands in the same household, not a new empty one', () async {
    final first = await settings.ensureTrialHousehold();
    expect(await settings.ensureTrialHousehold(), first);

    // A fresh LocalSettings over the same storage: the next app launch.
    expect((await LocalSettings.load()).trialHousehold, first);
  });

  test('a different device is a different household', () async {
    final mine = await settings.ensureTrialHousehold();
    SharedPreferences.setMockInitialValues({});
    final theirs = await (await LocalSettings.load()).ensureTrialHousehold();
    expect(theirs, isNot(mine));
  });

  test('nothing is stored until the door is actually used', () async {
    expect(settings.trialHousehold, isNull);
  });

  testWidgets('the door is present and signs the parent in', (tester) async {
    // Tall enough that the whole screen is laid out: the door sits below the
    // Google button and the default 600pt surface leaves it off the bottom.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = AppState(gateway: FakeGateway(), settings: settings);
    expect(app.signedIn, isFalse);

    await tester.pumpWidget(host(app));
    final door = find.text('Set up your household');
    expect(door, findsOneWidget, reason: 'no way into the app at all');

    await tester.ensureVisible(door);
    await tester.tap(door);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(app.signedIn, isTrue);
    expect(settings.trialHousehold, isNotNull);
    expect(
      settings.parentName,
      isNull,
      reason: 'the parent home would greet "Hi trial-3c994baf52eab4ec..."',
    );
  });

  testWidgets('the only way in is never disabled', (tester) async {
    // Nothing gates it — no client id, no network check, no account. If this
    // is ever disabled the app has no entrance at all.
    final app = AppState(gateway: FakeGateway(), settings: settings);
    await tester.pumpWidget(host(app));

    final door = find.widgetWithText(FilledButton, 'Set up your household');
    expect(door, findsOneWidget);
    expect(tester.widget<FilledButton>(door).onPressed, isNotNull);
  });
}
