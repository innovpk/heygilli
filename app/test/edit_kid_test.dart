import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/kid_detail_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Correcting a child.
///
/// There was no way to do this anywhere in the app: no edit, and no delete
/// either, so a child entered with the wrong age kept it for ever. Age is not
/// cosmetic — it sets the band, which is what the Curator screens against and
/// what decides whether the child is read to or shown text.
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
      nickname: 'Abeeha',
      age: 5,
      languages: const ['en'],
    );
    await app.refreshKids();
  });

  test('changing the age moves the band with it', () async {
    expect(kid.band, AgeBand.b4to6);

    final updated = await app.editKid(kid.id, age: 11);

    expect(updated.age, 11);
    expect(
      updated.band,
      AgeBand.b9to11,
      reason: 'keeping the old band would screen an 11-year-old as a pre-reader',
    );
    // And the household list a screen reads from, not just the returned copy.
    expect(app.kids.single.band, AgeBand.b9to11);
  });

  test('an edit is a correction, not a re-registration', () async {
    await gateway.updateLimits(kid.id, maxVideoMinutes: 20);

    await app.editKid(kid.id, nickname: 'Abee');

    final stored = app.kids.single;
    expect(stored.nickname, 'Abee');
    expect(stored.age, 5, reason: 'a name change must not reset the age');
    expect(stored.maxVideoMinutes, 20, reason: 'limits the parent set must survive');
    expect(stored.languages, ['en']);
  });

  testWidgets('the child page offers the edit', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: KidDetailScreen(kid: kid)),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.textContaining('Age 5'), findsOneWidget);
    expect(
      find.byTooltip('Edit Abeeha'),
      findsOneWidget,
      reason: 'without it the age on this very screen cannot be corrected',
    );
  });
}
