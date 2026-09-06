import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/protocol.dart';
import '../../core/speech.dart';
import '../../core/theme.dart';
import '../gate/pin_gate.dart';
import 'gilli_widget.dart';

/// The movement break: Gilli stops the video and gives the child something
/// physical to do, built from what they just watched.
///
/// PROTOCOL "Time limits and movement breaks". Three rules shape everything
/// here:
///
///  - Nothing plays until the break is over, so this screen replaces the
///    video entirely and a child cannot dismiss it. Back does nothing.
///  - The timer ends the break, not the child. "I did it" records that they
///    did it and gets praise; it never takes a second off the clock, and the
///    wording says so instead of pretending otherwise.
///  - Band 4_6 sees no text at all (SPEC 5.1). The task is spoken, Gilli acts
///    it out, and the time left is a ring that empties rather than digits.
///
/// It is an invitation to move, never a punishment: no red, no warning icon,
/// nothing about having watched too much.
class BreakScreen extends StatefulWidget {
  const BreakScreen({
    super.key,
    required this.kid,
    required this.movementBreak,
    required this.onFinished,
  });

  final Kid kid;
  final MovementBreak movementBreak;

  /// Called once, when the child is free to watch again: the timer ran out or
  /// a parent ended it early. The caller decides where they land.
  final VoidCallback onFinished;

  @override
  State<BreakScreen> createState() => _BreakScreenState();
}

class _BreakScreenState extends State<BreakScreen> {
  AgeBand get _band => widget.kid.band;
  bool get _preReader => _band == AgeBand.b4to6;
  BreakTask get _task => widget.movementBreak.task;

  Timer? _tick;
  late int _secondsLeft = widget.movementBreak.secondsLeft;
  late final int _total = widget.movementBreak.secondsLeft.clamp(1, 3600);

  Gesture _gesture = Gesture.cheer;
  int _gestureTick = 0;
  bool _acked = false;
  bool _finishing = false;

  /// Praise after "I did it", shown to readers only. Never a countdown claim.
  String? _praise;

  @override
  void initState() {
    super.initState();
    // Gilli arrives cheering, then says what to do: the first thing a child
    // sees is the buddy being pleased, not the video stopping.
    WidgetsBinding.instance.addPostFrameCallback((_) => _openWith());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onSecond());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  GilliVoice get _voice => context.read<GilliVoice>();

  Future<void> _openWith() async {
    if (!mounted) return;
    await _voice.say(url: '', fallbackText: _task.speech, slow: _preReader);
  }

  void _onSecond() {
    if (!mounted || _finishing) return;
    if (_secondsLeft <= 1) {
      setState(() => _secondsLeft = 0);
      _release();
      return;
    }
    setState(() => _secondsLeft--);
  }

  /// The timer decided: Gilli says they can watch again and the child leaves.
  Future<void> _release({bool byParent = false}) async {
    if (_finishing) return;
    _finishing = true;
    _tick?.cancel();
    setState(() {
      _gesture = Gesture.cheer;
      _gestureTick++;
    });
    await _voice.say(
      url: '',
      fallbackText: byParent
          ? 'All done. Let us watch again!'
          : 'Great moving! You can watch again now.',
      slow: _preReader,
    );
    if (!mounted) return;
    widget.onFinished();
  }

  /// Records that they did it. Deliberately does not touch [_secondsLeft].
  Future<void> _iDidIt() async {
    if (_acked || _finishing) return;
    setState(() {
      _acked = true;
      _gesture = Gesture.cheer;
      _gestureTick++;
      _praise = 'Nice moving. Gilli will call you when the time is up.';
    });
    try {
      await context.read<AppState>().gateway.ackBreak(widget.kid.id);
    } catch (_) {
      // The ack is a nicety; a break must never depend on the network.
    }
    if (!mounted) return;
    await _voice.say(
      url: '',
      fallbackText: _preReader
          ? 'Wow! You did it! Keep moving with me.'
          : 'Nice moving. I will call you when the time is up.',
      slow: _preReader,
    );
  }

  /// The parent way out: PIN first, then the server clears the break.
  Future<void> _parentOverride() async {
    final ok = await showPinGate(context);
    if (!ok || !mounted) return;
    try {
      await context.read<AppState>().gateway.overrideBreak(widget.kid.id);
    } catch (_) {
      // Nothing to say to a child; the parent already decided.
    }
    if (!mounted) return;
    await _release(byParent: true);
  }

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<GilliVoice>();
    return PopScope(
      // A break a child can back out of is not a break.
      canPop: false,
      child: Scaffold(
        backgroundColor: HgColors.teal,
        body: SafeArea(
          child: Stack(
            children: [
              LayoutBuilder(
                builder: (context, box) {
                  // Kid mode is landscape, which on a phone is under 400 dp
                  // tall. Everything is sized off that height, and the
                  // countdown sits under Gilli rather than at the end of the
                  // steps, so a child never has to scroll to find the clock
                  // or the button.
                  final wide = box.maxWidth > box.maxHeight;
                  final gilliSize = wide
                      ? (box.maxHeight * 0.44).clamp(120.0, 240.0)
                      : (box.maxWidth * 0.40).clamp(140.0, 240.0);
                  final ringSize = wide
                      ? (box.maxHeight * 0.24).clamp(72.0, 120.0)
                      : 108.0;
                  final gilli = GilliWidget(
                    size: gilliSize,
                    gesture: _gesture,
                    gestureTick: _gestureTick,
                    talking: voice.speaking,
                  );
                  final ring = _BreakTimer(
                    secondsLeft: _secondsLeft,
                    total: _total,
                    // Digits are text. Pre-readers get the ring emptying and
                    // a running figure, with nothing to read.
                    showDigits: !_preReader,
                    size: _preReader ? ringSize * 1.25 : ringSize,
                  );
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                    child: wide
                        ? Row(
                            spacing: 24,
                            children: [
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                // Clear of Gilli's drop shadow, which sits
                                // below his circle.
                                spacing: 16,
                                // The pre-reader panel is only the ring and
                                // one button, so its ring stays over there,
                                // large, next to Gilli.
                                children: [gilli, if (!_preReader) ring],
                              ),
                              Expanded(child: _panel(ring)),
                            ],
                          )
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            spacing: 16,
                            children: [
                              gilli,
                              Flexible(child: _panel(ring)),
                            ],
                          ),
                  );
                },
              ),
              // Small, dim, top-right: a parent finds it, a child does not
              // read it as a way out.
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  onPressed: _parentOverride,
                  iconSize: 24,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: const Icon(Icons.lock_outline_rounded),
                  color: HgColors.cream.withValues(alpha: 0.4),
                  tooltip: 'Parent',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _panel(Widget ring) {
    if (_preReader) {
      // No text anywhere on this screen for band 4_6: the task was spoken and
      // Gilli is acting it out. One picture button says "I did it".
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        spacing: 24,
        children: [
          ring,
          _DidItButton(
            done: _acked,
            label: null,
            onPressed: _acked ? null : _iDidIt,
          ),
        ],
      );
    }

    final steps = _task.steps;
    // The steps take whatever room is left and scroll if a long task needs
    // it; the button and the line under it never move off screen.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('Time to move', style: HgText.body(size: 15, color: HgColors.sky)),
        const SizedBox(height: 6),
        Text(
          _task.title,
          style: HgText.display(size: _band == AgeBand.b7to8 ? 32 : 27),
        ),
        const SizedBox(height: 10),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: 10,
              children: [
                for (var i = 0; i < steps.length; i++)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 12,
                    children: [
                      _StepNumber(i + 1),
                      Expanded(
                        child: Text(
                          steps[i],
                          style: HgText.body(
                            size: _band == AgeBand.b7to8 ? 18 : 16,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          spacing: 16,
          children: [
            _DidItButton(
              done: _acked,
              label: _acked ? 'Nice one' : 'I did it',
              onPressed: _acked ? null : _iDidIt,
            ),
            Expanded(
              child: Text(
                // Honest about what the button does: it tells Gilli, it does
                // not buy the video back sooner.
                _praise ?? 'The video comes back when the timer runs out.',
                style: HgText.body(size: 14, color: HgColors.sky),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Small round number beside a step.
class _StepNumber extends StatelessWidget {
  const _StepNumber(this.n);
  final int n;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: HgColors.mango.withValues(alpha: 0.22),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text('$n', style: HgText.body(size: 15, color: HgColors.mango)),
    );
  }
}

/// The time left, as a ring that empties. Digits are added for readers only;
/// for band 4_6 the ring is the whole clock (SPEC 5.1).
class _BreakTimer extends StatelessWidget {
  const _BreakTimer({
    required this.secondsLeft,
    required this.total,
    required this.showDigits,
    required this.size,
  });

  final int secondsLeft;
  final int total;
  final bool showDigits;
  final double size;

  static String clock(int seconds) {
    final s = seconds.clamp(0, 59 * 60 + 59);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final left = secondsLeft.clamp(0, total);
    return Semantics(
      label: 'Time left in the break',
      value: clock(left),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.expand(
              child: TweenAnimationBuilder<double>(
                // end-only tween: the ring glides from wherever it was to the
                // new second instead of stepping.
                tween: Tween(end: left / total),
                duration: const Duration(milliseconds: 400),
                builder: (context, v, _) => CircularProgressIndicator(
                  value: v,
                  strokeWidth: size * 0.09,
                  strokeCap: StrokeCap.round,
                  color: HgColors.mango,
                  backgroundColor: HgColors.tealDeep,
                ),
              ),
            ),
            if (showDigits)
              Text(clock(left), style: HgText.display(size: size * 0.26))
            else
              // A picture of movement rather than a number a 4-year-old
              // cannot read.
              Icon(
                Icons.directions_run_rounded,
                size: size * 0.4,
                color: HgColors.cream,
              ),
          ],
        ),
      ),
    );
  }
}

/// "I did it". A label for readers, an icon alone for band 4_6.
class _DidItButton extends StatelessWidget {
  const _DidItButton({
    required this.done,
    required this.label,
    required this.onPressed,
  });

  final bool done;
  final String? label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      done ? Icons.favorite_rounded : Icons.check_rounded,
      size: label == null ? 48 : 26,
    );
    if (label == null) {
      // 96 dp so a small hand cannot miss it.
      return Semantics(
        button: true,
        label: 'I did it',
        child: SizedBox(
          width: 96,
          height: 96,
          child: FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              shape: const CircleBorder(),
              padding: EdgeInsets.zero,
              disabledBackgroundColor: HgColors.mango.withValues(alpha: 0.55),
              disabledForegroundColor: HgColors.ink,
            ),
            child: icon,
          ),
        ),
      );
    }
    return SizedBox(
      height: 56,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: icon,
        style: FilledButton.styleFrom(
          disabledBackgroundColor: HgColors.mango.withValues(alpha: 0.55),
          disabledForegroundColor: HgColors.ink,
        ),
        label: Text(label!, style: HgText.body(size: 18, color: HgColors.ink)),
      ),
    );
  }
}

/// The daily limit is used up. Calm, and clear about when it comes back.
///
/// Deliberately not an error: same teal, same Gilli, no red, nothing about
/// having watched too much. Band 4_6 gets it spoken with no text, like
/// everything else (SPEC 5.1).
class DayDoneScreen extends StatefulWidget {
  const DayDoneScreen({super.key, required this.kid});

  final Kid kid;

  @override
  State<DayDoneScreen> createState() => _DayDoneScreenState();
}

class _DayDoneScreenState extends State<DayDoneScreen> {
  static const _line =
      'That is all the watching for today. It starts again tomorrow morning.';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<GilliVoice>().say(
        url: '',
        fallbackText: widget.kid.band == AgeBand.b4to6
            ? 'All done for today! We can watch again tomorrow.'
            : _line,
        slow: widget.kid.band == AgeBand.b4to6,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<GilliVoice>();
    final showText = widget.kid.band.showsQuestionText;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 20,
          children: [
            GilliWidget(
              size: 180,
              gesture: Gesture.idle,
              talking: voice.speaking,
            ),
            if (showText) ...[
              Text(
                'That is all for today',
                textAlign: TextAlign.center,
                style: HgText.display(size: 30),
              ),
              Text(
                'Gilli will be here again tomorrow morning.',
                textAlign: TextAlign.center,
                style: HgText.body(size: 17, color: HgColors.sky),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
