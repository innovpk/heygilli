import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/play.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/speech.dart';
import 'package:heygilli/features/kid/break_screen.dart';
import 'package:heygilli/features/kid/games/catch_gilli_game.dart';
import 'package:heygilli/features/kid/games/find_gilli_game.dart';
import 'package:heygilli/features/kid/home_screen.dart';
import 'package:heygilli/features/kid/sleepy_gilli.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Gilli naps, wakes when poked or pinched, and plays two games whose rounds
/// come from the Playmate agent (here, FakeGateway's copy of its rule).
void main() {
  late FakeGateway gateway;
  late AppState app;
  late Kid reader;
  late Kid preReader;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    reader = await gateway.createKid(
      nickname: 'Rayan',
      age: 9,
      languages: const ['en'],
    );
    preReader = await gateway.createKid(
      nickname: 'Lisa',
      age: 5,
      languages: const ['en'],
    );
  });

  Widget host(Widget child, {bool scaffold = true}) => MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<GilliVoice>(create: (_) => _SilentVoice()),
    ],
    child: MaterialApp(home: scaffold ? Scaffold(body: child) : child),
  );

  bool asleep(WidgetTester tester) =>
      tester.state<SleepyGilliState>(find.byType(SleepyGilli)).asleep;

  /// The games run on `Future.delayed`, which a disposed widget cannot
  /// cancel: run those out so the test ends with no timer pending.
  Future<void> tearDownGame(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  group('Gilli naps', () {
    testWidgets('he nods off when nobody touches him', (tester) async {
      await tester.pumpWidget(
        host(
          Center(
            child: SleepyGilli(
              kid: reader,
              size: 160,
              dozeAfter: const Duration(seconds: 5),
            ),
          ),
        ),
      );
      expect(asleep(tester), isFalse);
      expect(find.byKey(const Key('gilli-snore')), findsNothing);

      await tester.pump(const Duration(seconds: 6));
      expect(asleep(tester), isTrue);
      expect(find.byKey(const Key('gilli-snore')), findsOneWidget);
    });

    testWidgets('a tap wakes him', (tester) async {
      await tester.pumpWidget(
        host(Center(child: SleepyGilli(kid: reader, startAsleep: true))),
      );
      expect(asleep(tester), isTrue);

      await tester.tap(find.byType(SleepyGilli));
      await tester.pump();
      expect(asleep(tester), isFalse);
      expect(find.byKey(const Key('gilli-snore')), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a pinch wakes him', (tester) async {
      await tester.pumpWidget(
        host(
          Center(
            child: SleepyGilli(kid: preReader, size: 200, startAsleep: true),
          ),
        ),
      );
      final middle = tester.getCenter(find.byType(SleepyGilli));
      final a = await tester.startGesture(middle - const Offset(30, 0));
      final b = await tester.startGesture(middle + const Offset(30, 0));
      await tester.pump();
      await a.moveBy(const Offset(20, 0));
      await b.moveBy(const Offset(-20, 0));
      await tester.pump();
      await a.up();
      await b.up();
      await tester.pump();

      expect(asleep(tester), isFalse, reason: 'a pinch did not wake him');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('pinched while awake he squishes, and stays awake', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(Center(child: SleepyGilli(kid: reader, size: 200))),
      );
      final middle = tester.getCenter(find.byType(SleepyGilli));
      final a = await tester.startGesture(middle - const Offset(30, 0));
      final b = await tester.startGesture(middle + const Offset(30, 0));
      await tester.pump();
      await a.moveBy(const Offset(20, 0));
      await b.moveBy(const Offset(-20, 0));
      await a.up();
      await b.up();
      await tester.pump();
      expect(asleep(tester), isFalse);
      // A click is a pinch too, and it never takes him anywhere.
      await tester.tap(find.byType(SleepyGilli));
      await tester.pump();
      expect(asleep(tester), isFalse);
      expect(find.byType(SleepyGilli), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('at the end of the day he says goodnight and nods off', (
      tester,
    ) async {
      await tester.pumpWidget(host(DayDoneScreen(kid: reader)));
      await tester.pump();
      expect(asleep(tester), isFalse);

      await tester.pump(const Duration(seconds: 7));
      expect(asleep(tester), isTrue);

      await tester.tap(find.byType(SleepyGilli));
      await tester.pump();
      expect(asleep(tester), isFalse);
      await tester.pump(const Duration(seconds: 7));
      expect(asleep(tester), isTrue, reason: 'he stayed up after goodnight');
    });
  });

  testWidgets("a parent's notice does not follow them into kid mode", (
    tester,
  ) async {
    app.enterKidMode(reader);
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Moved to Shown'),
                  action: SnackBarAction(label: 'Undo', onPressed: () {}),
                ),
              );
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const KidHomeScreen()));
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('Moved to Shown'), findsNothing);
    expect(find.text('Undo'), findsNothing);
  });

  group('games', () {
    testWidgets('the games button opens his games; pinching Gilli does not', (
      tester,
    ) async {
      app.enterKidMode(reader);
      await tester.pumpWidget(host(const KidHomeScreen(), scaffold: false));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      // The day/night switch is gone from the shelf.
      expect(find.bySemanticsLabel('Switch to bright colours'), findsNothing);

      await tester.tap(find.byType(SleepyGilli));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('game-find')), findsNothing);

      await tester.tap(find.byKey(const Key('play-games')));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byKey(const Key('game-find')), findsOneWidget);
      expect(find.byKey(const Key('game-catch')), findsOneWidget);
      // Names under the pictures for a reader.
      expect(find.text('Find Gilli'), findsOneWidget);

      await tester.tap(find.byKey(const Key('game-catch')));
      await tester.pump();
      expect(find.byType(CatchGilliGame), findsOneWidget);
      // Back from a game is the picker, not the shelf.
      await tester.tap(find.bySemanticsLabel('Back'));
      await tester.pump();
      expect(find.byKey(const Key('game-find')), findsOneWidget);
      await tearDownGame(tester);
    });

    testWidgets('a pre-reader sees no words in the picker', (tester) async {
      app.enterKidMode(preReader);
      await tester.pumpWidget(host(const KidHomeScreen(), scaffold: false));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.tap(find.byKey(const Key('play-games')));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byKey(const Key('game-find')), findsOneWidget);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('find: the right tree shows him and brings the next round', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          FindGilliGame(
            kid: reader,
            onBack: () {},
            onAgain: () {},
            onHome: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final first = gateway.lastPlayTurn!;
      expect(first.round, 1);
      expect(find.byKey(const Key('round-star-0-off')), findsOneWidget);

      await tester.tap(
        find.byKey(Key('tree-${(first.spot + 1) % first.trees}')),
      );
      await tester.pump();
      expect(find.byKey(const Key('gilli-found')), findsNothing);

      await tester.tap(find.byKey(Key('tree-${first.spot}')));
      await tester.pump();
      expect(find.byKey(const Key('gilli-found')), findsOneWidget);
      expect(find.byKey(const Key('round-star-0-on')), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1700));
      await tester.pump(const Duration(milliseconds: 100));
      expect(gateway.lastPlayTurn!.round, 2);
      expect(find.byKey(const Key('gilli-found')), findsNothing);
      await tearDownGame(tester);
    });

    testWidgets('find: a pre-reader always gets his tail as a clue', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          FindGilliGame(
            kid: preReader,
            onBack: () {},
            onAgain: () {},
            onHome: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('gilli-tail')), findsOneWidget);
      expect(gateway.lastPlayTurn!.trees, lessThanOrEqualTo(4));
      await tearDownGame(tester);
    });

    testWidgets('find: five rounds, then stars and the way back', (
      tester,
    ) async {
      var home = 0;
      await tester.pumpWidget(
        host(
          FindGilliGame(
            kid: reader,
            onBack: () {},
            onAgain: () {},
            onHome: () => home++,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      for (var r = 0; r < roundsPerGame; r++) {
        await tester.tap(find.byKey(Key('tree-${gateway.lastPlayTurn!.spot}')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1700));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(gateway.lastPlayTurn!.done, isTrue);
      for (var i = 0; i < roundsPerGame; i++) {
        expect(find.byKey(Key('round-star-$i-on')), findsOneWidget);
      }
      expect(find.byKey(const Key('game-again')), findsOneWidget);
      await tester.tap(find.byKey(const Key('game-home')));
      expect(home, 1);
      await tearDownGame(tester);
    });

    testWidgets('catch: a tap or a click catches him', (tester) async {
      await tester.pumpWidget(
        host(
          CatchGilliGame(
            kid: reader,
            onBack: () {},
            onAgain: () {},
            onHome: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('catch-gilli')), findsNothing);

      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.byKey(const Key('catch-gilli')), findsOneWidget);
      expect(find.byKey(const Key('catch-dot-0-off')), findsOneWidget);

      await tester.tap(find.byKey(const Key('catch-gilli')));
      await tester.pump();
      expect(find.byKey(const Key('catch-dot-0-on')), findsOneWidget);
      expect(find.byKey(const Key('catch-gilli')), findsNothing);
      await tearDownGame(tester);
    });

    testWidgets('catch: he ducks away if nobody taps him', (tester) async {
      await tester.pumpWidget(
        host(
          CatchGilliGame(
            kid: reader,
            onBack: () {},
            onAgain: () {},
            onHome: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.byKey(const Key('catch-gilli')), findsOneWidget);

      await tester.pump(
        Duration(milliseconds: gateway.lastPlayTurn!.showMs + 50),
      );
      expect(find.byKey(const Key('catch-gilli')), findsNothing);
      expect(find.byKey(const Key('catch-dot-0-off')), findsOneWidget);
      await tearDownGame(tester);
    });
  });
}

/// Gilli with the sound off: these tests are about what a child sees.
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
