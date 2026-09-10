import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/break_activities.dart';
import '../../core/gateway.dart';
import '../../core/models.dart';
import '../../core/protocol.dart';
import '../../core/speech.dart';
import '../../core/theme.dart';
import 'kid_palette.dart';
import '../gate/pin_gate.dart';
import 'gilli_widget.dart';

/// The break: Gilli stops the video and reads out the line this child's
/// parent wrote for break time.
///
/// PROTOCOL "Time limits and break periods". Four rules shape everything here:
///
///  - Every word comes from a parent. A model may suggest lines in the parent
///    app, but only saved ones reach a child, and a parent who saved none gets
///    a quiet break rather than something invented to fill it.
///  - Nothing plays until the break is over, so this screen replaces the video
///    entirely and a child cannot dismiss it. Back does nothing.
///  - Whether "I did it" ends the break is the parent's setting. On a firm
///    break it records and praises without touching the clock, and says so
///    instead of pretending otherwise; on a soft one it lets them back.
///  - Band 4_6 sees no text at all (SPEC 5.1). The line is spoken, Gilli acts
///    it out, and the time left is a ring that empties rather than digits.
///
/// It is an invitation to stop for a moment, never a punishment: no red, no
/// warning icon, nothing about having watched too much.
class BreakScreen extends StatefulWidget {
  const BreakScreen({
    super.key,
    required this.kid,
    required this.breakPeriod,
    required this.onFinished,
  });

  final Kid kid;
  final BreakPeriod breakPeriod;

  /// Called once, when the child is free to watch again: the timer ran out or
  /// a parent ended it early. The caller decides where they land.
  final VoidCallback onFinished;

  @override
  State<BreakScreen> createState() => _BreakScreenState();
}

class _BreakScreenState extends State<BreakScreen> {
  AgeBand get _band => widget.kid.band;
  bool get _preReader => _band == AgeBand.b4to6;

  /// The line a parent wrote for this break, or null when they wrote none.
  BreakMessage? get _message => widget.breakPeriod.message;

  Timer? _tick;
  late int _secondsLeft = widget.breakPeriod.secondsLeft;
  late final int _total = widget.breakPeriod.secondsLeft.clamp(1, 3600);

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

  /// Read once: a break speaks from timers and taps, long after the frame
  /// that built it, and reaching through context then is a use across an
  /// async gap.
  late final Gateway _gateway = context.read<AppState>().gateway;

  /// What Gilli says when the parent has written no lines: that it is break
  /// time and nothing more. Never an invented instruction.
  String _quietLine() {
    final mins = (_total / 60).ceil();
    return _preReader
        ? 'Break time! Gilli will call you in a little while.'
        : 'Break time. Back in about $mins '
              '${mins == 1 ? 'minute' : 'minutes'}.';
  }

  Future<void> _openWith() async {
    if (!mounted) return;
    // A parent's line is spoken as they wrote it; with none, Gilli says only
    // that it is break time. Nothing is invented to fill the silence.
    await _speak(_message?.speech ?? _quietLine());
  }

  /// In Gilli's voice where the gateway can give one, the device's otherwise.
  /// The gateway is read once, in [initState], because these lines are spoken
  /// from timers and taps long after the frame that built this screen.
  Future<void> _speak(String text) =>
      speakLine(_gateway, _voice, text, slow: _preReader);

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
    await _speak(
      byParent
          ? 'All done. Let us watch again!'
          : 'Great moving! You can watch again now.',
    );
    if (!mounted) return;
    widget.onFinished();
  }

  /// Records that they did it. Deliberately does not touch [_secondsLeft].
  Future<void> _iDidIt() async {
    if (_acked || _finishing) return;
    final firm = widget.breakPeriod.isFirm;
    setState(() {
      _acked = true;
      _gesture = Gesture.cheer;
      _gestureTick++;
      _praise = firm
          ? 'Nice one. Gilli will call you when the time is up.'
          : 'Nice one.';
    });
    try {
      await context.read<AppState>().gateway.ackBreak(widget.kid.id);
    } catch (_) {
      // The ack is a nicety; a break must never depend on the network.
    }
    // Whether this ends the break is the parent's setting, not the child's tap.
    if (!firm) {
      await _release();
      return;
    }
    if (!mounted) return;
    await _speak(
      _preReader
          ? 'Wow! You did it! Keep moving with me.'
          : 'Nice moving. I will call you when the time is up.',
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
    final palette = KidPalette.of(context);
    final voice = context.watch<GilliVoice>();
    return PopScope(
      // A break a child can back out of is not a break.
      canPop: false,
      child: Scaffold(
        backgroundColor: palette.ground,
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
                    // What Gilli asked for, as a picture: a pre-reader hears
                    // "star jumps" once and then has only this screen.
                    activityIcon: breakActivityIcons[_message?.activity],
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
                  color: palette.quiet,
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
    final palette = KidPalette.of(context);
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

    final message = _message;
    // The parent's own sentence, or none at all. There is no generated task
    // here: a parent who wrote nothing gets a quiet break, which is a
    // deliberate state rather than a gap for a model to fill.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('Break time', style: HgText.body(size: 15, color: palette.quiet)),
        const SizedBox(height: 8),
        Flexible(
          child: SingleChildScrollView(
            child: Text(
              (message != null && message.text.isNotEmpty)
                  ? message.text
                  : _quietLine(),
              style: HgText.display(size: _band == AgeBand.b7to8 ? 30 : 26),
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
                _praise ??
                    (widget.breakPeriod.isFirm
                        ? 'The video comes back when the timer runs out.'
                        : 'Tap when you are done and the video comes back.'),
                style: HgText.body(size: 14, color: palette.quiet),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The time left, as a ring that empties. Digits are optional because a
/// pre-reader cannot read them.
class _BreakTimer extends StatelessWidget {
  const _BreakTimer({
    required this.secondsLeft,
    required this.total,
    required this.showDigits,
    required this.size,
    this.activityIcon,
  });

  final int secondsLeft;
  final int total;
  final bool showDigits;
  final double size;

  /// The icon for the activity Gilli asked for, when the line came from one.
  final String? activityIcon;

  static String clock(int seconds) {
    final s = seconds.clamp(0, 59 * 60 + 59);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
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
                  color: palette.accent,
                  backgroundColor: palette.chip,
                ),
              ),
            ),
            if (showDigits)
              Text(clock(left), style: HgText.display(size: size * 0.26))
            else if (activityIcon != null)
              // The activity itself, where there is one to show.
              SizedBox.square(
                dimension: size * 0.46,
                child: SvgPicture.asset('assets/icons/$activityIcon.svg'),
              )
            else
              // A picture of movement rather than a number a 4-year-old
              // cannot read.
              Icon(
                Icons.directions_run_rounded,
                size: size * 0.4,
                color: palette.onGround,
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
              disabledForegroundColor: HgColors.white,
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
          disabledForegroundColor: HgColors.white,
        ),
        label: Text(
          label!,
          style: HgText.body(size: 18, color: HgColors.white),
        ),
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
      speakLine(
        context.read<AppState>().gateway,
        context.read<GilliVoice>(),
        widget.kid.band == AgeBand.b4to6
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
    // This sits under the kid home's header in landscape, where there is not
    // much height left: Gilli is sized off what there is so the line saying
    // when watching comes back is never the part that falls off the screen.
    return LayoutBuilder(
      builder: (context, box) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              GilliWidget(
                size: (box.maxHeight * 0.44).clamp(90.0, 180.0),
                gesture: Gesture.idle,
                talking: voice.speaking,
              ),
              if (showText) ...[
                Text(
                  'That is all for today',
                  textAlign: TextAlign.center,
                  style: HgText.display(size: 28),
                ),
                Text(
                  'Gilli will be here again tomorrow morning.',
                  textAlign: TextAlign.center,
                  style: HgText.body(
                    size: 17,
                    color: KidPalette.of(context).quiet,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
