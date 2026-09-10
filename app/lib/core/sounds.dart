import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';

/// [onTap] with a tap sound in front of it.
VoidCallback tapping(VoidCallback onTap) => () {
  KidSounds.instance.tap();
  onTap();
};

/// [tapping] for a callback that may be null: a disabled button stays
/// disabled and silent.
VoidCallback? withTap(VoidCallback? onTap) =>
    onTap == null ? null : tapping(onTap);

/// Little sounds for a child's hands: a soft pop when they tap something, and
/// a bright run of notes when Gilli celebrates a right answer.
///
/// A tap that makes no sound feels like it did nothing to a child who cannot
/// read what changed. Both sounds are short and quiet, generated for this app
/// (`assets/sounds/`), and played on players of their own, so a tap never cuts
/// Gilli off mid-sentence and never counts as him speaking.
class KidSounds {
  KidSounds._();

  static final instance = KidSounds._();

  /// Called with the sound's name each time one is asked for. Tests listen
  /// here, since there is no audio device under `flutter test`.
  @visibleForTesting
  static void Function(String name)? onPlay;

  AudioPlayer? _tapPlayer;
  AudioPlayer? _cheerPlayer;

  /// Something a child pressed did something.
  void tap() => _play('tap', volume: 0.5);

  /// Gilli is celebrating: goes with the burst of stars.
  void cheer() => _play('cheer', volume: 0.6);

  Future<void> _play(String name, {required double volume}) async {
    onPlay?.call(name);
    if (!_hasAudio) return;
    try {
      final player = name == 'tap'
          ? (_tapPlayer ??= AudioPlayer())
          : (_cheerPlayer ??= AudioPlayer());
      await player.stop();
      await player.play(AssetSource('sounds/$name.wav'), volume: volume);
    } catch (_) {
      // A sound effect is never worth an error in front of a child.
    }
  }

  /// Only the app itself runs on [WidgetsFlutterBinding]. Under a test binding
  /// there is no audio plugin, and reaching for one leaves errors behind.
  static bool get _hasAudio {
    try {
      return WidgetsBinding.instance is WidgetsFlutterBinding;
    } catch (_) {
      return false;
    }
  }
}
