import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/takeout_import_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Takeout import screen, in the state every household starts in.
///
/// A parent's first import happens before there is a single kid to import
/// into. That case had the primary button reading "Pick a kid first" with
/// nothing to pick, while the only working control was a small pill above it.
void main() {
  late FakeGateway gateway;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    // A brand new household: FakeGateway seeds none, which is the real shape
    // of a parent who has just signed in with Google for the first time.
    expect(app.kids, isEmpty);
  });

  Widget host() => ChangeNotifierProvider<AppState>.value(
    value: app,
    child: const MaterialApp(home: TakeoutImportScreen()),
  );

  /// Both screens here are long lists, and a ListView does not build what is
  /// off-screen — a phone-sized test surface hides the very controls under
  /// test. Tall enough that the whole card is real.
  Future<void> openSample(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pump();
    await tester.tap(find.text('Use a sample export (demo)'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('the first import never tells a parent to pick a kid', (
    tester,
  ) async {
    await openSample(tester);

    // There is nothing to pick from, so nothing may ask them to pick.
    expect(find.text('Pick a kid first'), findsNothing);
    expect(find.text('IMPORT INTO'), findsNothing);
  });

  testWidgets('it offers to make the child and bring the channels at once', (
    tester,
  ) async {
    await openSample(tester);

    // Named after the profile, so a parent knows which card they are on.
    final add = find.textContaining(RegExp(r'^Add .+ and import \d+$'));
    expect(add, findsWidgets);
    expect(
      tester
          .widget<FilledButton>(
            find.ancestor(of: add.first, matching: find.byType(FilledButton)),
          )
          .onPressed,
      isNotNull,
      reason: 'the only route out of an empty household must be live',
    );
  });
}
