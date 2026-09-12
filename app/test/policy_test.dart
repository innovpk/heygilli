import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/policy_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What this household actually wants (PROTOCOL "Household policy").
///
/// Two rules matter more than the rest of this file. A question must show the
/// parent where it came from, or it is a stranger's checklist wearing this
/// child's name; and a question nobody answered must reach the Curator as
/// nothing at all, never as a quiet "fine".
void main() {
  group('what the page claims about itself', _honesty);

  late FakeGateway gateway;
  late AppState app;
  late Kid kid;

  /// The questions the demo Coach will propose for this kid, fetched here
  /// rather than in a test body: FakeGateway's lag is a real delay and the
  /// clock inside testWidgets is frozen.
  late PolicyQuestions asked;
  late List<PolicyQuestion> questions;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    kid = await gateway.createKid(
      nickname: 'Zoya',
      age: 8,
      languages: const ['en'],
    );
    // Two more channels so the Coach has more than one thing to ask about,
    // the way a real imported pile would.
    await gateway.addChannel(kid.id, 'https://youtube.com/@MinecraftDiaries');
    await gateway.addChannel(kid.id, 'https://youtube.com/@LegoBuildZone');
    asked = await gateway.policyQuestions(kid.id);
    questions = asked.questions;
  });

  Widget host() => ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(home: PolicyScreen(kid: kid)),
  );

  /// FakeGateway's lag runs on the tester's clock, so time is pumped rather
  /// than settled. The screen opens with two calls in flight and a save is
  /// one more, so four rounds covers either.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// A tall surface so every card is built and tappable without scrolling.
  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await settle(tester);
  }

  /// The saved policy as it stands, read without the simulated lag.
  Policy saved() => gateway.savedPolicy(kid.id);

  testWidgets('every question says which of this child\'s channels asked it', (
    tester,
  ) async {
    await open(tester);

    expect(questions, isNotEmpty, reason: 'the demo Coach proposed nothing');
    // The why is the difference between a question about this household and a
    // checklist someone else wrote. Its label went in a copy trim; the reason
    // itself is still under every question, and that is what is held here.
    for (final q in questions) {
      expect(q.why, isNotEmpty, reason: q.question);
    }
    expect(find.text(questions.first.why), findsOneWidget);
  });

  testWidgets('a question left alone is saved as no answer at all', (
    tester,
  ) async {
    await open(tester);

    await tester.tap(find.text('Fine').first);
    await tester.pump();
    await tester.tap(find.text('Save these answers'));
    await settle(tester);

    // One answered, the rest skipped. An untouched question arriving as
    // "fine" would put an opinion in this household's mouth.
    expect(saved().answers.length, 1);
    expect(saved().answers.single.id, questions.first.id);
    expect(saved().answers.single.choice, PolicyChoice.fine);
  });

  testWidgets('the question is saved with the answer, in the words asked', (
    tester,
  ) async {
    await open(tester);

    await tester.tap(find.text('Sometimes').first);
    await tester.pump();
    await tester.tap(find.text('Save these answers'));
    await settle(tester);

    expect(saved().answers.single.question, questions.first.question);
  });

  testWidgets('"rather not" says the video comes to the parent, not that it '
      'disappears', (tester) async {
    await open(tester);

    await tester.tap(find.text('Rather not').first);
    await tester.pump();

    // The strongest answer in the product still leaves the decision with the
    // parent, and the card says so where they are deciding.
    expect(find.textContaining('come to your inbox'), findsOneWidget);
    expect(
      find.textContaining('Nothing is hidden without you'),
      findsOneWidget,
    );
  });

  testWidgets('tapping the same answer again goes back to unanswered', (
    tester,
  ) async {
    await open(tester);

    await tester.tap(find.text('Fine').first);
    await tester.pump();
    await tester.tap(find.text('Save these answers'));
    await settle(tester);
    expect(saved().answers, hasLength(1));

    await tester.tap(find.text('Fine').first);
    await tester.pump();
    await tester.tap(find.text('Save these answers'));
    await settle(tester);

    // A parent who tapped by accident can take it back. Unanswered is a real
    // state, not a gap to be filled with the mildest choice.
    expect(saved().answers, isEmpty);
  });

  testWidgets('answers are still there when the screen is opened again', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Rather not').first);
    await tester.pump();
    await tester.tap(find.text('Save these answers'));
    await settle(tester);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pumpWidget(host());
    await settle(tester);

    // The effect line only shows under a chosen answer, so seeing it means
    // the saved choice came back selected.
    expect(find.textContaining('come to your inbox'), findsOneWidget);
  });

  testWidgets('the notes are saved as the parent wrote them', (tester) async {
    await open(tester);

    await tester.enterText(
      find.byType(TextField),
      'Nothing about dieting, and no gambling ads.',
    );
    await tester.pump();
    await tester.tap(find.text('Save these answers'));
    await settle(tester);

    expect(saved().notes, 'Nothing about dieting, and no gambling ads.');
  });

  testWidgets('answering nothing is a valid state, and nothing nags', (
    tester,
  ) async {
    await open(tester);

    // Nothing to save, because a household that skips every question is
    // telling the Curator to fall back to age alone. That is a setting.
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Save these answers'), findsNothing);
    expect(saved().isEmpty, isTrue);
  });

  testWidgets('a saved answer says how much it is actually doing', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Rather not').first);
    await tester.pump();
    await tester.tap(find.text('Save these answers'));
    await settle(tester);

    // weight is the server's number; the screen turns it into words rather
    // than showing a parent "0.8".
    expect(saved().answers.single.weight, greaterThan(0));
    expect(find.textContaining('Weighs'), findsOneWidget);
  });

  group('while setting a child up', () {
    // Setup asks one question to a page; it pops when done, so it is opened
    // from a page underneath rather than as the app's only route.
    Future<void> openSetup(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                      builder: (_) => PolicyScreen(kid: kid, setup: true),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
    }

    Future<void> next(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('one question to a page, and skipping is offered', (
      tester,
    ) async {
      await openSetup(tester);

      expect(find.text(questions.first.question), findsOneWidget);
      expect(find.text(questions[1].question), findsNothing);
      expect(
        find.text('QUESTION 1 OF ${questions.length + 1}'),
        findsOneWidget,
      );
      // Still said where it came from, on its own page.
      expect(find.text(questions.first.why), findsOneWidget);
      expect(find.text('Skip this one'), findsOneWidget);

      // One tap is the whole answer: the page turns by itself, after a
      // beat long enough to see what was picked.
      await tester.tap(find.text('Fine'));
      await tester.pump();
      expect(find.text(questions.first.question), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);
      await tester.pump(PolicyScreen.advanceAfter);
      expect(find.text(questions[1].question), findsOneWidget);
    });

    testWidgets('clearing an answer keeps the page', (tester) async {
      await openSetup(tester);

      await tester.tap(find.text('Fine'));
      await tester.pump();
      await tester.tap(find.text('Fine'));
      await tester.pump(PolicyScreen.advanceAfter);
      expect(find.text(questions.first.question), findsOneWidget);
      expect(find.text('Skip this one'), findsOneWidget);
    });

    testWidgets('a skipped question is saved as no answer at all', (
      tester,
    ) async {
      await openSetup(tester);

      await tester.tap(find.text('Rather not'));
      await tester.pump(PolicyScreen.advanceAfter);
      for (var i = 1; i < questions.length; i++) {
        await next(tester, 'Skip this one');
      }
      expect(find.text('Anything else, in your own words?'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'No gambling ads.');
      await tester.pump();
      await next(tester, 'Save and go on');
      await settle(tester);

      expect(saved().answers, hasLength(1));
      expect(saved().answers.single.id, questions.first.id);
      expect(saved().answers.single.choice, PolicyChoice.ratherNot);
      expect(saved().notes, 'No gambling ads.');
      expect(find.text('open'), findsOneWidget, reason: 'setup moved on');
    });

    testWidgets('going back keeps the answer given', (tester) async {
      await openSetup(tester);

      await tester.tap(find.text('Rather not'));
      await tester.pump();
      // The strongest answer still leaves the decision with the parent, and
      // the page says so where they are deciding.
      expect(find.textContaining('come to your inbox'), findsOneWidget);
      await tester.pump(PolicyScreen.advanceAfter);
      expect(find.text(questions[1].question), findsOneWidget);
      await next(tester, 'Back');

      expect(find.text(questions.first.question), findsOneWidget);
      expect(find.textContaining('come to your inbox'), findsOneWidget);
    });

    testWidgets('answering nothing goes on, and saves nothing', (tester) async {
      await openSetup(tester);

      for (var i = 0; i < questions.length; i++) {
        await next(tester, 'Skip this one');
      }
      await next(tester, 'Save and go on');
      await settle(tester);

      expect(find.text('open'), findsOneWidget);
      expect(saved().isEmpty, isTrue);
    });
  });

  group('Policy wire types', () {
    test('an unanswered question has no choice to read', () {
      expect(PolicyChoice.fromWire(null), isNull);
      expect(PolicyChoice.fromWire('block_it'), isNull);
      expect(PolicyChoice.fromWire('rather_not'), PolicyChoice.ratherNot);
    });

    test('an empty policy round-trips as empty', () {
      final p = Policy.fromJson({'kid_id': 'kid_1'});
      expect(p.isEmpty, isTrue);
      expect(p.answers, isEmpty);
      expect(p.notes, '');
      expect(p.choiceFor('q_gaming'), isNull);
    });

    test('a question with no options offered still has three', () {
      final q = PolicyQuestion.fromJson({
        'id': 'q_1',
        'question': 'Gaming videos?',
        'why': 'Two of these channels are gaming channels.',
      });
      expect(q.options, PolicyChoice.values);
    });

    test('unreadable options are dropped, not turned into a dead question', () {
      final q = PolicyQuestion.fromJson({
        'id': 'q_1',
        'question': 'Gaming videos?',
        'options': ['fine', 'nope'],
      });
      expect(q.options, [PolicyChoice.fine]);
    });

    test('a weight of zero has nothing to say', () {
      const a = PolicyAnswer(
        id: 'q_1',
        question: 'Gaming videos?',
        choice: PolicyChoice.fine,
      );
      expect(a.weightLabel, isNull);
    });
  });
}

/// The page must not claim more than it knows.
///
/// The first live run of this screen showed a header saying the questions came
/// from this child's own channels while every "why" underneath said "asked of
/// every family" — because the child had no channels yet. A parent who spots
/// one page overclaiming has no reason to believe the next one.
void _honesty() {
  // Both households are built here rather than in a test body: FakeGateway's
  // lag is a real delay, and inside testWidgets the clock is the tester's, so
  // an awaited call there would never come back.
  late AppState bare;
  late Kid bareKid;
  late AppState stocked;
  late Kid stockedKid;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    final empty = FakeGateway();
    await empty.signInDev('parent');
    bare = AppState(gateway: empty, settings: await LocalSettings.load());
    bareKid = await empty.createKid(
      nickname: 'Abu',
      age: 8,
      languages: const ['en'],
    );
    // A new kid in demo mode starts with a few channels so the rest of the
    // app has something to show. This household has removed them, which is
    // the real state a parent reaches by clearing an import they regret.
    for (final c in await empty.channels(bareKid.id)) {
      await empty.removeChannel(bareKid.id, c.id);
    }
    expect(
      (await empty.policyQuestions(bareKid.id)).basedOn,
      isEmpty,
      reason: 'nothing to have drawn on',
    );

    final full = FakeGateway();
    await full.signInDev('parent');
    stocked = AppState(gateway: full, settings: await LocalSettings.load());
    stockedKid = await full.createKid(
      nickname: 'Abu',
      age: 8,
      languages: const ['en'],
    );
    await full.addChannel(
      stockedKid.id,
      'https://youtube.com/@MinecraftDiaries',
    );
    await full.addChannel(stockedKid.id, 'https://youtube.com/@LegoBuildZone');
    expect((await full.policyQuestions(stockedKid.id)).basedOn, isNotEmpty);
  });

  Future<void> open(WidgetTester tester, AppState app, Kid kid) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: PolicyScreen(kid: kid)),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('with no channels it says these are the common questions', (
    tester,
  ) async {
    await open(tester, bare, bareKid);
    expect(
      find.textContaining('every family is asked'),
      findsOneWidget,
      reason: 'the page claimed the questions came from this child',
    );
    expect(find.textContaining('already subscribed to'), findsNothing);
  });

  testWidgets('with channels it says where the questions came from', (
    tester,
  ) async {
    await open(tester, stocked, stockedKid);
    expect(find.textContaining('already subscribed to'), findsOneWidget);
    expect(find.textContaining('every family is asked'), findsNothing);
  });
}
