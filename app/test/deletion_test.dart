import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Removing a child, and removing the household.
///
/// Neither was possible: a child added by mistake stayed for ever, and a
/// parent who wanted to be forgotten had nowhere to ask.
void main() {
  late AppState app;
  late FakeGateway gateway;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
  });

  Future<Kid> addKid(String name, int age) async {
    final kid = await app.addKid(nickname: name, age: age, languages: const ['en']);
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

  test('deleting the household takes every child and ends the session', () async {
    await addKid('Abu', 8);
    await addKid('Zara', 5);
    await app.settings.setKidDeviceId('kid_something');

    await app.deleteHousehold();

    expect(app.kids, isEmpty);
    expect(app.signedIn, isFalse, reason: 'a token for an account that is gone');
    expect(app.settings.kidDeviceId, isNull);
  });
}
