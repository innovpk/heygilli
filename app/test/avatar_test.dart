import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A child's own picture.
///
/// `Kid.avatar` existed on the model and was never set or drawn by anything:
/// every child was their own initial in a mango circle, and nothing anywhere
/// let them change it.
void main() {
  late AppState app;
  late Kid kid;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    kid = await app.addKid(nickname: 'Abeeha', age: 5, languages: const ['en']);
  });

  test('a child can choose a picture and it sticks', () async {
    final updated = await app.editKid(kid.id, avatar: 'frog');
    expect(updated.avatar, 'frog');
    expect(app.kids.single.avatar, 'frog');

    // And go back to their initial: empty is a real choice, not a no-op.
    expect((await app.editKid(kid.id, avatar: '')).avatar, '');
  });

  test('changing the picture changes nothing else about them', () async {
    await app.editKid(kid.id, avatar: 'rocket');
    final stored = app.kids.single;
    expect(stored.nickname, 'Abeeha');
    expect(stored.age, 5);
    expect(stored.band, AgeBand.b4to6);
  });

  test('a child who has not chosen shows their initial, not a blank circle', () {
    // The server's default is "gilli", for which there is no icon. Every child
    // who had never opened the picker therefore rendered as an empty coloured
    // circle — a bug the earlier tests could not see, because they only ever
    // checked names that were already in the offered list.
    const notChosen = Kid(
      id: 'k',
      nickname: 'Abeeha',
      age: 7,
      band: AgeBand.b7to8,
      languages: ['en'],
      avatar: 'gilli',
    );
    expect(notChosen.hasDrawableAvatar, isFalse);

    for (final name in kidAvatars) {
      expect(
        Kid(
          id: 'k',
          nickname: 'A',
          age: 7,
          band: AgeBand.b7to8,
          languages: const ['en'],
          avatar: name,
        ).hasDrawableAvatar,
        isTrue,
        reason: '$name is offered, so it must be drawable',
      );
    }

    // And a face this app has never heard of — one added on the server before
    // the asset ships — falls back rather than drawing nothing.
    expect(
      const Kid(
        id: 'k',
        nickname: 'A',
        age: 7,
        band: AgeBand.b7to8,
        languages: ['en'],
        avatar: 'unicorn',
      ).hasDrawableAvatar,
      isFalse,
    );
  });

  test('every offered face has an asset behind it', () {
    // The name is turned straight into assets/icons/<name>.svg, so an offered
    // face with no file is a blank circle on a child's screen — and a child
    // cannot report that.
    expect(kidAvatars, isNotEmpty);
    expect(
      kidAvatars.toSet().length,
      kidAvatars.length,
      reason: 'duplicate face',
    );
    for (final name in kidAvatars) {
      expect(
        File('assets/icons/$name.svg').existsSync(),
        isTrue,
        reason: 'offered "$name" with no assets/icons/$name.svg behind it',
      );
    }
  });
}
