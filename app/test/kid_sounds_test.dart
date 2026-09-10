import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/sounds.dart';

/// Tap sounds in kid mode.
///
/// A press that makes no sound feels like it did nothing to a child who cannot
/// read what changed on the screen. There is no audio device under a test, so
/// these listen on [KidSounds.onPlay] for what would have been played.
void main() {
  late List<String> played;

  setUp(() {
    played = [];
    KidSounds.onPlay = played.add;
  });

  tearDown(() => KidSounds.onPlay = null);

  test('a tap is a pop, a celebration is a cheer', () {
    KidSounds.instance.tap();
    KidSounds.instance.cheer();
    expect(played, ['tap', 'cheer']);
  });

  test('withTap plays the pop, then does what the button does', () {
    final order = <String>[];
    KidSounds.onPlay = (name) => order.add('sound:$name');

    withTap(() => order.add('action'))!();

    expect(order, ['sound:tap', 'action']);
  });

  test('a disabled button stays disabled and silent', () {
    expect(withTap(null), isNull);
    expect(played, isEmpty);
  });

  testWidgets('pressing a wired button makes the sound once', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: withTap(() => pressed++),
              child: const Text('Go'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Go'));
    await tester.pump();

    expect(pressed, 1);
    expect(played, ['tap']);
  });

  testWidgets('the sound files ship with the app', (tester) async {
    // pubspec lists assets/sounds/, and KidSounds plays these two by name.
    for (final name in ['tap', 'cheer']) {
      final bytes = await rootBundle.load('assets/sounds/$name.wav');
      expect(bytes.lengthInBytes, greaterThan(1000), reason: '$name.wav');
    }
  });
}
