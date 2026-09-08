import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/setup_review_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Deciding what a child will see, while setting them up.
///
/// Approving channels approves channels; the uploads are read one at a time
/// afterwards, and only the ones the Curator could not settle used to reach
/// the parent — in the inbox, later, in a different part of the app. So the
/// child's screen stayed empty and the list the parent eventually found never
/// said what it had not asked about.
void main() {
  late AppState app;
  late FakeGateway gateway;
  late Kid kid;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    kid = await gateway.createKid(
      nickname: 'Abu',
      age: 8,
      languages: const ['en'],
    );
    await app.refreshKids();
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: SetupReviewScreen(kid: kid)),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Finder switchFinder(WidgetTester tester, String title) => find.descendant(
    of: find.ancestor(of: find.text(title), matching: find.byType(Row)).first,
    matching: find.byType(Switch),
  );

  Switch switchFor(WidgetTester tester, String title) =>
      tester.widget<Switch>(switchFinder(tester, title));

  testWidgets('everything screened is shown, not only the questions', (
    tester,
  ) async {
    await open(tester);

    // The Curator's reason for each, including the ones it settled itself.
    expect(
      find.textContaining('Explains how volcanoes work'),
      findsOneWidget,
    );
    expect(find.textContaining('A sponsor read in the middle'), findsOneWidget);
    expect(find.textContaining('A live stream'), findsOneWidget);
  });

  testWidgets('the verdict is the starting position, not the final one', (
    tester,
  ) async {
    await open(tester);

    // Approved starts on, hidden starts off — a parent who agrees with all of
    // it has nothing to do but confirm.
    expect(switchFor(tester, 'Every Kind of Volcano').value, isTrue);
    expect(switchFor(tester, 'Five Little Ducks').value, isFalse);
  });

  testWidgets('what it was judged on is on the card', (tester) async {
    await open(tester);

    expect(find.text('Read: what is said in the video'), findsWidgets);
    expect(find.text('Read: the title and description only'), findsOneWidget);
  });

  testWidgets('the count on the button follows the switches', (tester) async {
    await open(tester);
    expect(find.text('Allow 2 videos'), findsOneWidget);

    await tester.tap(find.text('Allow all'));
    await tester.pumpAndSettle();

    expect(find.text('Allow 4 videos'), findsOneWidget);
  });

  testWidgets('a refresh never moves a switch the parent has set', (
    tester,
  ) async {
    // Screening takes minutes, so the list is polled while the parent is
    // reading it. Seeding every arriving item would quietly undo a decision
    // they had already made, and they would only find out from the count.
    final still = _StillScreeningGateway(gateway);
    app = AppState(gateway: still, settings: await LocalSettings.load());
    await open(tester);

    await tester.tap(switchFinder(tester, 'Every Kind of Volcano'));
    // Not pumpAndSettle: the run never finishes, so the screen keeps polling
    // and there is no settled frame to wait for.
    await tester.pump(const Duration(milliseconds: 400));
    expect(switchFor(tester, 'Every Kind of Volcano').value, isFalse);

    // Past the poll interval, so a refresh has certainly landed.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 3));
    }

    expect(switchFor(tester, 'Every Kind of Volcano').value, isFalse);
  });

  testWidgets('confirming sends both answers, and they stick', (tester) async {
    await open(tester);

    // Turn down one the Curator approved: the parent disagreeing with it is
    // the whole point of showing them what it decided.
    await tester.tap(switchFinder(tester, 'Every Kind of Volcano'));
    await tester.pumpAndSettle();
    expect(find.text('Allow 1 video'), findsOneWidget);

    await tester.tap(find.text('Allow 1 video'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    late Map<String, String> byId;
    await tester.runAsync(() async {
      byId = {
        for (final i in (await gateway.reviewQueue(kid.id)).items)
          i.video.title: i.status,
      };
    });
    expect(byId['Every Kind of Volcano'], 'hide');
    expect(byId['How Ears Let Us Hear the World'], 'approve');
  });
}


/// A gateway whose run never finishes, so the screen keeps polling.
class _StillScreeningGateway extends FakeGateway {
  _StillScreeningGateway(this.inner);
  final FakeGateway inner;

  @override
  Future<ReviewQueue> reviewQueue(String kidId) async {
    final q = await inner.reviewQueue(kidId);
    return ReviewQueue(
      items: q.items,
      screened: q.items.length,
      expected: q.items.length + 5,
      channels: q.channels,
    );
  }

  @override
  Future<void> reviewDecide(
    String kidId, {
    List<String> approve = const [],
    List<String> hide = const [],
  }) => inner.reviewDecide(kidId, approve: approve, hide: hide);
}
