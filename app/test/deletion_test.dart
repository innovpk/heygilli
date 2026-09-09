import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/kid_detail_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Removing a child, and removing the household.
///
/// Neither was possible: a child added by mistake stayed for ever, and a
/// parent who wanted to be forgotten had nowhere to ask.
void main() {
  _feedback();

  late AppState app;
  late FakeGateway gateway;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
  });

  Future<Kid> addKid(String name, int age) async {
    final kid = await app.addKid(
      nickname: name,
      age: age,
      languages: const ['en'],
    );
    return kid;
  }

  test('deleting one child leaves their sibling alone', () async {
    final gone = await addKid('Abu', 8);
    final stays = await addKid('Zara', 5);

    await app.deleteKid(gone);

    expect(app.kids.map((k) => k.id), [stays.id]);
  });

  test('the name has to match, and nothing happens when it does not', () async {
    final kid = await addKid('Abu', 8);

    // The server refuses without the nickname; the client must not paper over
    // that, or the confirmation is theatre.
    await expectLater(
      gateway.deleteKid(kid.id, 'Zara'),
      throwsA(isA<StateError>()),
    );
    expect((await gateway.kids()).length, 1);
  });

  test("deleting the device's own child stops it being their device", () async {
    final kid = await addKid('Abu', 8);
    await app.setDeviceKid(kid);
    expect(app.settings.kidDeviceId, kid.id);

    await app.deleteKid(kid);

    // Otherwise the tablet boots for ever into a profile that is not there.
    expect(app.settings.kidDeviceId, isNull);
    expect(app.deviceKid, isNull);
  });

  test('deleting a child who is being watched leaves kid mode', () async {
    final kid = await addKid('Abu', 8);
    app.enterKidMode(kid);
    expect(app.kidMode, isTrue);

    await app.deleteKid(kid);

    expect(app.kidMode, isFalse);
    expect(app.activeKid, isNull);
  });

  test(
    'deleting the household takes every child and ends the session',
    () async {
      await addKid('Abu', 8);
      await addKid('Zara', 5);
      await app.settings.setKidDeviceId('kid_something');

      await app.deleteHousehold();

      expect(app.kids, isEmpty);
      expect(
        app.signedIn,
        isFalse,
        reason: 'a token for an account that is gone',
      );
      expect(app.settings.kidDeviceId, isNull);
    },
  );
}

/// What the parent sees while it happens.
///
/// Deleting is several calls over a gateway that may be asleep, so it can take
/// seconds. Without a sign of life the parent taps Delete, the dialog closes,
/// the page sits there, and they tap it again.
void _feedback() {
  testWidgets('the page shows it is deleting, and cannot be started twice', (
    tester,
  ) async {
    late AppState app;
    late _SlowGateway gateway;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      gateway = _SlowGateway();
      await gateway.signInDev('parent');
      app = AppState(gateway: gateway, settings: await LocalSettings.load());
      await gateway.createKid(
        nickname: 'Abdul',
        age: 8,
        languages: const ['en'],
      );
      await app.refreshKids();
      await app.settings.setPin('1234');
    });
    final kid = app.kids.single;

    tester.view.physicalSize = const Size(1200, 900);
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

    // Reachable from the tab a parent lands on, not only from Rules.
    expect(find.byTooltip('Delete Abdul'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete Abdul'));
    await tester.pumpAndSettle();
    for (final digit in ['1', '2', '3', '4']) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'Abdul');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pump();
    await tester.pump();

    // The delete is in flight and will not return. The parent must be able to
    // see that, and must not be able to fire a second one.
    expect(find.text('Deleting Abdul...'), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.delete_outline),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);
  });
}

/// A gateway whose delete never finishes, so the waiting state can be seen.
class _SlowGateway extends FakeGateway {
  @override
  Future<void> deleteKid(String kidId, String confirmNickname) =>
      Completer<void>().future;
}
