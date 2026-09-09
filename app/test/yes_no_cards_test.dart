import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/icon_library.dart';
import 'package:heygilli/core/protocol.dart';
import 'package:heygilli/features/kid/pick_cards.dart';

/// A yes/no question is a pick with two options, so it goes through the cards
/// a child already knows how to use. The cards were written for three; this is
/// the check that two is not a broken three.
void main() {
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
