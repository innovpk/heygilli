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
  _pushedScreenTests();
  _railGeometry();

  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    await gateway.createKid(
      nickname: 'Abeeha',
      age: 6,
      languages: const ['en'],
    );
    await gateway.createKid(nickname: 'Abu', age: 8, languages: const ['en']);
    await gateway.createKid(nickname: 'Zara', age: 9, languages: const ['en']);
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

  // Every child's name is on screen twice once the rail exists — once in the
  // rail, once on their card. These tests are about where the cards sit, so
  // they ask the grid rather than the whole tree.
  Finder inGrid(String name) =>
      find.descendant(of: find.byType(GridView), matching: find.text(name));

  testWidgets('a phone-width window keeps the bottom tab bar, no rail', (
    tester,
  ) async {
    await resize(tester, 500);
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(HouseholdSidebar), findsNothing);
  });

  testWidgets('a desktop-width window shows the rail, not the bottom bar', (
    tester,
  ) async {
    await resize(tester, 1200);
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.byType(HouseholdSidebar), findsOneWidget);
    // Not just visually replaced: an invisible NavigationBar still eating
    // thumb-height at the bottom of a desktop window would be its own bug.
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('the rail actually switches tabs', (tester) async {
    await resize(tester, 1200);
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.text('Kids'), findsWidgets);
    // Twice: once on her card in the grid, once in the rail, which lists every
    // child on the household whatever page is open.
    expect(find.text('Abeeha'), findsNWidgets(2));

    await tester.tap(find.text('Inbox').last);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Her card has gone with the grid; her name has not, because the rail is
    // the frame and not part of the page. That is the whole point of it.
    expect(find.text('Abeeha'), findsOneWidget);
    // The inbox, whatever is in it. Counting the cards tied this test to how
    // many prompts the demo happens to ship, which is not what it is about.
    expect(find.text('Approve'), findsWidgets);
  });

  testWidgets('two kids sit side by side once the window is wide enough', (
    tester,
  ) async {
    // Wide enough to activate the sidebar layout (>=900) but, after the
    // sidebar and padding are subtracted, still short of the three-column
    // threshold — this is what actually exercises the two-column tier
    // specifically rather than the three-column one.
    await resize(tester, 1000);
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.byType(GridView), findsOneWidget);
    final abeeha = tester.getTopLeft(inGrid('Abeeha'));
    final abu = tester.getTopLeft(inGrid('Abu'));
    expect(
      abeeha.dy,
      closeTo(abu.dy, 2),
      reason: 'two kids should be in the same row once there is room',
    );
  });

  testWidgets('three kids sit in one row on a genuinely wide window', (
    tester,
  ) async {
    // The regression this guards: ParentScaffold's own wide-mode cap left
    // less room than the three-column breakpoint needed, so that tier could
    // never be reached no matter how wide the browser window actually was.
    // 2000, not 1200 — this has to exceed ParentScaffold's cap plus the
    // sidebar plus the grid's own padding, not just clear the breakpoint
    // number read in isolation.
    await resize(tester, 2000);
    await tester.pumpWidget(host());
    await tester.pump();

    final abeeha = tester.getTopLeft(inGrid('Abeeha'));
    final abu = tester.getTopLeft(inGrid('Abu'));
    final zara = tester.getTopLeft(inGrid('Zara'));
    expect(abeeha.dy, closeTo(abu.dy, 2));
    expect(abeeha.dy, closeTo(zara.dy, 2));
    expect(
      zara.dx,
      greaterThan(abu.dx),
      reason: 'three kids in one row, left to right',
    );
  });

  testWidgets('one kid per row on a narrow window, unchanged', (tester) async {
    await resize(tester, 500);
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.byType(GridView), findsNothing);
    final abeeha = tester.getTopLeft(find.text('Abeeha'));
    final abu = tester.getTopLeft(find.text('Abu'));
    expect(abeeha.dy, lessThan(abu.dy - 10));
  });
}

/// A screen pushed on top of the tab root — kid detail, digest, policy — is
/// most of the app, and every one of them was a 560px phone column in the
/// middle of whatever window the parent had open. The doc comment on
/// [ParentScaffold.sidebar] said they got "the same wide column with no rail";
/// the code ANDed the width test with `sidebar != null`, so they did not.
void _pushedScreenTests() {
  Future<void> pumpScaffold(WidgetTester tester, Size size) async {
    // Built through runAsync: the fake gateway uses a real delay, and
    // awaiting one inside `testWidgets` waits on a clock only `pump` moves.
    late AppState app;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      final gateway = FakeGateway();
      await gateway.signInDev('parent');
      app = AppState(gateway: gateway, settings: await LocalSettings.load());
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(
          home: ParentScaffold(
            title: 'Abeeha',
            body: SizedBox(height: 200, child: Text('content')),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a pushed screen uses the width it has', (tester) async {
    await pumpScaffold(tester, const Size(1600, 1000));

    final width = tester.getRect(find.text('content')).width;
    expect(
      width,
      greaterThan(900),
      reason: 'a phone column in a 1600px window is the bug being fixed',
    );
  });

  testWidgets('a phone still gets one readable column', (tester) async {
    await pumpScaffold(tester, const Size(420, 900));
    expect(tester.getRect(find.text('content')).width, lessThan(500));
  });
}

/// Where the navigation sits.
///
/// The rail used to live inside a rounded card floating in the middle of the
/// cream, which made the navigation read as part of the page rather than the
/// frame around it, and left a band of empty ground down both sides of a wide
/// window.
void _railGeometry() {
  testWidgets('the rail owns the left edge, corner to corner', (tester) async {
    late AppState app;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      final gateway = FakeGateway();
      await gateway.signInDev('parent');
      app = AppState(gateway: gateway, settings: await LocalSettings.load());
      await gateway.createKid(nickname: 'Abu', age: 8, languages: const ['en']);
      await app.refreshKids();
    });
    const size = Size(1600, 1000);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: ParentHome()),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    final rail = tester.getRect(find.byType(HouseholdSidebar));
    expect(rail.left, 0, reason: 'the rail is inset from the window edge');
    expect(rail.top, 0, reason: 'the rail does not start at the top');
    expect(
      rail.height,
      size.height,
      reason:
          'the rail stops short of the bottom of the window: got \${rail.height}',
    );
  });
}
