import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/protocol.dart';
import 'package:heygilli/features/kid/gilli_widget.dart';

/// Gilli celebrates an answer that landed.
///
/// A hop on its own was easy to miss from across a sofa. A correct answer now
/// throws stars and confetti out around him while he cheers, drawn rather than
/// written so it says the same thing to a child who cannot read yet.
final _burst = find.byKey(const Key('gilli-celebration'));

Widget _gilli(int tick, {bool calm = false, bool asleep = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: calm),
        child: Scaffold(
          body: Center(
            child: GilliWidget(
              size: 160,
              gesture: Gesture.cheer,
              celebrateTick: tick,
              asleep: asleep,
            ),
          ),
        ),
      ),
    );

void main() {
  group('which answers Gilli celebrates', () {
    test('correct and partial, the two the gateway scores as success', () {
      expect(AnswerResult.correct.celebrates, isTrue);
      expect(AnswerResult.partial.celebrates, isTrue);
    });

    test('never a miss, a mumble or a silence', () {
      // Nobody is told they are wrong, but nobody is cheered for nothing
      // either: Gilli just says the answer and moves on.
      expect(AnswerResult.offTopic.celebrates, isFalse);
      expect(AnswerResult.unclear.celebrates, isFalse);
      expect(AnswerResult.silence.celebrates, isFalse);
    });
  });

  group('the burst', () {
    testWidgets('nothing until an answer lands', (tester) async {
      await tester.pumpWidget(_gilli(0));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_burst, findsNothing);
    });

    testWidgets('bursts when the tick moves, then clears away', (tester) async {
      await tester.pumpWidget(_gilli(0));
      await tester.pumpWidget(_gilli(1));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        _burst,
        findsOneWidget,
        reason: 'no celebration for a right answer',
      );

      await tester.pump(const Duration(milliseconds: 1400));
      expect(_burst, findsNothing, reason: 'the confetti never cleared');
    });

    testWidgets('a second right answer celebrates again', (tester) async {
      await tester.pumpWidget(_gilli(0));
      await tester.pumpWidget(_gilli(1));
      await tester.pump(const Duration(milliseconds: 1600));
      expect(_burst, findsNothing);

      await tester.pumpWidget(_gilli(2));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_burst, findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a tap goes straight through it', (tester) async {
      await tester.pumpWidget(_gilli(0));
      await tester.pumpWidget(_gilli(1));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.ancestor(of: _burst, matching: find.byType(IgnorePointer)),
        findsWidgets,
      );
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('not when the device asks for less motion', (tester) async {
      await tester.pumpWidget(_gilli(0, calm: true));
      await tester.pumpWidget(_gilli(1, calm: true));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_burst, findsNothing);
    });

    testWidgets('not while Gilli is asleep', (tester) async {
      await tester.pumpWidget(_gilli(0, asleep: true));
      await tester.pumpWidget(_gilli(1, asleep: true));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_burst, findsNothing);
    });
  });
}
