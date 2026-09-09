import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/progress_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Before HeyGilli: N% of watching came from channels not on the list."
///
/// The only number on the parent side that describes something which happened
/// before this app existed, and the only way to know it is the export the
/// parent brought across. Without one there is nothing honest to say, and a
/// card with an invented percentage in it would be worse than no card at all
/// in a product whose whole claim is that it does not guess.
void main() {
  late AppState app;
  late Kid kid;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final gateway = FakeGateway();
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
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: ProgressScreen(kid: kid)),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('the section is absent when nothing was imported', (
    tester,
  ) async {
    await open(tester);
    expect(
      find.textContaining('Before HeyGilli'),
      findsNothing,
      reason: 'with no export there is no measurement to report',
    );
  });

  test('the share is clamped, so a stray value cannot render "102%"', () {
    const over = HistoryInsight(kidId: 'k', videos: 10, unsubscribedShare: 1.4);
    expect(over.unsubscribedPercent, 100);
    const under = HistoryInsight(
      kidId: 'k',
      videos: 10,
      unsubscribedShare: -0.3,
    );
    expect(under.unsubscribedPercent, 0);
  });
}
