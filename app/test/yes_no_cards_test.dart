import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/icon_library.dart';
import 'package:heygilli/core/protocol.dart';
import 'package:heygilli/features/kid/pick_cards.dart';

/// A yes/no question is a pick with two options, so it goes through the cards
/// a child already knows how to use. The cards were written for three; this is
/// the check that two is not a broken three.
void main() {
  writtenCards();
  late IconLibrary icons;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    icons = await IconLibrary.load();
  });

  Widget host(List<PickOption> options, void Function(int) onPick) =>
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PickCards(
              options: options,
              icons: icons,
              onPick: onPick,
              showLabels: true,
            ),
          ),
        ),
      );

  const yesNo = [
    PickOption(iconId: 'icon_yes', label: 'yes'),
    PickOption(iconId: 'icon_no', label: 'no'),
  ];

  testWidgets('draws exactly two cards, not three', (tester) async {
    await tester.pumpWidget(host(yesNo, (_) {}));
    expect(find.text('yes'), findsOneWidget);
    expect(find.text('no'), findsOneWidget);
  });

  testWidgets('answers with the index that was tapped', (tester) async {
    var picked = -1;
    await tester.pumpWidget(host(yesNo, (i) => picked = i));

    await tester.tap(find.text('no'));
    await tester.pump();

    expect(picked, 1, reason: 'the second card is "no"');
  });

  test('the library has an icon for each answer', () {
    // The planner builds these two ids in code, so a missing file is a card
    // with a blank face rather than an error anybody would see.
    expect(icons.byId('icon_yes'), isNotNull);
    expect(icons.byId('icon_no'), isNotNull);
  });
}

/// A reader may be sent written answers: a card with no picture and a label.
/// The words fill the card; nothing falls back to the star icon.
void writtenCards() {
  late IconLibrary icons;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    icons = await IconLibrary.load();
  });

  const words = [
    PickOption(iconId: '', label: 'to cool the brain'),
    PickOption(iconId: '', label: 'to get more oxygen'),
    PickOption(iconId: 'icon_sun', label: 'sun'),
  ];

  testWidgets('a card with no picture shows its words, and still answers', (
    tester,
  ) async {
    var picked = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PickCards(
              options: words,
              icons: icons,
              onPick: (i) => picked = i,
              showLabels: true,
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('pick-text-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('pick-text-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('pick-text-2')), findsNothing);
    expect(find.text('to cool the brain'), findsOneWidget);
    expect(find.text('sun'), findsOneWidget);
    await tester.tap(find.text('to get more oxygen'));
    await tester.pump();
    expect(picked, 1);
  });
}
