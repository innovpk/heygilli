import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/icon_library.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/speech.dart';
import 'package:heygilli/features/kid/games/balloon_pop_game.dart';
import 'package:heygilli/features/kid/games/memory_game.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late FakeGateway gateway;
  late AppState app;
  late IconLibrary icons;
  late Kid reader;

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

  group('MemoryGame (Flip & Match)', () {
    testWidgets('renders memory cards and flips on tap', (tester) async {
      await tester.pumpWidget(
        host(
          MemoryGame(
            kid: reader,
            onBack: () {},
            onAgain: () {},
            onHome: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      // There should be memory cards on screen
      expect(find.byKey(const Key('memory-card-0')), findsOneWidget);
      expect(find.byKey(const Key('memory-card-1')), findsOneWidget);

      // Tap card 0 to flip it
      await tester.tap(find.byKey(const Key('memory-card-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Tap card 1 to flip it
      await tester.tap(find.byKey(const Key('memory-card-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tearDownGame(tester);
    });
  });

  group('BalloonPopGame (Pop & Play)', () {
    testWidgets('renders balloons and pops on tap', (tester) async {
      await tester.pumpWidget(
        host(
          BalloonPopGame(
            kid: reader,
            onBack: () {},
            onAgain: () {},
            onHome: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Check for balloon tap targets
      final balloons = find.byType(GestureDetector);
      expect(balloons, findsWidgets);

      // Advance frames so balloons float smoothly
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      // Pop the first balloon found
      final firstBalloon = find.byKey(const Key('balloon-0'));
      if (firstBalloon.evaluate().isNotEmpty) {
        await tester.tap(firstBalloon);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await tearDownGame(tester);
    });
  });
}

class _SilentVoice extends GilliVoice {
  @override
  Future<void> speak(
    String text, {
    String? audioUrl,
    bool slow = false,
    String? voice,
  }) async {}
}
