import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/starter_channels_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Somewhere to start, for a household with no channels.
///
/// Setting up meant requesting a Takeout export from Google and waiting for
/// it, or handing over an account before knowing whether you want the thing.
/// A parent who did neither had an empty app.
class _CountingGateway extends FakeGateway {
  final List<String> added = [];

  @override
  Future<Channel> addChannel(String kidId, String url) {
    added.add(url);
    return super.addChannel(kidId, url);
  }
}

void main() {
  late AppState app;
  late _CountingGateway gateway;
  late Kid kid;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = _CountingGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    kid = await gateway.createKid(
      nickname: 'Abeeha',
      age: 5,
      languages: const ['en'],
    );
    await app.refreshKids();
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: StarterChannelsScreen(kid: kid)),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('picking nothing still offers channels for their age', (
    tester,
  ) async {
    await show(tester);
    // "I do not know yet" is the commonest answer during setup and must not
    // be met with a blank screen.
    expect(find.byType(CheckboxListTile), findsWidgets);
    expect(find.text('Danny Go!'), findsOneWidget);
    // Nothing is preselected: arriving here approves nothing.
    final boxes = tester.widgetList<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(boxes.every((b) => b.value == false), isTrue);
    expect(find.text('Choose at least one'), findsOneWidget);
  });

  testWidgets('a topic narrows the list', (tester) async {
    await show(tester);
    final before = tester.widgetList(find.byType(CheckboxListTile)).length;

    await tester.tap(find.text('Science and how things work'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('SciShow Kids'), findsOneWidget);
    expect(find.text('Danny Go!'), findsNothing);
    expect(tester.widgetList(find.byType(CheckboxListTile)).length, lessThan(before));
  });

  testWidgets('the chosen channels are added, and only those', (tester) async {
    await show(tester);

    await tester.tap(find.widgetWithText(CheckboxListTile, 'Danny Go!'));
    await tester.pump();
    expect(find.text('Add 1 channel'), findsOneWidget);

    await tester.tap(find.text('Add 1 channel'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(gateway.added, [
      'https://www.youtube.com/channel/UC3wCAOfSB0W9iuKDDtNJeGw',
    ]);
  });

  testWidgets('select all is a toggle, not a trap', (tester) async {
    await show(tester);
    final total = tester.widgetList(find.byType(CheckboxListTile)).length;

    await tester.tap(find.text('Select all'));
    await tester.pump();
    expect(find.text('Add $total channels'), findsOneWidget);

    // A parent who ticked everything by accident needs one tap back, not one
    // per channel.
    await tester.tap(find.text('Clear all'));
    await tester.pump();
    expect(find.text('Choose at least one'), findsOneWidget);
    expect(gateway.added, isEmpty);
  });
}
