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
///
/// The list is split into two tabs — what the child will see, and what they
/// will not — and each card leads with short tags a parent can skim, with the
/// screening's reason one tap away behind "Why".
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

  /// Switches tab by its label, whatever the count beside it says.
  Future<void> tab(WidgetTester tester, String name) async {
    await tester.tap(find.textContaining('$name ('));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Finder switchFinder(WidgetTester tester, String title) => find.descendant(
    of: find.ancestor(of: find.text(title), matching: find.byType(Row)).first,
    matching: find.byType(Switch),
  );

  Switch switchFor(WidgetTester tester, String title) =>
      tester.widget<Switch>(switchFinder(tester, title));

  testWidgets('every suggestion is on one of the two tabs', (tester) async {
    await open(tester);

    // What the Curator approved starts under Shown...
    expect(find.text('Every Kind of Volcano'), findsOneWidget);
    expect(find.text('How Ears Let Us Hear the World'), findsOneWidget);
    expect(find.text('Twinkle Twinkle Little Star'), findsNothing);

    // ...and what it asked about starts under Hidden, switched off.
    await tab(tester, 'Hidden');
    expect(find.text('Twinkle Twinkle Little Star'), findsOneWidget);
    expect(find.text('Every Kind of Volcano'), findsNothing);
  });

  testWidgets('the tags are there to skim, the reason is one tap away', (
    tester,
  ) async {
    await open(tester);

    // Tags without opening anything.
    expect(find.text('Volcanoes'), findsOneWidget);
    // The paragraph is folded away until asked for.
    expect(find.textContaining('Explains how volcanoes work'), findsNothing);

    await tester.tap(find.text('Why').first);
    await tester.pump();
    expect(find.textContaining('Explains how volcanoes work'), findsOneWidget);
    expect(find.text('Hide why'), findsOneWidget);
  });

  testWidgets('a question the Curator raised says so, and says why', (
    tester,
  ) async {
    await open(tester);
    await tab(tester, 'Hidden');

    // What gave it pause, as a tag, and that it was left to the parent.
    expect(find.text('Asked you'), findsOneWidget);
    expect(find.text('Sponsor'), findsOneWidget);

    await tester.tap(find.text('Why').first);
    await tester.pump();
    expect(
      find.textContaining('A sponsor named in the description'),
      findsOneWidget,
    );
  });

  testWidgets('what Gilli kept back is listed under Hidden, and says so', (
    tester,
  ) async {
    // It used to sit behind a link under the Hidden tab, which is one tap
    // away from the tab that was already called Hidden.
    await open(tester);
    expect(find.text('Five Little Ducks'), findsNothing);

    await tab(tester, 'Hidden');
    expect(find.text('Five Little Ducks'), findsOneWidget);
    expect(find.text('Kept by Gilli'), findsOneWidget);
    expect(find.text('Live stream'), findsOneWidget);
    expect(switchFor(tester, 'Five Little Ducks').value, isFalse);
  });

  testWidgets('"Allow all" never lets through what Gilli kept back', (
    tester,
  ) async {
    // "Allow all" meaning "allow the things we kept back too" is how a
    // two-hour film reached a seven-year-old's science list.
    await open(tester);
    await tester.tap(find.text('Allow all'));
    await tester.pumpAndSettle();

    await tab(tester, 'Hidden');
    expect(find.text('Five Little Ducks'), findsOneWidget);
    expect(switchFor(tester, 'Five Little Ducks').value, isFalse);
  });

  testWidgets('a ceiling that could not run on some of them says so', (
    tester,
  ) async {
    // A length is only knowable through the parent's own Google grant. Where
    // it was not, the ceiling skipped that video rather than judging it on a
    // number nobody has, and a parent told nothing reads the ceiling as a
    // promise it cannot keep.
    app = AppState(
      gateway: _UnmeasuredGateway(gateway),
      settings: await LocalSettings.load(),
    );
    await open(tester);

    expect(
      find.textContaining('Nothing over 35 minutes is suggested'),
      findsOneWidget,
    );
    expect(find.textContaining('2 of these have no length'), findsOneWidget);
  });

  testWidgets('the verdict is the starting position, not the final one', (
    tester,
  ) async {
    await open(tester);

    // Approved starts on, a question starts off — a parent who agrees with
    // all of it has nothing to do but confirm.
    expect(switchFor(tester, 'Every Kind of Volcano').value, isTrue);
    await tab(tester, 'Hidden');
    expect(switchFor(tester, 'Twinkle Twinkle Little Star').value, isFalse);
  });

  testWidgets('a title-only judgement is flagged; a watched one needs no tag', (
    tester,
  ) async {
    // A video read on its title alone is a different judgement from one read
    // on what is said in it, and the person deciding is the one who should be
    // told which they are looking at.
    await open(tester);
    expect(find.text('Title only'), findsNothing);

    await tab(tester, 'Hidden');
    // The one it asked about, and the one it kept back: both read on the
    // title alone.
    expect(find.text('Title only'), findsNWidgets(2));
  });

  testWidgets('flipping a switch moves the card, and Undo brings it back', (
    tester,
  ) async {
    await open(tester);
    // Hidden counts what Gilli kept back as well as what is switched off.
    expect(find.text('Shown (2)'), findsOneWidget);
    expect(find.text('Hidden (2)'), findsOneWidget);

    await tester.tap(switchFinder(tester, 'Every Kind of Volcano'));
    await tester.pump();
    expect(find.text('Every Kind of Volcano'), findsNothing);
    expect(find.text('Shown (1)'), findsOneWidget);
    expect(find.text('Hidden (3)'), findsOneWidget);
    expect(find.text('Moved to Hidden'), findsOneWidget);

    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Every Kind of Volcano'), findsOneWidget);
    expect(find.text('Shown (2)'), findsOneWidget);
    expect(find.text('Hidden (2)'), findsOneWidget);
  });

  testWidgets('the count on the button follows the switches', (tester) async {
    await open(tester);
    expect(find.text('Allow 2 videos'), findsOneWidget);

    await tester.tap(find.text('Allow all'));
    await tester.pumpAndSettle();

    expect(find.text('Allow 3 videos'), findsOneWidget);
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
    // Switched off, so it now lives under Hidden.
    await tab(tester, 'Hidden');
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
      unknownLength: q.unknownLength,
      maxMinutes: q.maxMinutes,
    );
  }

  @override
  Future<void> reviewDecide(
    String kidId, {
    List<String> approve = const [],
    List<String> hide = const [],
  }) => inner.reviewDecide(kidId, approve: approve, hide: hide);
}

/// A gateway whose lengths could not be looked up, as a household without a
/// Google grant has.
class _UnmeasuredGateway extends FakeGateway {
  _UnmeasuredGateway(this.inner);
  final FakeGateway inner;

  @override
  Future<ReviewQueue> reviewQueue(String kidId) async {
    final q = await inner.reviewQueue(kidId);
    return ReviewQueue(
      items: q.items,
      screened: q.screened,
      expected: q.expected,
      channels: q.channels,
      unknownLength: 2,
      maxMinutes: 35,
    );
  }
}
