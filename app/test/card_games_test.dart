import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/icon_library.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/play.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/speech.dart';
import 'package:heygilli/features/kid/games/balloon_pop_game.dart';
import 'package:heygilli/features/kid/games/memory_game.dart';
import 'package:heygilli/features/kid/games/play_screen.dart';
import 'package:heygilli/features/kid/games/quiz_game.dart';
import 'package:heygilli/features/kid/games/quiz_rounds.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The card games: letters, sums, guess the animal, spot the animal. The
/// question is written on the device from the level and the band; the
/// Playmate rule (FakeGateway's copy) sets the level from how the last rounds
/// went. Nobody loses a round: a wrong card fades, and after two of those the
/// right one wobbles.
void main() {
  late FakeGateway gateway;
  late AppState app;
  late IconLibrary icons;
  late Kid reader;
  late Kid older;
  late Kid preReader;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    icons = await IconLibrary.load();
    reader = await gateway.createKid(
      nickname: 'Rayan',
      age: 8,
      languages: const ['en'],
    );
    older = await gateway.createKid(
      nickname: 'Sana',
      age: 10,
      languages: const ['en'],
    );
    preReader = await gateway.createKid(
      nickname: 'Lisa',
      age: 5,
      languages: const ['en'],
    );
  });

  Widget host(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<GilliVoice>(create: (_) => _SilentVoice()),
      Provider<IconLibrary>.value(value: icons),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );

  Future<void> tearDownGame(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  QuizRound roundOf(WidgetTester tester) =>
      tester.state<QuizGameState>(find.byType(QuizGame)).round!;

  Future<void> start(WidgetTester tester, Kid kid, PlayGame game) async {
    await tester.pumpWidget(
      host(
        QuizGame(
          kid: kid,
          game: game,
          onBack: () {},
          onAgain: () {},
          onHome: () {},
          rng: Random(7),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The cards ignore a tap for a moment after they change.
    await tester.pump(QuizGameState.settle * 2);
  }

  group('rounds by band', () {
    final rng = Random(3);

    test(
      'letters: big letters for a pre-reader, small and neighbours after',
      () {
        final little = abcRound(1, AgeBand.b4to6, rng, icons);
        expect(little.cards, hasLength(3));
        expect(
          little.cards.every((c) => c.text == c.text!.toUpperCase()),
          isTrue,
        );
        expect(little.prompt, startsWith('Find the letter '));
        expect(
          little.cards[little.correct].text,
          little.prompt.split(' ').last,
        );

        final small = abcRound(1, AgeBand.b7to8, rng, icons);
        expect(small.cards, hasLength(4));
        expect(
          small.cards.every((c) => c.text == c.text!.toLowerCase()),
          isTrue,
        );

        final after = abcRound(3, AgeBand.b7to8, rng, icons);
        expect(after.prompt, contains('comes'));

        final starts = abcRound(1, AgeBand.b9to11, rng, icons);
        expect(starts.prompt, startsWith('Which one starts with '));
        final letter = starts.prompt
            .split(' ')
            .last
            .replaceAll('?', '')
            .toLowerCase();
        expect(starts.cards[starts.correct].label!.startsWith(letter), isTrue);
        expect(
          starts.cards.where((c) => c.label!.startsWith(letter)),
          hasLength(1),
          reason: 'only one card may start with the letter',
        );
      },
    );

    test('numbers: counting, then plus and minus, then times and sharing', () {
      final count = sumsRound(1, AgeBand.b4to6, rng, icons);
      expect(count.showing, isNotEmpty);
      expect(count.showing.length, lessThanOrEqualTo(3));
      expect(count.cards.every((c) => c.isPicture), isTrue);
      expect(
        count.cards[count.correct].iconId,
        endsWith(['one', 'two', 'three'][count.showing.length - 1]),
      );

      final easy = sumsRound(1, AgeBand.b7to8, rng, icons);
      expect(easy.prompt, anyOf(contains('+'), contains('−')));
      final right = int.parse(easy.cards[easy.correct].text!);
      final parts = easy.prompt.replaceAll(' = ?', '').split(' ');
      final a = int.parse(parts[0]);
      final b = int.parse(parts[2]);
      expect(right, parts[1] == '+' ? a + b : a - b);
      expect(
        easy.cards.map((c) => c.text).toSet(),
        hasLength(3),
        reason: 'no two answers alike',
      );

      final times = sumsRound(2, AgeBand.b9to11, rng, icons);
      expect(times.prompt, contains('×'));
      final hard = [
        for (var i = 0; i < 10; i++) sumsRound(5, AgeBand.b9to11, rng, icons),
      ];
      expect(hard.any((r) => r.prompt.contains('÷')), isTrue);
      for (final r in hard) {
        if (!r.prompt.contains('÷')) continue;
        final p = r.prompt.replaceAll(' = ?', '').split(' ');
        expect(
          int.parse(r.cards[r.correct].text!),
          int.parse(p[0]) ~/ int.parse(p[2]),
        );
        expect(
          int.parse(p[0]) % int.parse(p[2]),
          0,
          reason: 'sharing comes out whole',
        );
      }
    });

    test('guess: a sound for a pre-reader, a fact for the older', () {
      final little = guessAnimalRound(1, AgeBand.b4to6, rng, icons);
      expect(little.cards, hasLength(3));
      expect(little.prompt, endsWith('Who am I?'));
      final big = guessAnimalRound(4, AgeBand.b9to11, rng, icons);
      expect(big.cards, hasLength(4));
      expect(
        big.cards.every((c) => c.isPicture && c.label!.isNotEmpty),
        isTrue,
      );
    });

    test('spot: the crowd grows with the band', () {
      expect(spotAnimalRound(1, AgeBand.b4to6, rng, icons).cards, hasLength(4));
      expect(spotAnimalRound(1, AgeBand.b7to8, rng, icons).cards, hasLength(6));
      final big = spotAnimalRound(4, AgeBand.b9to11, rng, icons);
      expect(big.cards, hasLength(12));
      expect(big.cards.map((c) => c.iconId).toSet(), hasLength(12));
      final name = big.prompt.replaceAll('Find the ', '').replaceAll('!', '');
      expect(big.cards[big.correct].iconId, 'icon_$name');
    });
  });

  group('on the table', () {
    testWidgets('a reader sees the question; a pre-reader hears it', (
      tester,
    ) async {
      await start(tester, reader, PlayGame.abc);
      expect(find.byKey(const Key('quiz-prompt')), findsOneWidget);
      expect(find.byKey(const Key('quiz-card-0')), findsOneWidget);
      await tearDownGame(tester);

      await start(tester, preReader, PlayGame.abc);
      expect(find.byKey(const Key('quiz-prompt')), findsNothing);
      expect(find.byKey(const Key('quiz-card-0')), findsOneWidget);
      await tearDownGame(tester);
    });

    testWidgets('the right card earns a star and the next round comes', (
      tester,
    ) async {
      await start(tester, reader, PlayGame.sums);
      final first = roundOf(tester);
      await tester.tap(find.byKey(Key('quiz-card-${first.correct}')));
      await tester.pump();
      expect(find.byKey(const Key('round-star-0-on')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1700));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(QuizGameState.settle * 2);
      expect(gateway.lastPlayTurn!.round, 2);
      expect(
        gateway.lastPlayTurn!.level,
        2,
        reason: 'a first-try win goes up a level',
      );
      expect(roundOf(tester), isNot(same(first)));
      await tearDownGame(tester);
    });

    testWidgets('two wrong cards and the right one shows itself', (
      tester,
    ) async {
      await start(tester, older, PlayGame.spotAnimal);
      final r = roundOf(tester);
      final wrong = [
        for (var i = 0; i < r.cards.length; i++)
          if (i != r.correct) i,
      ];
      await tester.tap(find.byKey(Key('quiz-card-${wrong[0]}')));
      await tester.pump();
      await tester.tap(find.byKey(Key('quiz-card-${wrong[1]}')));
      await tester.pump();
      expect(find.byKey(const Key('round-star-0-on')), findsNothing);
      // The right card is now bordered in mango: the hint.
      final hinted = tester.widget<Container>(
        find
            .descendant(
              of: find.byKey(Key('quiz-card-${r.correct}')),
              matching: find.byType(Container),
            )
            .first,
      );
      expect((hinted.decoration as BoxDecoration).border, isNotNull);
      await tester.tap(find.byKey(Key('quiz-card-${r.correct}')));
      await tester.pump();
      expect(find.byKey(const Key('round-star-0-on')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1700));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        gateway.lastPlayTurn!.level,
        1,
        reason: 'three tries is a struggle; level stays at the floor',
      );
      await tearDownGame(tester);
    });

    testWidgets('five rounds end the game with five stars', (tester) async {
      await start(tester, preReader, PlayGame.guessAnimal);
      for (var i = 0; i < roundsPerGame; i++) {
        await tester.tap(
          find.byKey(Key('quiz-card-${roundOf(tester).correct}')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1700));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(QuizGameState.settle * 2);
      }
      expect(gateway.lastPlayTurn!.done, isTrue);
      for (var i = 0; i < roundsPerGame; i++) {
        expect(find.byKey(Key('round-star-$i-on')), findsOneWidget);
      }
      expect(find.byKey(const Key('game-again')), findsOneWidget);
      await tearDownGame(tester);
    });

    testWidgets('the picker offers all eight games', (tester) async {
      await tester.pumpWidget(host(PlayScreen(kid: reader)));
      await tester.pump();
      for (final k in [
        'find',
        'catch',
        'memory',
        'pop',
        'abc',
        'sums',
        'guess',
        'spot',
      ]) {
        expect(find.byKey(Key('game-$k')), findsOneWidget, reason: k);
      }
      for (final (k, game) in [
        ('abc', PlayGame.abc),
        ('sums', PlayGame.sums),
        ('guess', PlayGame.guessAnimal),
        ('spot', PlayGame.spotAnimal),
      ]) {
        await tester.tap(find.byKey(Key('game-$k')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.widget<QuizGame>(find.byType(QuizGame)).game, game);
        // Back to the picker.
        await tester.tap(find.byIcon(Icons.arrow_back_rounded).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('game-find')), findsOneWidget);
      }

      // Memory game picker navigation
      await tester.tap(find.byKey(const Key('game-memory')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(MemoryGame), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('game-find')), findsOneWidget);

      // Balloon pop picker navigation
      await tester.tap(find.byKey(const Key('game-pop')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(BalloonPopGame), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('game-find')), findsOneWidget);

      await tearDownGame(tester);
    });
  });
}

class _SilentVoice extends GilliVoice {
  @override
  Future<void> say({
    required String url,
    String? fallbackText,
    String language = 'en',
    bool slow = false,
  }) async {}

  @override
  Future<void> stop() async {}
}
