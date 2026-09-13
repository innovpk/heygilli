import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/speech.dart';
import 'package:heygilli/features/kid/home_screen.dart';
import 'package:heygilli/features/kid/kid_background.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late FakeGateway gateway;
  late AppState app;
  late LocalSettings settings;
  late Kid kid1;
  late Kid kid2;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    settings = await LocalSettings.load();
    app = AppState(gateway: gateway, settings: settings);
    kid1 = await gateway.createKid(
      nickname: 'Rayan',
      age: 9,
      languages: const ['en'],
    );
    kid2 = await gateway.createKid(
      nickname: 'Lisa',
      age: 5,
      languages: const ['en'],
    );
  });

  group('KidBackgroundTheme & Persistence', () {
    test('all 5 themes exist with valid attributes', () {
      expect(KidBackgroundTheme.values.length, 5);
      final ids = KidBackgroundTheme.values.map((t) => t.id).toSet();
      expect(ids, {'cosmic', 'ocean', 'jungle', 'sunset', 'classic'});

      for (final theme in KidBackgroundTheme.values) {
        expect(theme.name.isNotEmpty, isTrue);
        expect(theme.emoji.isNotEmpty, isTrue);
        expect(theme.gradient.colors.isNotEmpty, isTrue);
      }
    });

    test('fromId defaults gracefully to cosmic', () {
      expect(KidBackgroundTheme.fromId(null), KidBackgroundTheme.cosmic);
      expect(KidBackgroundTheme.fromId('unknown'), KidBackgroundTheme.cosmic);
      expect(KidBackgroundTheme.fromId('ocean'), KidBackgroundTheme.ocean);
      expect(KidBackgroundTheme.fromId('jungle'), KidBackgroundTheme.jungle);
      expect(KidBackgroundTheme.fromId('sunset'), KidBackgroundTheme.sunset);
      expect(KidBackgroundTheme.fromId('classic'), KidBackgroundTheme.classic);
    });

    test('settings and app state persist background choice per kid', () async {
      expect(app.kidBackground(kid1.id), 'cosmic');
      expect(app.kidBackground(kid2.id), 'cosmic');

      bool notified = false;
      app.addListener(() => notified = true);

      await app.setKidBackground(kid1.id, 'ocean');
      expect(notified, isTrue);
      expect(app.kidBackground(kid1.id), 'ocean');
      expect(settings.kidBackground(kid1.id), 'ocean');
      // Sibling choice remains independent
      expect(app.kidBackground(kid2.id), 'cosmic');

      await app.setKidBackground(kid2.id, 'jungle');
      expect(app.kidBackground(kid2.id), 'jungle');
      expect(app.kidBackground(kid1.id), 'ocean');
    });
  });

  group('KidBackground widget & CustomPainter', () {
    testWidgets('paints all 5 themes without runtime errors on phone and tablet sizes', (
      tester,
    ) async {
      for (final theme in KidBackgroundTheme.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 500,
                child: KidBackground(
                  theme: theme,
                  child: const Center(child: Text('Shelf Content')),
                ),
              ),
            ),
          ),
        );
        expect(find.text('Shelf Content'), findsOneWidget);
        expect(find.byType(KidBackground), findsOneWidget);

        // Also test miniature thumbnail version
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 120,
                height: 90,
                child: KidBackgroundThumbnail(theme: theme),
              ),
            ),
          ),
        );
        expect(find.byType(KidBackgroundThumbnail), findsOneWidget);
      }
    });
  });

  group('KidHomeScreen background button & modal picker', () {
    Future<void> openShelf(WidgetTester tester, Kid kid) async {
      app.enterKidMode(kid);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: app),
            ChangeNotifierProvider<GilliVoice>(create: (_) => _SilentVoice()),
          ],
          child: const MaterialApp(home: KidHomeScreen()),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    testWidgets('kid shelf shows background button in header', (tester) async {
      await openShelf(tester, kid1);

      expect(find.byKey(const Key('pick-background')), findsOneWidget);
      expect(find.bySemanticsLabel('Change background'), findsOneWidget);
    });

    testWidgets('tapping background button opens theme picker with all 5 themes', (
      tester,
    ) async {
      await openShelf(tester, kid1);

      await tester.tap(find.byKey(const Key('pick-background')));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      expect(find.text('Choose your background'), findsOneWidget);
      expect(find.text('Space'), findsOneWidget);
      expect(find.text('Ocean'), findsOneWidget);
      expect(find.text('Jungle'), findsOneWidget);
      expect(find.text('Sunset'), findsOneWidget);
      expect(find.text('Classic'), findsOneWidget);
    });

    testWidgets('tapping a theme card updates active background and persists choice', (
      tester,
    ) async {
      await openShelf(tester, kid1);

      // Open background picker
      await tester.tap(find.byKey(const Key('pick-background')));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      // Tap "Ocean" theme
      await tester.tap(find.text('Ocean'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      // Modal is dismissed
      expect(find.text('Choose your background'), findsNothing);

      // App state and settings have updated to ocean
      expect(app.kidBackground(kid1.id), 'ocean');
      expect(settings.kidBackground(kid1.id), 'ocean');

      // The background widget on the shelf now renders the ocean theme
      final bg = tester.widget<KidBackground>(find.byType(KidBackground));
      expect(bg.theme, KidBackgroundTheme.ocean);
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
