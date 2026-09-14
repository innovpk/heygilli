import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/speech.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GilliVoice URL resolution', () {
    test('resolves relative URLs against base URL', () {
      final voice = GilliVoice(baseUrl: 'http://example.com:8080');
      expect(
        voice.resolveUrl('/tts/abc123.mp3'),
        'http://example.com:8080/tts/abc123.mp3',
      );
      expect(
        voice.resolveUrl('tts/abc123.mp3'),
        'http://example.com:8080/tts/abc123.mp3',
      );
    });

    test('preserves already absolute URLs', () {
      final voice = GilliVoice(baseUrl: 'http://example.com:8080');
      expect(
        voice.resolveUrl('https://other.com/audio.mp3'),
        'https://other.com/audio.mp3',
      );
      expect(
        voice.resolveUrl('http://localhost:9000/audio.mp3'),
        'http://localhost:9000/audio.mp3',
      );
    });

    test('handles empty URL', () {
      final voice = GilliVoice();
      expect(voice.resolveUrl(''), '');
    });

    test('falls back to BuildConfig.apiUrl when no baseUrl given', () {
      final voice = GilliVoice();
      final expectedBase = BuildConfig.apiUrl.replaceAll(RegExp(r'/+$'), '');
      expect(voice.resolveUrl('/tts/hash.mp3'), '$expectedBase/tts/hash.mp3');
    });
  });

  group('GilliVoice fallback speech', () {
    final spoken = <String>[];
    const channel = MethodChannel('flutter_tts');

    setUp(() {
      spoken.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'speak':
                spoken.add('${call.arguments}');
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

    test('speaks fallbackText via on-device TTS when url is empty', () async {
      final voice = GilliVoice();
      await voice.say(url: '', fallbackText: 'Why did the ice melt?');
      expect(spoken, contains('Why did the ice melt?'));
    });
  });
}
