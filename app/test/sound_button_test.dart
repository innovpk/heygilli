import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/features/kid/session_screen.dart';

/// The escape hatch for a browser that will not turn the sound back on.
///
/// The video is started muted so that it starts at all, and unmuted the moment
/// it plays. Where that is refused — silently, which is the dangerous part —
/// a child is left in front of a video with no sound and no way to say what is
/// wrong. This button is the difference between that and one tap.
void main() {
  Widget host(ValueNotifier<bool> needsSound, VoidCallback onTap) => MaterialApp(
    home: Scaffold(
      body: SoundButton(needsSound: needsSound, onTap: onTap),
    ),
  );

  testWidgets('stays out of the way when the sound came back on', (
    tester,
  ) async {
    final needsSound = ValueNotifier(false);
    addTearDown(needsSound.dispose);
    await tester.pumpWidget(host(needsSound, () {}));

    expect(find.byIcon(Icons.volume_off_rounded), findsNothing);
  });

  testWidgets('appears when the browser kept the video muted', (tester) async {
    final needsSound = ValueNotifier(false);
    addTearDown(needsSound.dispose);
    await tester.pumpWidget(host(needsSound, () {}));

    needsSound.value = true;
    await tester.pump();

    expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
  });

  testWidgets('asks for the sound when tapped', (tester) async {
    var taps = 0;
    final needsSound = ValueNotifier(true);
    addTearDown(needsSound.dispose);
    await tester.pumpWidget(host(needsSound, () => taps++));

    await tester.tap(find.byIcon(Icons.volume_off_rounded));
    expect(taps, 1);
  });

  testWidgets('is big enough for a child to hit', (tester) async {
    // A pre-reader cannot be told what it is for, so it has to be a target
    // they land on rather than aim at.
    final needsSound = ValueNotifier(true);
    addTearDown(needsSound.dispose);
    await tester.pumpWidget(host(needsSound, () {}));

    final size = tester.getSize(find.byType(SoundButton));
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(40));
  });
}
