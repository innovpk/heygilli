import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/features/kid/session_screen.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

/// The half of "no YouTube branding in front of a child" that pointer events
/// cannot do.
///
/// `pointerEvents: none` keeps the pause overlay away because that overlay
/// answers a pointer. The poster — title, channel, share, "Watch on YouTube" —
/// is the state the embed is simply *in* before it plays, and no parameter
/// turns it off, so it has to be covered until the first frame arrives.
void main() {
  group('hasStarted', () {
    test('goes true on the first frame that plays', () {
      expect(hasStarted(false, PlayerState.unStarted), isFalse);
      expect(hasStarted(false, PlayerState.buffering), isFalse);
      expect(hasStarted(false, PlayerState.cued), isFalse);
      expect(hasStarted(false, PlayerState.playing), isTrue);
    });

    test('stays true once it is, through every pause Gilli makes', () {
      // The bite: a plain `state == playing` passes the test above and puts
      // the cover back over the video every time Gilli asks a question — which
      // is several times a video, in the middle of the thing the child is
      // watching.
      for (final state in PlayerState.values) {
        expect(
          hasStarted(true, state),
          isTrue,
          reason: 'the cover came back on $state',
        );
      }
    });
  });

  group('PosterCover', () {
    Widget host(ValueNotifier<bool> started) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: 320,
          height: 180,
          child: PosterCover(started: started, child: const Text('the embed')),
        ),
      ),
    );

    Finder cover() => find.byType(CircularProgressIndicator);

    Finder inCover(Type type) => find.descendant(
      of: find.byType(PosterCover),
      matching: find.byType(type),
    );

    double opacityOf(WidgetTester tester) =>
        tester.widget<AnimatedOpacity>(inCover(AnimatedOpacity)).opacity;

    testWidgets('hides the poster before anything has played', (tester) async {
      final started = ValueNotifier(false);
      addTearDown(started.dispose);
      await tester.pumpWidget(host(started));

      expect(cover(), findsOneWidget);
      expect(opacityOf(tester), 1);
    });

    testWidgets('lifts once the video plays', (tester) async {
      final started = ValueNotifier(false);
      addTearDown(started.dispose);
      await tester.pumpWidget(host(started));

      started.value = true;
      // Not pumpAndSettle: the spinner animates forever, so nothing ever
      // settles. Pump past the fade instead.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(opacityOf(tester), 0);
    });

    testWidgets('is opaque, or it is not a cover', (tester) async {
      // A cover that lets the poster through passes every other test in this
      // file — it is in the tree, it lifts on the first frame, it takes no
      // pointers — while the child reads "Watch on YouTube" straight through
      // it. Opacity is the whole job.
      final started = ValueNotifier(false);
      addTearDown(started.dispose);
      await tester.pumpWidget(host(started));

      final box = tester.widget<ColoredBox>(inCover(ColoredBox));
      expect(box.color.a, 1.0);
      // And it fills the player rather than sitting in a corner of it.
      expect(tester.getSize(inCover(ColoredBox)), const Size(320, 180));
    });

    testWidgets('never eats a tap meant for the player', (tester) async {
      // The cover sits on top. If it took pointer events it would swallow the
      // gesture the platform needs to let the video autoplay at all.
      final started = ValueNotifier(false);
      addTearDown(started.dispose);
      await tester.pumpWidget(host(started));

      final ignoring = tester.widget<IgnorePointer>(inCover(IgnorePointer));
      expect(ignoring.ignoring, isTrue);
    });
  });
}
