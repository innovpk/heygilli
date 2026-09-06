import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/analytics.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/protocol.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/progress_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Revisiting a shaky concept (PROTOCOL "Revisiting a shaky concept").
///
/// One rule outranks everything else here: a child is never told they are
/// being retested. The `revisit` field is bookkeeping for the parent's
/// screen, and these tests fail if it ever changes a word a child hears, a
/// pixel a child sees, or turns up in the kid-facing code at all.
Map<String, dynamic> _ask({Map<String, dynamic>? revisit}) => {
  't': 'ask',
  'q': 2,
  'type': 'why',
  'input': 'voice',
  'text': 'Why does the moon look different tonight?',
  'text_ur': 'آج رات چاند مختلف کیوں لگ رہا ہے؟',
  'speak': 'Why does the moon look different tonight?',
  'tts_url': 'http://h/tts/abc.mp3',
  'listen_ms': 8000,
  'gesture': 'think',
  'revisit': ?revisit,
};

void main() {
  group('the revisit field', () {
    test('is read off the ask', () {
      final a =
          ServerMessage.decode(
                jsonEncode(
                  _ask(
                    revisit: {
                      'concept': 'Why the moon changes shape',
                      'last_seen': '2026-09-01',
                    },
                  ),
                ),
              )
              as AskMessage;

      expect(a.revisit?.concept, 'Why the moon changes shape');
      expect(a.revisit?.lastSeen, '2026-09-01');
    });

    test('changes nothing the child hears, sees or waits through', () {
      final plain = ServerMessage.decode(jsonEncode(_ask())) as AskMessage;
      final revisited =
          ServerMessage.decode(
                jsonEncode(_ask(revisit: {'concept': 'Moon phases'})),
              )
              as AskMessage;

      // Same question, same voice line, same window. The only difference
      // between these two on a child's screen is nothing at all.
      expect(revisited.text, plain.text);
      expect(revisited.textUr, plain.textUr);
      expect(revisited.speak, plain.speak);
      expect(revisited.fallbackSpeech, plain.fallbackSpeech);
      expect(revisited.ttsUrl, plain.ttsUrl);
      expect(revisited.listenMs, plain.listenMs);
      expect(revisited.gesture, plain.gesture);
      expect(revisited.type, plain.type);
    });

    test('is null on an ordinary question, which is nearly all of them', () {
      final a = ServerMessage.decode(jsonEncode(_ask())) as AskMessage;
      expect(a.revisit, isNull);
    });

    test('a revisit with no concept in it is not a revisit', () {
      expect(QuestionRevisit.fromJson(null), isNull);
      expect(QuestionRevisit.fromJson(const {}), isNull);
      expect(QuestionRevisit.fromJson(const {'concept': ''}), isNull);
      expect(QuestionRevisit.fromJson('moon'), isNull);
    });
  });

  group('the kid side', () {
    test('never mentions a revisit anywhere in its own code', () {
      // Blunt on purpose. A child noticing they are being retested is the
      // failure mode this whole mechanism is designed around, so the rule is
      // enforced on the source rather than left to whoever edits these
      // screens next. If a kid screen ever needs this word, that is a
      // decision to argue for, not to slip in.
      final offenders = <String>[];
      for (final f in Directory('lib/features/kid').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (f.readAsStringSync().toLowerCase().contains('revisit')) {
          offenders.add(f.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'a child-facing screen refers to revisits: nothing a child sees '
            'or hears may hint that a question is a retest',
      );
    });
  });

  group('RevisitConcept', () {
    test('parses the parent-side shape', () {
      final r = RevisitConcept.fromJson({
        'concept': 'Why the moon changes shape',
        'times_shaky': 4,
        'last_seen': '2026-09-03',
        'asked_again': 2,
      });

      expect(r.concept, 'Why the moon changes shape');
      expect(r.timesShaky, 4);
      expect(r.askedAgain, 2);
      expect(r.waiting, isFalse);
    });

    test('nothing come back to yet is waiting, not failing', () {
      // At most one revisit fits in a session and never as the first
      // question, so a concept can sit here for days before its turn.
      final r = RevisitConcept.fromJson({'concept': 'Moon phases'});
      expect(r.askedAgain, 0);
      expect(r.waiting, isTrue);
    });
  });

  group('FakeGateway revisits', () {
    late FakeGateway gateway;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      gateway = FakeGateway();
      await gateway.signInDev('parent');
    });

    test('lines up with what analytics called shaky', () async {
      final kid = await gateway.createKid(
        nickname: 'Bilal',
        age: 10,
        languages: const ['en'],
      );

      final revisits = await gateway.revisits(kid.id);
      final analytics = await gateway.analytics(kid.id);

      expect(revisits, isNotEmpty);
      expect(
        revisits.map((r) => r.concept),
        analytics.needsAnotherLook.map((s) => s.concept),
      );
    });

    test('a kid with nothing shaky has nothing to come back to', () async {
      final kid = await gateway.createKid(
        nickname: 'Ayla',
        age: 5,
        languages: const ['en'],
      );

      expect(await gateway.revisits(kid.id), isEmpty);
    });
  });

  group('the parent sees it, the child does not', () {
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
        age: 10,
        languages: const ['en'],
      );
    });

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 3600);
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

    testWidgets('the concepts being come back to are on the parent screen', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('COMING BACK TO THESE'), findsOneWidget);
      expect(find.text('Why the moon changes shape'), findsWidgets);
    });

    testWidgets('and the parent is told what it looks like from the sofa', (
      tester,
    ) async {
      await open(tester);

      expect(
        find.textContaining('never as "remember when you got this wrong"'),
        findsOneWidget,
      );
      expect(
        find.textContaining("nothing on Bilal's screen says it is a repeat"),
        findsOneWidget,
      );
    });
  });
}
