import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Gilli's voice. Plays the gateway's cached `tts_url` (consistent character
/// voice, Urdu support) and falls back to on-device TTS when the URL is empty
/// or fails, per PROTOCOL.md "TTS".
class GilliVoice extends ChangeNotifier {
  GilliVoice();

  // Built on first use, not in the constructor: creating one of these reaches
  // for a platform channel, and the object itself is constructed in places
  // (tests, a screen that never speaks) where no audio is ever asked for.
  AudioPlayer? _playerOrNull;
  FlutterTts? _ttsOrNull;

  AudioPlayer get _player {
    final player = _playerOrNull;
    if (player != null) return player;
    final made = AudioPlayer();
    made.onPlayerComplete.listen((_) => _finish());
    return _playerOrNull = made;
  }

  FlutterTts get _tts {
    final tts = _ttsOrNull;
    if (tts != null) return tts;
    final made = FlutterTts();
    made.setCompletionHandler(_finish);
    made.setCancelHandler(_finish);
    made.setErrorHandler((_) => _finish());
    return _ttsOrNull = made;
  }

  bool _speaking = false;
  Completer<void>? _done;

  /// True while audio is playing; drives Gilli's sound-wave indicator.
  bool get speaking => _speaking;

  /// Speaks [url] if given, else [fallbackText] with on-device TTS.
  /// Resolves when playback finishes (or immediately if there is nothing).
  Future<void> say({
    required String url,
    String? fallbackText,
    String language = 'en',
    bool slow = false,
  }) async {
    await stop();
    if (url.isEmpty && (fallbackText == null || fallbackText.isEmpty)) return;

    _done = Completer<void>();
    _speaking = true;
    notifyListeners();

    if (url.isNotEmpty) {
      try {
        await _player.play(UrlSource(url));
      } catch (_) {
        // Network or codec trouble: fall through to on-device TTS.
        if (fallbackText != null && fallbackText.isNotEmpty) {
          await _speakLocal(fallbackText, language, slow);
        } else {
          _finish();
        }
      }
    } else {
      await _speakLocal(fallbackText!, language, slow);
    }
    // Safety net: never let a stuck completion block the session loop.
    return _done!.future.timeout(
      const Duration(seconds: 20),
      onTimeout: _finish,
    );
  }

  Future<void> _speakLocal(String text, String language, bool slow) async {
    try {
      await _tts.setLanguage(language == 'ur' ? 'ur-PK' : 'en-US');
      // SPEC 9.2: slower rate for pre-readers so key words land.
      await _tts.setSpeechRate(slow ? 0.42 : 0.5);
      await _tts.setPitch(1.1);
      await _tts.speak(text);
    } catch (_) {
      _finish();
    }
  }

  void _finish() {
    if (!_speaking) return;
    _speaking = false;
    if (_done != null && !_done!.isCompleted) _done!.complete();
    notifyListeners();
  }

  Future<void> stop() async {
    if (!_speaking) return;
    try {
      await _playerOrNull?.stop();
      await _ttsOrNull?.stop();
    } catch (_) {}
    _finish();
  }

  @override
  void dispose() {
    _playerOrNull?.dispose();
    _ttsOrNull?.stop();
    super.dispose();
  }
}

/// Result of one listening window. [transcript] is never persisted anywhere:
/// it goes to the gateway, which scores it and discards it (SPEC 7.4).
class Heard {
  const Heard({required this.transcript, required this.heardAnything});
  final String transcript;
  final bool heardAnything;
}

/// Push-to-talk (and auto-start for pre-readers) over on-device recognition.
class KidEars extends ChangeNotifier {
  final _stt = SpeechToText();
  bool _ready = false;
  bool _available = false;
  bool _listening = false;
  String _partial = '';
  bool _heardSound = false;
  Completer<Heard>? _window;
  Timer? _timer;

  bool get listening => _listening;

  /// Live partial transcript shown for bands 7+ only.
  String get partial => _partial;

  bool get available => _available;

  Future<bool> init() async {
    if (_ready) return _available;
    _ready = true;
    try {
      _available = await _stt.initialize(
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') _onEngineStopped();
        },
        onError: (_) => _onEngineStopped(),
      );
    } catch (_) {
      _available = false;
    }
    return _available;
  }

  /// Listens for up to [window]. Resolves early when the engine finalises a
  /// result, or when [finishNow] is called (button released).
  Future<Heard> listen({
    required Duration window,
    String language = 'en',
  }) async {
    await stopListening();
    _partial = '';
    _heardSound = false;
    _window = Completer<Heard>();
    if (!await init()) {
      // No recogniser (emulator, denied permission): behave like silence so
      // the loop still moves on and Gilli models the answer.
      return const Heard(transcript: '', heardAnything: false);
    }
    _listening = true;
    notifyListeners();
    try {
      await _stt.listen(
        onResult: _onResult,
        onSoundLevelChange: (level) {
          if (level > 2) _heardSound = true;
        },
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: true,
          listenFor: window,
          pauseFor: const Duration(seconds: 3),
          localeId: language == 'ur' ? 'ur_PK' : 'en_US',
        ),
      );
    } catch (_) {
      _complete();
    }
    _timer = Timer(window + const Duration(milliseconds: 400), _complete);
    return _window!.future;
  }

  void _onResult(SpeechRecognitionResult r) {
    _partial = r.recognizedWords;
    if (_partial.isNotEmpty) _heardSound = true;
    notifyListeners();
    if (r.finalResult) _complete();
  }

  void _onEngineStopped() {
    if (_listening) _complete();
  }

  /// Button released: take what we have.
  Future<void> finishNow() async {
    if (!_listening) return;
    try {
      await _stt.stop();
    } catch (_) {}
    _complete();
  }

  void _complete() {
    _timer?.cancel();
    _timer = null;
    final wasListening = _listening;
    _listening = false;
    if (_window != null && !_window!.isCompleted) {
      _window!.complete(
        Heard(
          transcript: _partial.trim(),
          heardAnything: _heardSound || _partial.trim().isNotEmpty,
        ),
      );
    }
    if (wasListening) notifyListeners();
  }

  Future<void> stopListening() async {
    _timer?.cancel();
    if (_listening) {
      try {
        await _stt.cancel();
      } catch (_) {}
    }
    _listening = false;
    if (_window != null && !_window!.isCompleted) {
      _window!.complete(const Heard(transcript: '', heardAnything: false));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stt.cancel();
    super.dispose();
  }
}
