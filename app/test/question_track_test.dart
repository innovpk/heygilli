import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/features/kid/question_track.dart';

/// Where the questions are in this video.
///
/// Under the player, never on it: HeyGilli plays by YouTube's rules and those
/// forbid overlays during playback. A video that stops dead to ask something is
/// a small shock the first few times; a child who can see the next dot coming
/// is waiting for it instead.
void main() {
  Future<void> show(
    WidgetTester tester, {
    required double positionS,
    required int durationS,
    required List<int> times,
    int asked = 0,
    double width = 400,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: QuestionTrack(
                positionS: positionS,
                durationS: durationS,
                questionTimes: times,
                askedCount: asked,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<double> dotLefts(WidgetTester tester) => tester
      .widgetList<Positioned>(find.byType(Positioned))
      .map((p) => p.left!)
      .toList();

  testWidgets('a dot for every question', (tester) async {
    await show(tester, positionS: 0, durationS: 600, times: [90, 270, 450]);
    expect(dotLefts(tester), hasLength(3));
  });

  testWidgets('dots sit where the questions are', (tester) async {
    // Halfway through the video is halfway along the strip.
    await show(tester, positionS: 0, durationS: 600, times: [300], width: 400);
    final left = dotLefts(tester).single;
    expect(left, closeTo(400 / 2 - 6, 1));
  });

  testWidgets('a question near the end stays inside the strip', (tester) async {
    // Half a dot hanging off the edge reads as a bug, and an end-of-video
    // question is the commonest kind there is.
    await show(tester, positionS: 0, durationS: 600, times: [597], width: 400);
    final left = dotLefts(tester).single;
    expect(left, lessThanOrEqualTo(400 - 12));
    expect(left, greaterThanOrEqualTo(0));
  });

  testWidgets('answered questions are filled in', (tester) async {
    await show(
      tester,
      positionS: 300,
      durationS: 600,
      times: [90, 270, 450],
      asked: 2,
    );
    // Two behind them, one still to come.
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
  });

  testWidgets('a video of unknown length shows nothing rather than guessing', (
    tester,
  ) async {
    // duration 0 means nobody could look it up, which is common. There is no
    // scale to place a dot on, so placing one would be inventing it.
    await show(tester, positionS: 30, durationS: 0, times: [90, 270]);
    expect(find.byType(Positioned), findsNothing);
  });

  testWidgets('no questions, no strip', (tester) async {
    await show(tester, positionS: 30, durationS: 600, times: []);
    expect(find.byType(Positioned), findsNothing);
  });

  testWidgets('a position past the end does not overflow the bar', (
    tester,
  ) async {
    // The player reports a position a shade past the duration at the very end.
    await show(
      tester,
      positionS: 900,
      durationS: 600,
      times: [300],
      width: 400,
    );
    final fill = tester.widgetList<Container>(find.byType(Container)).toList();
    expect(fill, isNotEmpty);
    // Nothing threw, and the dot is still on the strip.
    expect(dotLefts(tester).single, lessThanOrEqualTo(400 - 12));
  });

  testWidgets('it says out loud what it shows', (tester) async {
    await show(
      tester,
      positionS: 300,
      durationS: 600,
      times: [90, 270, 450],
      asked: 1,
    );
    expect(
      find.bySemanticsLabel('3 questions in this video, 1 answered so far'),
      findsOneWidget,
    );
  });
}
