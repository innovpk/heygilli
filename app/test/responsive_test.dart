import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/responsive.dart';
import 'package:heygilli/core/theme.dart';

/// Using the width for something, rather than stretching a phone screen.
void main() {
  _closing();

  Future<void> pumpAt(WidgetTester tester, Size size, Widget child) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pump();
  }

  group('a modal goes where the person is looking', () {
    Widget opener() => Builder(
      builder: (context) => TextButton(
        onPressed: () => showHgModal<void>(
          context,
          builder: (_) => const SizedBox(height: 200, child: Text('form')),
        ),
        child: const Text('open'),
      ),
    );

    testWidgets('a phone gets a sheet from the bottom', (tester) async {
      await pumpAt(tester, const Size(420, 900), opener());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('form'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('a wide window gets a dialog, not a strip at the bottom edge', (
      tester,
    ) async {
      await pumpAt(tester, const Size(1600, 1000), opener());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('form'), findsOneWidget);
      expect(
        find.byType(Dialog),
        findsOneWidget,
        reason: 'a bottom sheet on a 1000px window arrives below the fold',
      );
      // And it is centred rather than pinned to the bottom.
      final box = tester.getRect(find.text('form'));
      expect(box.center.dy, lessThan(800));
    });
  });

  group('cards use the width', () {
    List<Widget> cards() => const [
      SizedBox(height: 100, child: Text('one')),
      SizedBox(height: 100, child: Text('two')),
      SizedBox(height: 100, child: Text('three')),
    ];

    testWidgets('one column on a phone', (tester) async {
      await pumpAt(
        tester,
        const Size(420, 1400),
        HgCardColumns(children: cards()),
      );
      final one = tester.getRect(find.text('one'));
      final two = tester.getRect(find.text('two'));
      expect(two.top, greaterThan(one.bottom), reason: 'stacked, in order');
    });

    testWidgets('two columns once there is room for two readable ones', (
      tester,
    ) async {
      await pumpAt(
        tester,
        const Size(1400, 1000),
        HgCardColumns(children: cards()),
      );
      final one = tester.getRect(find.text('one'));
      final two = tester.getRect(find.text('two'));
      expect(
        two.left,
        greaterThan(one.right),
        reason:
            'a parent should not scroll past one card to reach the next '
            'on a window with room for both',
      );
      // Third goes back to the left column: filling in order, not by height.
      final three = tester.getRect(find.text('three'));
      expect(three.left, one.left);
      expect(three.top, greaterThan(one.bottom));
    });

    testWidgets('a single card never becomes a half-width column', (
      tester,
    ) async {
      await pumpAt(
        tester,
        const Size(1400, 1000),
        const HgCardColumns(
          children: [SizedBox(height: 100, child: Text('only'))],
        ),
      );
      expect(tester.getRect(find.text('only')).width, greaterThan(600));
    });

    testWidgets('the breakpoint is the app-wide one, not a local guess', (
      tester,
    ) async {
      await pumpAt(
        tester,
        Size(HgLayout.wideBreakpoint - 1, 1400),
        HgCardColumns(children: cards()),
      );
      final one = tester.getRect(find.text('one'));
      final two = tester.getRect(find.text('two'));
      expect(two.top, greaterThan(one.bottom));
    });
  });
}

/// Closing is half of a modal. A dialog that saves and stays open leaves the
/// parent looking at a form they have already submitted, with the result
/// behind it.
void _closing() {
  testWidgets('a wide-window modal pops and returns its value', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    String? got = 'not yet';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                got = await showHgModal<String>(
                  context,
                  builder: (_) => Builder(
                    builder: (inner) => TextButton(
                      onPressed: () => Navigator.of(inner).pop('saved'),
                      child: const Text('save'),
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();

    expect(find.text('save'), findsNothing, reason: 'the modal stayed open');
    expect(got, 'saved');
  });
}
