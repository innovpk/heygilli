import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/protocol.dart';
import '../../core/theme.dart';

/// Gilli the palm squirrel, drawn from assets/gilli.svg.
///
/// Gestures are the buddy's body language and do the work text cannot for
/// pre-readers (SPEC 7.5). Each gesture is a single short implicit animation
/// (600 ms max) driven by [gestureTick]: bump the tick to replay the same
/// gesture. While [talking] a small sound-wave sits by Gilli's mouth.
class GilliWidget extends StatefulWidget {
  const GilliWidget({
    super.key,
    this.size = 160,
    this.gesture = Gesture.idle,
    this.gestureTick = 0,
    this.talking = false,
    this.listening = false,
    this.asleep = false,
    this.background = HgColors.cream,
  });

  final double size;
  final Gesture gesture;
  final int gestureTick;
  final bool talking;
  final bool listening;

  /// Eyes shut, head tipped, breathing slow and deep, and Zs drifting up.
  /// Gestures and talking wait until he is awake again.
  final bool asleep;
  final Color? background;

  @override
  State<GilliWidget> createState() => _GilliWidgetState();
}

class _GilliWidgetState extends State<GilliWidget>
    with SingleTickerProviderStateMixin {
  // Slow breathing so Gilli never looks frozen between gestures.
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          if (widget.background != null)
            Container(
              decoration: BoxDecoration(
                color: widget.background,
                shape: BoxShape.circle,
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x590F2A33),
                    offset: Offset(0, 8),
                    blurRadius: 0,
                  ),
                ],
              ),
            ),
          if (widget.listening && !widget.asleep) _ListenHalo(size: s),
          Positioned(
            bottom: s * 0.04,
            child: TweenAnimationBuilder<double>(
              // A new key restarts the tween: one gesture, out and back.
              key: ValueKey('${widget.gesture}-${widget.gestureTick}'),
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeInOut,
              builder: (context, t, child) => AnimatedBuilder(
                animation: _breathe,
                builder: (context, child) => Transform(
                  alignment: Alignment.bottomCenter,
                  transform: _matrix(
                    widget.asleep ? Gesture.idle : widget.gesture,
                    t,
                    _breathe.value,
                    asleep: widget.asleep,
                  ),
                  child: child,
                ),
                child: child,
              ),
              child: _GilliBody(
                size: s * 0.86,
                talking: widget.talking && !widget.asleep,
                gesture: widget.gesture,
                asleep: widget.asleep,
              ),
            ),
          ),
          if (widget.talking && !widget.asleep)
            Positioned(
              right: s * 0.02,
              top: s * 0.28,
              child: _SoundWave(height: s * 0.28),
            ),
          if (widget.asleep)
            Positioned(
              right: -s * 0.08,
              top: -s * 0.12,
              child: _Snore(key: const Key('gilli-snore'), size: s * 0.42),
            ),
        ],
      ),
    );
  }

  /// t runs 0 → 1 once per gesture; `pulse` is sin(pi t): 0 → 1 → 0.
  static Matrix4 _matrix(
    Gesture g,
    double t,
    double breathe, {
    bool asleep = false,
  }) {
    final pulse = math.sin(math.pi * t);
    final m = Matrix4.identity();
    // Breathing: barely-there vertical scale, slow and deep when asleep.
    m.scaleByDouble(1, 1 + (asleep ? 0.05 : 0.015) * breathe, 1, 1);
    if (asleep) {
      // Head tipped over to one side, the way a nap looks.
      m.rotateZ(0.12);
      return m;
    }
    switch (g) {
      case Gesture.idle:
        break;
      case Gesture.stretch:
        m.scaleByDouble(1 - 0.08 * pulse, 1 + 0.28 * pulse, 1, 1);
      case Gesture.shrink:
        m.scaleByDouble(1 - 0.3 * pulse, 1 - 0.3 * pulse, 1, 1);
      case Gesture.spin:
        m.rotateZ(2 * math.pi * t);
      case Gesture.point:
        m.translateByDouble(16 * pulse, 0, 0, 1);
        m.rotateZ(-0.18 * pulse);
      case Gesture.roar:
        m.scaleByDouble(1 + 0.22 * pulse, 1 + 0.22 * pulse, 1, 1);
        m.translateByDouble(6 * math.sin(t * math.pi * 6) * pulse, 0, 0, 1);
      case Gesture.think:
        m.rotateZ(0.14 * pulse);
        m.translateByDouble(0, 4 * pulse, 0, 1);
      case Gesture.cheer:
        m.translateByDouble(0, -26 * pulse, 0, 1);
        m.rotateZ(0.12 * math.sin(t * math.pi * 4));
    }
    return m;
  }
}

/// Three mango bars bouncing while TTS plays: "Gilli is talking".
class _SoundWave extends StatefulWidget {
  const _SoundWave({required this.height});
  final double height;

  @override
  State<_SoundWave> createState() => _SoundWaveState();
}

class _SoundWaveState extends State<_SoundWave>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.height;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        spacing: h * 0.12,
        children: List.generate(3, (i) {
          final phase = _c.value * 2 * math.pi + i * 1.1;
          final f = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(phase));
          return Container(
            width: h * 0.16,
            height: h * f,
            decoration: BoxDecoration(
              color: HgColors.mango,
              borderRadius: BorderRadius.circular(h),
            ),
          );
        }),
      ),
    );
  }
}

/// Three Zs drifting up and away while Gilli sleeps.
///
/// Drawn, not typed: a pre-reader sees no letters anywhere in the app, and a
/// zigzag floating off a sleeping squirrel reads as sleep without them.
class _Snore extends StatefulWidget {
  const _Snore({super.key, required this.size});
  final double size;

  @override
  State<_Snore> createState() => _SnoreState();
}

class _SnoreState extends State<_Snore> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) => CustomPaint(
        size: Size.square(widget.size),
        painter: _SnorePainter(_c.value),
      ),
    ),
  );
}

class _SnorePainter extends CustomPainter {
  _SnorePainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    for (var i = 0; i < 3; i++) {
      // Each Z is a third of a cycle behind the last: born low and small,
      // growing and fading as it rises.
      final p = (t + i / 3) % 1;
      final z = w * (0.16 + 0.16 * p);
      final x = w * (0.08 + 0.5 * p);
      final y = w * (0.86 - 0.7 * p) - z;
      final paint = Paint()
        ..color = HgColors.mango.withValues(alpha: math.sin(math.pi * p))
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, z * 0.2)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(
        Path()
          ..moveTo(x, y)
          ..lineTo(x + z, y)
          ..lineTo(x, y + z)
          ..lineTo(x + z, y + z),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SnorePainter old) => old.t != t;
}

/// Pulsing ring behind Gilli while the mic is open.
class _ListenHalo extends StatefulWidget {
  const _ListenHalo({required this.size});
  final double size;

  @override
  State<_ListenHalo> createState() => _ListenHaloState();
}

class _ListenHaloState extends State<_ListenHalo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.size * (1 + 0.25 * _c.value),
        height: widget.size * (1 + 0.25 * _c.value),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: HgColors.mango.withValues(alpha: 0.45 * (1 - _c.value)),
        ),
      ),
    );
  }
}

/// Gilli, drawn as separate layers so parts of him can move on their own.
///
/// A single flat image reads as a sticker: the whole body slides about and
/// nothing on the face changes. Splitting the drawing lets the tail sway, the
/// ears twitch, the eyes blink and the mouth actually open while he speaks, so
/// a four-year-old who cannot read still sees something alive. Each layer is a
/// full 180x180 SVG, so they stack with no per-layer offsets and every
/// rotation origin is just a point on that shared canvas.
class _GilliBody extends StatefulWidget {
  const _GilliBody({
    required this.size,
    required this.talking,
    required this.gesture,
    this.asleep = false,
  });

  final double size;
  final bool talking;
  final Gesture gesture;
  final bool asleep;

  @override
  State<_GilliBody> createState() => _GilliBodyState();
}

class _GilliBodyState extends State<_GilliBody> with TickerProviderStateMixin {
  late final _sway = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2100),
  )..repeat(reverse: true);

  /// One long cycle that is open-eyed almost throughout: the blink is a short
  /// dip near the end, so it reads as an occasional blink rather than a pulse.
  late final _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4300),
  )..repeat();

  /// Mouth shapes while talking. Runs only when there is speech.
  late final _talk = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  @override
  void initState() {
    super.initState();
    if (widget.talking) _talk.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_GilliBody old) {
    super.didUpdateWidget(old);
    if (widget.talking && !_talk.isAnimating) {
      _talk.repeat(reverse: true);
    } else if (!widget.talking && _talk.isAnimating) {
      _talk
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _sway.dispose();
    _blink.dispose();
    _talk.dispose();
    super.dispose();
  }

  /// 1 = eyes open, 0 = shut. Open for most of the cycle, with one quick dip.
  static double _eyeOpen(double t) {
    const start = 0.90;
    if (t < start) return 1;
    final k = (t - start) / (1 - start); // 0 → 1 across the blink
    return (1 - math.sin(math.pi * k)).clamp(0.06, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    // A roar holds the mouth open; otherwise it follows the talk cycle.
    final roaring = widget.gesture == Gesture.roar && !widget.asleep;

    return SizedBox(
      width: s,
      height: s,
      child: AnimatedBuilder(
        animation: Listenable.merge([_sway, _blink, _talk]),
        builder: (context, _) {
          // A sleeping tail barely stirs.
          final sway = (_sway.value - 0.5) * 2 * (widget.asleep ? 0.25 : 1);
          final open = roaring || _talk.value > 0.5;
          return Stack(
            fit: StackFit.expand,
            children: [
              // Tail: pivots at its base, behind everything.
              Transform.rotate(
                angle: 0.10 * sway,
                alignment: const Alignment(-0.51, 0.56),
                child: _layer('tail', s),
              ),
              _layer('body', s),
              // Ears twitch on opposite phases so they never look mechanical.
              Transform.rotate(
                angle: -0.09 * sway,
                alignment: const Alignment(-0.22, -0.38),
                child: _layer('ear_left', s),
              ),
              Transform.rotate(
                angle: 0.09 * -sway,
                alignment: const Alignment(0.36, -0.38),
                child: _layer('ear_right', s),
              ),
              _layer('head', s),
              // Blink: squash the eyes vertically about their own centre.
              Transform.scale(
                scaleY: widget.asleep ? 0.08 : _eyeOpen(_blink.value),
                alignment: const Alignment(0.07, -0.27),
                child: _layer('eyes', s),
              ),
              _layer(open ? 'mouth_open' : 'mouth_closed', s),
            ],
          );
        },
      ),
    );
  }

  Widget _layer(String name, double s) =>
      SvgPicture.asset('assets/gilli/$name.svg', width: s, height: s);
}
