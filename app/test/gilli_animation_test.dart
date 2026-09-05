import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/protocol.dart';
import 'package:heygilli/features/kid/gilli_widget.dart';

/// Every layer asset currently on screen, in paint order.
List<String> _layers(WidgetTester tester) => tester
    .widgetList<SvgPicture>(find.byType(SvgPicture))
    .map((p) => (p.bytesLoader as SvgAssetLoader).assetName)
    .toList();

/// The rotation/scale actually applied to a named layer this frame.
Matrix4 _transformAbove(WidgetTester tester, String asset) {
  final svg = find.byWidgetPredicate(
    (w) => w is SvgPicture && (w.bytesLoader as SvgAssetLoader).assetName == asset,
  );
  return tester
      .widgetList<Transform>(
        find.ancestor(of: svg, matching: find.byType(Transform)),
      )
      .first
      .transform;
}

Widget _host({bool talking = false, Gesture gesture = Gesture.idle}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: GilliWidget(size: 200, talking: talking, gesture: gesture),
        ),
      ),
    );

void main() {
  group('Gilli is drawn in parts', () {
    testWidgets('body, tail, ears, head, eyes and a mouth all render', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      await tester.pump(const Duration(milliseconds: 16));

      final layers = _layers(tester);
      expect(layers, contains('assets/gilli/tail.svg'));
      expect(layers, contains('assets/gilli/body.svg'));
      expect(layers, contains('assets/gilli/ear_left.svg'));
      expect(layers, contains('assets/gilli/ear_right.svg'));
      expect(layers, contains('assets/gilli/head.svg'));
      expect(layers, contains('assets/gilli/eyes.svg'));
      // Exactly one mouth at a time, never both.
      expect(
        layers.where((l) => l.contains('mouth')).length,
        1,
        reason: 'both mouth layers were drawn at once',
      );
    });

    testWidgets('the tail is somewhere else a second later', (tester) async {
      await tester.pumpWidget(_host());
      await tester.pump(const Duration(milliseconds: 16));
      final before = _transformAbove(tester, 'assets/gilli/tail.svg');

      await tester.pump(const Duration(milliseconds: 700));
      final after = _transformAbove(tester, 'assets/gilli/tail.svg');

      expect(after, isNot(before), reason: 'the tail never moved');
    });

    testWidgets('the eyes change shape across the blink cycle', (tester) async {
      await tester.pumpWidget(_host());
      await tester.pump(const Duration(milliseconds: 16));

      final seen = <double>{};
      for (var i = 0; i < 44; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        seen.add(_transformAbove(tester, 'assets/gilli/eyes.svg').entry(1, 1));
      }

      // Open for most of the cycle, so a blink shows up as a smaller value.
      expect(seen.reduce((a, b) => a > b ? a : b), closeTo(1, 0.001));
      expect(
        seen.reduce((a, b) => a < b ? a : b),
        lessThan(0.9),
        reason: 'the eyes never closed',
      );
    });
  });

  group('the mouth follows the voice', () {
    testWidgets('closed while Gilli is quiet', (tester) async {
      await tester.pumpWidget(_host());
      await tester.pump(const Duration(milliseconds: 16));

      expect(_layers(tester), contains('assets/gilli/mouth_closed.svg'));
      expect(_layers(tester), isNot(contains('assets/gilli/mouth_open.svg')));
    });

    testWidgets('opens and closes while talking', (tester) async {
      await tester.pumpWidget(_host(talking: true));

      final shapes = <String>{};
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 80));
        shapes.addAll(_layers(tester).where((l) => l.contains('mouth')));
      }

      expect(
        shapes,
        containsAll(<String>{
          'assets/gilli/mouth_open.svg',
          'assets/gilli/mouth_closed.svg',
        }),
        reason: 'the mouth did not move while talking',
      );
      await tester.pumpWidget(_host());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a roar holds the mouth open', (tester) async {
      await tester.pumpWidget(_host(gesture: Gesture.roar));
      await tester.pump(const Duration(milliseconds: 16));

      expect(_layers(tester), contains('assets/gilli/mouth_open.svg'));
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
