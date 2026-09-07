import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/parent_home.dart';
import 'package:heygilli/features/parent/parent_widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The parent app was a phone layout centered in a browser window: a 560px
/// column with empty cream on either side and a thumb-reach bottom tab bar on
/// a screen nobody was holding. Above [ParentScaffold.wideBreakpoint] it now
/// gets an actual desktop shape — a left rail instead of a bottom bar, and a
/// kid grid instead of a stack of full-width rows.
void main() {
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    await gateway.createKid(nickname: 'Abeeha', age: 6, languages: const ['en']);
    await gateway.createKid(nickname: 'Abu', age: 8, languages: const ['en']);
    await app.refreshKids();
  });

  Widget host() => ChangeNotifierProvider<AppState>.value(
    value: app,
    child: const MaterialApp(home: ParentHome()),
  );

  Future<void> resize(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('a phone-width window keeps the bottom tab bar, no rail', (
    tester,
  ) async {
    await resize(tester, 500);
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(ParentSidebar), findsNothing);
  });

  testWidgets('a desktop-width window shows the rail, not the bottom bar', (
    tester,
  ) async {
    await resize(tester, 1200);
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.byType(ParentSidebar), findsOneWidget);
    // Not just visually replaced: an invisible NavigationBar still eating
    // thumb-height at the bottom of a desktop window would be its own bug.
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('the rail actually switches tabs', (tester) async {
    await resize(tester, 1200);
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.text('Kids'), findsWidgets);
    // FakeGateway seeds a real inbox prompt, so the switch is checked by what
    // left rather than by an empty state: the kid grid is gone, replaced by
    // whatever the inbox has (here, an actual Curator prompt to decide on).
    expect(find.text('Abeeha'), findsOneWidget);

    await tester.tap(find.text('Inbox').last);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('Abeeha'), findsNothing);
    expect(find.text('Approve'), findsOneWidget);
  });

  testWidgets('two kids sit side by side once the window is wide enough', (
    tester,
  ) async {
    await resize(tester, 1200);
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.byType(GridView), findsOneWidget);
    final abeeha = tester.getTopLeft(find.text('Abeeha'));
    final abu = tester.getTopLeft(find.text('Abu'));
    expect(
      abeeha.dy,
      closeTo(abu.dy, 2),
      reason: 'two kids should be in the same row once there is room',
    );
  });

  testWidgets('one kid per row on a narrow window, unchanged', (
    tester,
  ) async {
    await resize(tester, 500);
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.byType(GridView), findsNothing);
    final abeeha = tester.getTopLeft(find.text('Abeeha'));
    final abu = tester.getTopLeft(find.text('Abu'));
    expect(abeeha.dy, lessThan(abu.dy - 10));
  });
}
