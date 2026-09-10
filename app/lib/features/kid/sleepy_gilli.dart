import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/protocol.dart';
import '../../core/speech.dart';
import '../../core/theme.dart';
import 'gilli_widget.dart';

/// Gilli, who nods off when nobody is playing and wakes up when pinched.
///
/// On the kid shelf he falls asleep after a while with nobody touching the
/// screen. A pinch wakes him: a tap or a click on him, or two fingers
/// squeezed together on a touch screen. He stretches and says "ouch" and
/// hello. Pinched while awake, he squishes and squeaks. That is all a pinch
/// does: the games have their own button, so poking Gilli is never a way into
/// something else.
///
/// Nothing here is text, so it is the same for a four-year-old: the sleep is
/// drawn and the hello is spoken.
class SleepyGilli extends StatefulWidget {
  const SleepyGilli({
    super.key,
    required this.kid,
    this.size = 72,
    this.startAsleep = false,
    this.dozeAfter = const Duration(seconds: 40),
    this.wakeLines,
    this.talking = false,
    this.background = HgColors.cream,
  });

  final Kid kid;
  final double size;
  final bool startAsleep;

  /// How long with nobody touching him before he nods off.
  final Duration dozeAfter;

  /// What he says when woken. Defaults to a pinched, sleepy hello.
  final List<String>? wakeLines;

  /// Someone else is speaking in his voice, so his mouth moves.
  final bool talking;
  final Color? background;

  @override
  State<SleepyGilli> createState() => SleepyGilliState();
}

class SleepyGilliState extends State<SleepyGilli> {
  late bool _asleep = widget.startAsleep;
  Gesture _gesture = Gesture.idle;
  int _tick = 0;
  bool _talking = false;
  Timer? _doze;
  Timer? _cheer;
  final _rng = Random();

  static const _wakeUp = [
    'Ouch! Hee hee, you woke me up!',
    'Yawn! Who pinched me? Oh, hello!',
    'Oh! Hello! I was having a little nap.',
  ];
  static const _pinched = [
    'Ouch! Hee hee, that tickles!',
    'Hey! That was a pinch!',
    'Hee hee! Again, again!',
  ];

  bool get asleep => _asleep;

  @override
  void initState() {
    super.initState();
    if (!_asleep) _armDoze();
  }

  @override
  void dispose() {
    _doze?.cancel();
    _cheer?.cancel();
    super.dispose();
  }

  /// Someone touched the screen: an awake Gilli stays awake a while longer.
  /// A sleeping one stays asleep; waking him is the child's to do.
  void stir() {
    if (!_asleep) _armDoze();
  }

  void _armDoze() {
    _doze?.cancel();
    _doze = Timer(widget.dozeAfter, () {
      if (!mounted) return;
      // Never mid-sentence.
      if (_talking || widget.talking) {
        _armDoze();
        return;
      }
      setState(() {
        _asleep = true;
        _gesture = Gesture.idle;
      });
    });
  }

  /// A pinch while he sleeps. He stretches, then cheers, and says hello.
  Future<void> wake() async {
    if (!_asleep) return;
    setState(() {
      _asleep = false;
      _gesture = Gesture.stretch;
      _tick++;
    });
    _armDoze();
    _cheer?.cancel();
    _cheer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() {
        _gesture = Gesture.cheer;
        _tick++;
      });
    });
    await _say(_pick(widget.wakeLines ?? _wakeUp));
  }

  /// A tap, a click or a squeeze. Asleep, it wakes him; awake, he squishes
  /// up the way anyone does when pinched, and squeaks about it.
  Future<void> pinch() async {
    if (_asleep) return wake();
    _armDoze();
    if (_talking) return; // one squeak at a time
    setState(() {
      _gesture = Gesture.shrink;
      _tick++;
    });
    await _say(_pick(_pinched));
  }

  String _pick(List<String> lines) => lines[_rng.nextInt(lines.length)];

  Future<void> _say(String line) async {
    final gateway = context.read<AppState>().gateway;
    final voice = context.read<GilliVoice>();
    setState(() => _talking = true);
    try {
      await speakLine(
        gateway,
        voice,
        line,
        slow: widget.kid.band == AgeBand.b4to6,
      );
    } catch (_) {
      // A hello is a nicety; a squirrel that cannot speak still wakes up.
    } finally {
      if (mounted) setState(() => _talking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    // One squeeze is one pinch, however many frames the fingers take.
    var squeezed = false;
    return Semantics(
      button: true,
      label: _asleep ? 'Gilli is asleep. Pinch him to wake him up' : 'Gilli',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // With a mouse, or one finger, the pinch is a tap or a click.
        onTap: pinch,
        onScaleStart: (d) => squeezed = false,
        onScaleUpdate: (d) {
          if (squeezed) return;
          if (d.pointerCount >= 2 || (d.scale - 1).abs() > 0.05) {
            squeezed = true;
            pinch();
          }
        },
        child: SizedBox.square(
          dimension: s,
          child: GilliWidget(
            size: s,
            asleep: _asleep,
            gesture: _gesture,
            gestureTick: _tick,
            talking: _talking || widget.talking,
            background: widget.background,
          ),
        ),
      ),
    );
  }
}
