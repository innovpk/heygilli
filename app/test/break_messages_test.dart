import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/break_messages_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The parent's break-time lines (PROTOCOL "Time limits and break periods").
///
/// One rule is worth more than the rest of this file: a sentence reaches a
/// child only because a parent saved it. Suggestions are drafts in a text box
/// and nothing more, and these tests fail if that ever stops being true.
void main() {
  late FakeGateway gateway;
  late AppState app;
  late Kid kid;

  /// A second child whose parent already saved a line. Seeded here rather
  /// than in a test body: FakeGateway's lag is a real delay, and inside
  /// testWidgets the clock is frozen.
  late Kid kidWithLines;

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
    final other = await gateway.createKid(
      nickname: 'Bilal',
      age: 9,
      languages: const ['en'],
    );
    kidWithLines = await gateway.saveBreakMessages(other.id, const [
      BreakMessage(text: 'Break time. Have a stretch.'),
    ]);
  });

  Widget host(Kid k) => ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: BreakMessagesCard(kid: k)),
      ),
    ),
  );

  /// FakeGateway's simulated lag runs on the tester's clock, so anything that
  /// waits on it needs time pumped rather than a bare frame. A save is two
  /// round trips — the write, then the reload — so this pumps through both.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// What Gilli would read out to this child, as things stand.
  ///
  /// Read synchronously: FakeGateway's simulated lag is a real delay, and
  /// inside testWidgets the clock is the tester's, so awaiting `kids()` from
  /// a test body would never come back.
  List<BreakMessage> savedLines([Kid? who]) =>
      gateway.savedBreakMessages((who ?? kid).id);

  testWidgets('a kid with no lines is a quiet break, said plainly', (
    tester,
  ) async {
    await tester.pumpWidget(host(kid));
    await tester.pump();

    expect(find.textContaining('Breaks will be quiet'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('typing a line and saving it is what reaches the child', (
    tester,
  ) async {
    await tester.pumpWidget(host(kid));
    await tester.pump();

    await tester.tap(find.text('Add a line'));
    await tester.pump();
    await tester.enterText(
      find.byType(TextField),
      'Break time. Come and drink some water.',
    );
    await tester.pump();

    await tester.tap(find.text('Save what Gilli says'));
    await settle(tester);

    final saved = savedLines();
    expect(saved.single.text, 'Break time. Come and drink some water.');
    expect(saved.single.id, isNotEmpty, reason: 'a saved line needs an id');
  });

  testWidgets('asking for ideas puts drafts in the boxes and saves nothing', (
    tester,
  ) async {
    await tester.pumpWidget(host(kid));
    await tester.pump();

    await tester.tap(find.text('Ideas'));
    await settle(tester);

    // Drafts are on screen, editable.
    expect(find.byType(TextField), findsWidgets);
    // And not one word of them has reached the child.
    expect(
      savedLines(),
      isEmpty,
      reason: 'a suggestion reached a child without the parent saving it',
    );
  });

  testWidgets('a suggestion the parent edits is saved as they edited it', (
    tester,
  ) async {
    await tester.pumpWidget(host(kid));
    await tester.pump();

    await tester.tap(find.text('Ideas'));
    await settle(tester);

    await tester.enterText(
      find.byType(TextField).first,
      'Break time. Go and say salaam to Nano.',
    );
    await tester.pump();
    // Everything the parent did not want goes before the save.
    final extras = find.byTooltip('Remove this line');
    while (tester.widgetList(extras).length > 1) {
      await tester.tap(extras.last);
      await tester.pump();
    }

    await tester.tap(find.text('Save what Gilli says'));
    await settle(tester);

    final saved = savedLines();
    expect(saved.single.text, 'Break time. Go and say salaam to Nano.');
  });

  testWidgets('clearing every line goes back to a quiet break', (tester) async {
    await tester.pumpWidget(host(kidWithLines));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(savedLines(kidWithLines), isNotEmpty);

    await tester.tap(find.byTooltip('Remove this line'));
    await tester.pump();
    await tester.tap(find.text('Save what Gilli says'));
    await settle(tester);

    // The parent said "nothing", and that is saved as nothing rather than
    // quietly leaving the old line in place.
    expect(savedLines(kidWithLines), isEmpty);
  });

  testWidgets('a blank box is dropped, not saved as an empty line', (
    tester,
  ) async {
    await tester.pumpWidget(host(kid));
    await tester.pump();

    await tester.tap(find.text('Add a line'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Break time.');
    await tester.pump();
    await tester.tap(find.text('Add a line'));
    await tester.pump();

    await tester.tap(find.text('Save what Gilli says'));
    await settle(tester);

    // An empty line would be a break where Gilli opens its mouth and says
    // nothing, which is worse than a quiet one.
    final saved = savedLines();
    expect(saved.length, 1);
    expect(saved.single.text, 'Break time.');
  });

  testWidgets('the save button stays quiet until something changed', (
    tester,
  ) async {
    await tester.pumpWidget(host(kid));
    await tester.pump();
    expect(find.text('Saved'), findsOneWidget);

    await tester.tap(find.text('Add a line'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Break time.');
    await tester.pump();
    expect(find.text('Save what Gilli says'), findsOneWidget);
  });

  testWidgets('the card says where the boundary is', (tester) async {
    // A parent should not have to infer whether the model can reach their
    // child; the card tells them, in the place they would ask.
    await tester.pumpWidget(host(kid));
    await tester.pump();
    expect(
      find.textContaining('Nothing reaches Zoya until you save it'),
      findsOneWidget,
    );
  });
}
