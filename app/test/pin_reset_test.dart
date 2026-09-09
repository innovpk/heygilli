import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Forgetting the parent PIN.
///
/// The PIN is chosen once, kept only on this device and never sent anywhere,
/// so there is nothing to recover it with. Without a reset, a parent who
/// mistyped it at setup could not leave kid mode on that device again — ever.
void main() {
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
  });

  test(
    'a PIN can be forgotten, and the gate then asks for a new one',
    () async {
      await app.setPin('1234');
      expect(app.hasPin, isTrue);
      expect(app.checkPin('1234'), isTrue);

      await app.clearPin();

      expect(
        app.hasPin,
        isFalse,
        reason: 'the gate sets a new PIN when none is stored',
      );
      expect(
        app.checkPin('1234'),
        isFalse,
        reason: 'the old PIN must not still open it',
      );

      await app.setPin('5678');
      expect(app.checkPin('5678'), isTrue);
      expect(app.checkPin('1234'), isFalse);
    },
  );

  test('clearing the PIN leaves the rest of the household alone', () async {
    await app.setPin('1234');
    await app.settings.setParentName('Asma');
    final kid = await app.addKid(
      nickname: 'Abu',
      age: 5,
      languages: const ['en'],
    );
    await app.setDeviceKid(kid);

    await app.clearPin();

    // Whose device this is, and who is signed in, are separate questions from
    // which four digits open the gate.
    expect(app.settings.parentName, 'Asma');
    expect(app.settings.kidDeviceId, kid.id);
    expect(app.kids.single.id, kid.id);
  });
}
