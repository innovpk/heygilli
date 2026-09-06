import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/analytics.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/protocol.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/speech.dart';
import 'package:heygilli/features/parent/progress_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bilingual word seeding (PROTOCOL "Bilingual word seeding").
///
/// The awkward part of this feature is not the wire type, it is the device:
/// Polly has no Urdu voice, so an Urdu term is only ever spoken by the phone
/// itself. A phone with no Urdu voice must fall back to the English question
/// with no seed — never to a silent gap where a word should have been.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Stands in for the platform TTS engine, so both answers to "can this
  /// device say Urdu" can be tested. Records what was actually spoken.
  final spoken = <String>[];
  var urduInstalled = true;

  const channel = MethodChannel('flutter_tts');

  setUp(() {
    spoken.clear();
    urduInstalled = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'isLanguageAvailable':
              return call.arguments == 'ur-PK' ? urduInstalled : true;
            case 'speak':
              spoken.add('${call.arguments}');
              // The engine calls back when it finishes; without that the
              // voice waits out its own 20-second safety timeout.
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .handlePlatformMessage(
                    channel.name,
                    const StandardMethodCodec().encodeMethodCall(
                      const MethodCall('speak.onComplete'),
                    ),
                    (_) {},
                  );
              return 1;
            default:
              return 1;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('the word on a question', () {
    test('is read off the ask', () {
      final a =
          ServerMessage.decode(
                jsonEncode({
                  't': 'ask',
                  'q': 1,
                  'type': 'why',
                  'input': 'voice',
                  'text': 'Why did the lava come out?',
                  'tts_url': '',
                  'listen_ms': 8000,
                  'gesture': 'think',
                  'word': {
                    'term': 'آتش فشاں',
                    'language': 'ur',
                    'gloss': 'volcano',
                    'first_heard': true,
                  },
                }),
              )
              as AskMessage;

      expect(a.word?.term, 'آتش فشاں');
      expect(a.word?.isUrdu, isTrue);
      expect(a.word?.gloss, 'volcano');
      expect(a.word?.firstHeard, isTrue);
    });

    test('is null on the questions that carry none, which is most', () {
      final a =
          ServerMessage.decode(jsonEncode({'t': 'ask', 'q': 0, 'tts_url': ''}))
              as AskMessage;
      expect(a.word, isNull);
    });

    test('a word with no term in it is not a word', () {
      // Otherwise Gilli pauses to teach nothing.
      expect(SeededWord.fromJson(const {'term': '  '}), isNull);
      expect(SeededWord.fromJson(const {'language': 'ur'}), isNull);
      expect(SeededWord.fromJson(null), isNull);
    });
  });

  group('saying it on a device', () {
    test(
      'an Urdu term is spoken by the phone, since Polly has no voice',
      () async {
        final voice = GilliVoice();
        addTearDown(voice.dispose);

        final said = await voice.saySeed(
          const SeededWord(term: 'بادل', gloss: 'cloud'),
        );

        expect(said, isTrue);
        expect(spoken, ['بادل']);
      },
    );

    test('a phone with no Urdu voice gets no seed, not a silent gap', () async {
      urduInstalled = false;
      final voice = GilliVoice();
      addTearDown(voice.dispose);

      final said = await voice.saySeed(
        const SeededWord(term: 'بادل', gloss: 'cloud'),
      );

      // The caller then behaves as if the question had carried no word at
      // all: the English question was already asked and stands on its own.
      expect(said, isFalse);
      expect(spoken, isEmpty);
    });

    test('an engine that cannot answer counts as no voice', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'no_engine');
          });
      final voice = GilliVoice();
      addTearDown(voice.dispose);

      expect(await voice.canSpeak('ur'), isFalse);
      expect(await voice.saySeed(const SeededWord(term: 'بادل')), isFalse);
    });
  });

  group('WordSeed', () {
    test('emerging is exactly a seed nobody has said back', () {
      // PROTOCOL: the parent's vocabulary list and this are the same data.
      final heard = WordSeed.fromJson({'term': 'چاند', 'times_heard': 2});
      final said = WordSeed.fromJson({
        'term': 'بادل',
        'times_heard': 4,
        'times_said': 2,
      });

      expect(heard.emerging, isTrue);
      expect(said.emerging, isFalse);
    });
  });

  group('FakeGateway words', () {
    late FakeGateway gateway;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      gateway = FakeGateway();
      await gateway.signInDev('parent');
    });

    test('a household with one language is offered nothing', () async {
      final kid = await gateway.createKid(
        nickname: 'Zoya',
        age: 8,
        languages: const ['en'],
      );

      // Not an empty state to apologise for: seeding is opt-in by virtue of
      // the language list.
      expect(await gateway.words(kid.id), isEmpty);
    });

    test('a bilingual kid has words, some come back and some not', () async {
      final kid = await gateway.createKid(
        nickname: 'Bilal',
        age: 9,
        languages: const ['en', 'ur'],
      );

      final words = await gateway.words(kid.id);
      expect(words, isNotEmpty);
      expect(words.every((w) => w.language == 'ur'), isTrue);
      expect(words.every((w) => w.gloss.isNotEmpty), isTrue);
      expect(words.any((w) => w.emerging), isTrue);
      expect(words.any((w) => !w.emerging), isTrue);
    });
  });

  group('the parent screen', () {
    late FakeGateway gateway;
    late AppState app;
    late Kid kid;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      gateway = FakeGateway();
      await gateway.signInDev('parent');
      app = AppState(gateway: gateway, settings: await LocalSettings.load());
      kid = await gateway.createKid(
        nickname: 'Bilal',
        age: 9,
        languages: const ['en', 'ur'],
      );
    });

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(home: ProgressScreen(kid: kid)),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    testWidgets('shows the words and what each one has done so far', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('URDU WORDS GILLI HAS OFFERED'), findsOneWidget);
      expect(find.text('volcano'), findsOneWidget);
      expect(find.textContaining('not said back yet'), findsWidgets);
    });

    testWidgets('and why a phone might not offer one at all', (tester) async {
      await open(tester);

      // The one thing a parent could not work out for themselves: their
      // phone's voices decide whether this happens.
      expect(find.textContaining('no Urdu voice installed'), findsOneWidget);
      expect(
        find.textContaining('One new word a session at most'),
        findsOneWidget,
      );
    });
  });
}
