import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/prompts_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What Gilli is allowed to ask, and the parent's say over it.
///
/// Gilli asked every five-year-old "can you clap for the video?", for every
/// video, and there was nowhere in the app to change that.
void main() {
  late AppState app;
  late FakeGateway gateway;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
  });

  /// Created outside the widget harness: the fake gateway uses a real delay,
  /// and awaiting one inside `testWidgets` waits on a clock that only `pump`
  /// advances, which is a hang rather than a failure.
  Future<Kid> makeKid(WidgetTester tester, int age) async {
    late Kid kid;
    await tester.runAsync(() async {
      kid = await gateway.createKid(
        nickname: 'Abeeha',
        age: age,
        languages: const ['en'],
      );
      await app.refreshKids();
    });
    return kid;
  }

  Future<void> show(WidgetTester tester, Kid kid) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PromptsCard(kid: kid)),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('a pre-reader gets their own questions, all on to begin with', (
    tester,
  ) async {
    await show(tester, await makeKid(tester, 5));

    expect(find.text('Clap for the video'), findsOneWidget);
    expect(find.text('Name a colour you saw'), findsOneWidget);
    // Not a nine-year-old's question.
    expect(find.text('Explain it to a friend'), findsNothing);

    final switches = tester.widgetList<SwitchListTile>(find.byType(SwitchListTile));
    expect(switches.length, greaterThan(4), reason: 'one question is not a bank');
    expect(
      switches.every((s) => s.value),
      isTrue,
      reason: 'opt-out: a parent who never opens this still gets a working app',
    );
  });

  testWidgets('an older child is asked older questions', (tester) async {
    await show(tester, await makeKid(tester, 10));

    expect(find.text('Explain it to a friend'), findsOneWidget);
    expect(
      find.text('Clap for the video'),
      findsNothing,
      reason: 'grading the bank by band is the point of writing it',
    );
  });

  testWidgets('turning one off saves the ids that are off', (tester) async {
    final kid = await makeKid(tester, 5);
    await show(tester, kid);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Clap for the video'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Read back through the tree: the switch shows what the server returned,
    // so this is the round trip and not just local state.
    final clap = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Clap for the video'),
    );
    expect(clap.value, isFalse);
    final others = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .where((s) => s.value);
    expect(
      others.length,
      greaterThan(3),
      reason: 'turning one off must not turn the others off with it',
    );
    expect(find.text('Saved.'), findsOneWidget);
  });
}
