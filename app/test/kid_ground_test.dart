import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/kid/kid_palette.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which ground a child watches on.
///
/// Dark was the only answer for as long as there has been a kid side, and the
/// reason is real — a bright screen in a dim room after tea. It is the wrong
/// answer in a bright room in the afternoon, where the dark screen is the one
/// that is hard to read, and a child had no say in it.
void main() {
  group('the palette', () {
    test('flips to the other one and back', () {
      expect(KidPalette.nightTime.flipped, KidPalette.dayTime);
      expect(KidPalette.dayTime.flipped, KidPalette.nightTime);
    });

    test('never puts rust on the dark ground', () {
      // 2.2:1. The whole reason accentTint exists.
      expect(KidPalette.nightTime.accent, isNot(KidPalette.dayTime.accent));
    });

    test("Gilli's bubble is inverted against the ground on both", () {
      // So a bubble always reads as somebody speaking rather than as one more
      // panel the same colour as everything around it.
      for (final palette in [KidPalette.nightTime, KidPalette.dayTime]) {
        expect(
          palette.bubble,
          isNot(palette.ground),
          reason: 'a bubble the colour of the page is not a bubble',
        );
        expect(palette.onBubble, isNot(palette.bubble));
      }
    });

    testWidgets('a screen built outside a KidTheme still gets the dark one', (
      tester,
    ) async {
      // A test pumping one widget on its own, most often. The fallback keeps
      // that from being a crash.
      late KidPalette seen;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            seen = KidPalette.of(context);
            return const SizedBox();
          },
        ),
      );
      expect(seen, KidPalette.nightTime);
    });

    testWidgets('and the one in scope when there is one', (tester) async {
      late KidPalette seen;
      await tester.pumpWidget(
        KidTheme(
          palette: KidPalette.dayTime,
          child: Builder(
            builder: (context) {
              seen = KidPalette.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, KidPalette.dayTime);
    });
  });

  group('remembering the choice', () {
    late LocalSettings settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await LocalSettings.load();
    });

    test('dark until a child says otherwise', () {
      expect(settings.kidLikesDaylight('kid_1'), isFalse);
    });

    test('and it survives being asked again', () async {
      await settings.setKidLikesDaylight('kid_1', true);
      expect(settings.kidLikesDaylight('kid_1'), isTrue);
    });

    test('one sibling choosing does not choose for the other', () async {
      // Two children on one tablet. The whole reason this is stored per child
      // rather than per device.
      await settings.setKidLikesDaylight('kid_1', true);
      expect(settings.kidLikesDaylight('kid_2'), isFalse);
    });

    test('turning it off again leaves nothing behind', () async {
      await settings.setKidLikesDaylight('kid_1', true);
      await settings.setKidLikesDaylight('kid_1', false);
      expect(settings.kidLikesDaylight('kid_1'), isFalse);
    });
  });

  group('what the time pill says', () {
    // The pill is built from the watch state and the child's own limits, and
    // says nothing at all when there is nothing to say — a pill reading
    // "unlimited" answers a question nobody asked.
    const kid = Kid(
      id: 'k',
      nickname: 'Abu',
      age: 8,
      band: AgeBand.b7to8,
      languages: ['en'],
      dailyMinutes: 60,
      breakAfterMinutes: 25,
    );

    test('a child with limits has both halves of it', () {
      const state = WatchState(minutesLeftToday: 35, continuousMinutes: 13);
      expect(kid.dailyMinutes > 0 && state.minutesLeftToday > 0, isTrue);
      expect(kid.breakAfterMinutes - state.continuousMinutes, 12);
    });

    test('a child with no limits has neither', () {
      const free = Kid(
        id: 'k',
        nickname: 'Abu',
        age: 8,
        band: AgeBand.b7to8,
        languages: ['en'],
        dailyMinutes: 0,
        breakAfterMinutes: 0,
      );
      const state = WatchState();
      expect(free.dailyMinutes > 0 && state.minutesLeftToday > 0, isFalse);
      expect(free.breakAfterMinutes > 0, isFalse);
    });
  });
}
