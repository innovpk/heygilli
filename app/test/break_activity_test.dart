import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/break_activities.dart';
import 'package:heygilli/core/fake_gateway.dart';

/// What a parent picks for breaks during setup is what Gilli asks for at one.
///
/// The demo gateway used to keep the picks only so a test could see them
/// arrive, so every demo break was Gilli saying "break time" and nothing else.
void main() {
  test('a pick becomes the line Gilli says, with its picture', () async {
    final gateway = FakeGateway();
    await gateway.signInDev('parent');
    final kid = await gateway.createKid(
      nickname: 'Abu',
      age: 5,
      languages: const ['en'],
    );
    await gateway.setPreferences(
      kid.id,
      const [],
      breakActivities: const ['jump', 'not-an-activity'],
    );

    final line = gateway.savedBreakMessages(kid.id).single;
    expect(line.activity, 'jump');
    expect(line.speech, 'Break time. Star jumps?');
    expect(breakActivityIcons[line.activity], isNotNull);
  });

  test('every activity offered has a picture', () {
    expect(breakActivityIcons.keys.toSet(), breakActivityLabels.keys.toSet());
  });
}
