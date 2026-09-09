import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/inbox_screen.dart';
import 'package:heygilli/features/parent/parent_widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The inbox, one child at a time.
///
/// A household with two children had both their questions in one list, so a
/// parent deciding about one had to read past the other's — and deciding is
/// per child, because the same video can be right for one and not the other.
void main() {
  _height();

  late AppState app;
  late FakeGateway gateway;

  Future<void> setUpWith(WidgetTester tester, List<int> ages) async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await tester.runAsync(() async {
      await gateway.signInDev('parent');
      app = AppState(gateway: gateway, settings: await LocalSettings.load());
      var n = 0;
      for (final age in ages) {
        await gateway.createKid(
          nickname: ['Abeeha', 'Abu'][n++],
          age: age,
          languages: const ['en'],
        );
      }
      await app.refreshKids();
    });
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: InboxScreen())),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('one child means no tabs to choose between', (tester) async {
    await setUpWith(tester, [5]);
    expect(find.text('Everyone  3'), findsNothing);
    expect(find.textContaining('Abeeha  '), findsNothing);
    expect(find.text('Show it'), findsWidgets);
  });

  testWidgets('two children get a tab each, with a count', (tester) async {
    await setUpWith(tester, [5, 8]);

    expect(find.text('Everyone  3'), findsOneWidget);
    // Three demo prompts spread across two children: 2 and 1.
    expect(find.text('Abu  2'), findsOneWidget);
    expect(find.text('Abeeha  1'), findsOneWidget);
  });

  testWidgets('choosing a child shows only their questions', (tester) async {
    await setUpWith(tester, [5, 8]);
    final all = tester.widgetList(find.text('Show it')).length;

    await tester.tap(find.text('Abeeha  1'));
    await tester.pump();

    expect(
      tester.widgetList(find.text('Show it')).length,
      lessThan(all),
      reason: 'the other child\'s questions are still in the list',
    );

    // And back to everyone.
    await tester.tap(find.text('Everyone  3'));
    await tester.pump();
    expect(tester.widgetList(find.text('Show it')).length, all);
  });

  testWidgets('a card does not repeat the child once you are in their tab', (
    tester,
  ) async {
    await setUpWith(tester, [5, 8]);
    // Standing in "Everyone", each card says whose it is.
    expect(find.textContaining('For Abeeha'), findsWidgets);

    await tester.tap(find.text('Abeeha  1'));
    await tester.pump();
    expect(
      find.textContaining('For Abeeha'),
      findsNothing,
      reason: 'a line per card that says what the tab already says',
    );
  });
}

/// How much a parent has to scroll.
///
/// Each card was a heading, a thumbnail, a boxed sentence and a pair of
/// full-width buttons — most of a phone screen to answer one yes/no question,
/// so a dozen questions meant a dozen screens of scrolling.
void _height() {
  testWidgets('a card is short enough that several fit on one screen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final gateway = FakeGateway();
    late AppState app;
    await tester.runAsync(() async {
      await gateway.signInDev('parent');
      app = AppState(gateway: gateway, settings: await LocalSettings.load());
      await gateway.createKid(nickname: 'Abu', age: 8, languages: const ['en']);
      await app.refreshKids();
    });

    // A phone, held normally.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: InboxScreen())),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    final cards = find.byType(PCard);
    expect(tester.widgetList(cards), isNotEmpty);
    final height = tester.getSize(cards.first).height;
    expect(
      height,
      lessThan(130),
      reason: 'at ${height.round()}px a parent scrolls a screen per question',
    );
  });
}
