import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/kid_detail_screen.dart';
import 'package:heygilli/features/parent/parent_home.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The first ten minutes, for a parent who has just signed in.
///
/// Every one of these was a dead end. The only prominent button on an empty
/// app sent the parent to Google to request a Takeout export; adding a child
/// returned them to the list they were already looking at; and the child's
/// page opened on an analytics tab that is empty by definition for a child
/// added a minute ago, with the one step that has to happen next — approving
/// channels, without which kid mode shows nothing — behind the third tab.
void main() {
  late AppState app;
  late FakeGateway gateway;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    await app.refreshKids();
  });

  Future<void> pumpWide(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: home),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// Which tab is actually selected, rather than which tab's content happens
  /// to be built: a TabBarView builds its neighbours, so asserting on text
  /// alone passes whichever tab is open.
  int selectedTab(WidgetTester tester) =>
      tester.widget<TabBar>(find.byType(TabBar)).controller!.index;

  testWidgets('a child with no channels opens on Channels', (tester) async {
    late Kid kid;
    await tester.runAsync(() async {
      kid = await gateway.createKid(
        nickname: 'Abu',
        age: 8,
        languages: const ['en'],
      );
      // The demo gateway hands every new child two sample channels so its
      // screens have something to show. A real one does not, and this is the
      // real one's new child.
      for (final c in await gateway.channels(kid.id)) {
        await gateway.removeChannel(kid.id, c.id);
      }
      await app.refreshKids();
    });
    await pumpWide(tester, KidDetailScreen(kid: kid));

    expect(selectedTab(tester), 2);
    expect(find.text('Suggest channels for Abu'), findsOneWidget);
  });

  testWidgets('a child who is watching still opens on how it is going', (
    tester,
  ) async {
    late Kid kid;
    await tester.runAsync(() async {
      kid = await gateway.createKid(
        nickname: 'Abu',
        age: 8,
        languages: const ['en'],
      );
      // Left with the demo gateway's sample channels: a child who watches.
      await app.refreshKids();
    });
    await pumpWide(tester, KidDetailScreen(kid: kid));

    expect(selectedTab(tester), 0);
  });

  testWidgets('the empty app leads with adding a kid, not with Takeout', (
    tester,
  ) async {
    await pumpWide(tester, const ParentHome());

    expect(find.text('No kids yet'), findsOneWidget);
    // The step every household takes is the filled button; the export, which
    // means leaving for Google and waiting on an email, is a quiet link.
    final add = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Add a kid'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(add.onPressed, isNotNull);
    expect(
      find.ancestor(
        of: find.text('Already use YouTube Kids? Import a profile'),
        matching: find.byType(TextButton),
      ),
      findsOneWidget,
    );
  });

  testWidgets('adding a kid carries on into that kid, on Channels', (
    tester,
  ) async {
    await pumpWide(tester, const ParentHome());

    await tester.tap(find.text('Add a kid'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Abu');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save kid'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Not back on the list they were already looking at. Which tab it lands
    // on is the previous test's business; the demo gateway gives its new
    // children channels, so this one would land on "How it is going".
    expect(find.byType(KidDetailScreen), findsOneWidget);
  });
}
