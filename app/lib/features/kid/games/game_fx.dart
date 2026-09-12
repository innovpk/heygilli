import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/sounds.dart';

/// Tactile bouncy touch wrapper for buttons, cards, and game tiles.
///
/// Squishes smoothly on tap down and springs back on release, making
/// tap targets feel alive and physical to small hands.
class BouncyTouch extends StatefulWidget {
  const BouncyTouch({
    super.key,
    required this.child,
    required this.onTap,
    this.scaleDown = 0.92,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double scaleDown;
  final bool enabled;

  @override
  State<BouncyTouch> createState() => _BouncyTouchState();
}

class _BouncyTouchState extends State<BouncyTouch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    reverseDuration: const Duration(milliseconds: 220),
    lowerBound: 0.0,
    upperBound: 1.0,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    if (!widget.enabled || widget.onTap == null) return;
    _controller.forward();
  }

  void _onTapUp(TapUpDetails _) {
    if (!widget.enabled || widget.onTap == null) return;
    _controller.reverse();
    tapping(widget.onTap!)();
  }

  void _onTapCancel() {
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.onTap == null) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final scale = 1.0 - (_controller.value * (1.0 - widget.scaleDown));
          return Transform.scale(
            scale: scale,
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// A burst of gentle, colorful confetti ribbons and stars drifting down.
///
/// Renders purely in Flutter using CustomPainter so it has zero asset overhead
/// and runs smoothly at 60/120 fps.
class ConfettiOverlay extends StatefulWidget {
  const ConfettiOverlay({super.key, this.duration = const Duration(seconds: 3)});

  final Duration duration;

  @override
  State<ConfettiOverlay> createState() => _ConfettiOverlayState();
}

class _ConfettiOverlayState extends State<ConfettiOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..forward();

  late final List<_ConfettiParticle> _particles = List.generate(
    42,
    (i) => _ConfettiParticle(seed: i),
  );

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: _anim,
      builder: (context, _) => CustomPaint(
        painter: _ConfettiPainter(
          progress: _anim.value,
          particles: _particles,
        ),
        size: Size.infinite,
      ),
    ),
  );
}

class _ConfettiParticle {
  _ConfettiParticle({required int seed}) {
    final rng = math.Random(seed * 37 + 11);
    x = rng.nextDouble();
    delay = rng.nextDouble() * 0.25;
    speed = 0.5 + rng.nextDouble() * 0.6;
    swaySpeed = 2.0 + rng.nextDouble() * 4.0;
    swayDist = 18.0 + rng.nextDouble() * 26.0;
    size = 7.0 + rng.nextDouble() * 6.0;
    rotationSpeed = 2.0 + rng.nextDouble() * 5.0;
    color = _palette[rng.nextInt(_palette.length)];
    isCircle = rng.nextBool();
  }

  late final double x;
  late final double delay;
  late final double speed;
  late final double swaySpeed;
  late final double swayDist;
  late final double size;
  late final double rotationSpeed;
  late final Color color;
  late final bool isCircle;

  static const _palette = [
    Color(0xFFE88A68), // warm mango/coral
    Color(0xFF67B29F), // mint green
    Color(0xFFF2C94C), // joyful sunny gold
    Color(0xFF74B9FF), // gentle sky blue
    Color(0xFFFD79A8), // playful pink
    Color(0xFFA29BFE), // soft lavender
  ];
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter({required this.progress, required this.particles});

  final double progress;
  final List<_ConfettiParticle> particles;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      if (progress < p.delay) continue;
      final t = ((progress - p.delay) / (1.0 - p.delay)).clamp(0.0, 1.0);
      final y = t * (size.height + 40.0) - 20.0;
      final x = p.x * size.width + math.sin(t * math.pi * p.swaySpeed) * p.swayDist;
      final rot = t * math.pi * p.rotationSpeed;
      final alpha = (1.0 - t * 0.35).clamp(0.0, 1.0);

      final paint = Paint()
        ..color = p.color.withValues(alpha: alpha)
        ..style = PaintingStyle.fill;

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(rot);

      if (p.isCircle) {
        canvas.drawCircle(Offset.zero, p.size * 0.5, paint);
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset.zero,
              width: p.size * 1.3,
              height: p.size * 0.7,
            ),
            const Radius.circular(2),
          ),
          paint,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// Ambient drifting meadow clouds or playful floating bubbles.
class FloatingMeadowAmbiance extends StatefulWidget {
  const FloatingMeadowAmbiance({super.key});

  @override
  State<FloatingMeadowAmbiance> createState() => _FloatingMeadowAmbianceState();
}

class _FloatingMeadowAmbianceState extends State<FloatingMeadowAmbiance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 22),
  )..repeat();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: _anim,
      builder: (context, _) => CustomPaint(
        painter: _MeadowAmbiancePainter(progress: _anim.value),
        size: Size.infinite,
      ),
    ),
  );
}

class _MeadowAmbiancePainter extends CustomPainter {
  _MeadowAmbiancePainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final cloudPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.055)
      ..style = PaintingStyle.fill;

    // 3 gentle drifting clouds
    for (var i = 0; i < 3; i++) {
      final speed = 0.6 + i * 0.35;
      final startX = (i * 0.35 + progress * speed) % 1.3 - 0.15;
      final x = startX * size.width;
      final y = 24.0 + i * 36.0;
      final r = 26.0 + i * 8.0;

      canvas.drawCircle(Offset(x, y), r, cloudPaint);
      canvas.drawCircle(Offset(x + r * 0.7, y - 6), r * 0.8, cloudPaint);
      canvas.drawCircle(Offset(x - r * 0.7, y - 4), r * 0.7, cloudPaint);
      canvas.drawCircle(Offset(x + r * 1.3, y + 2), r * 0.6, cloudPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _MeadowAmbiancePainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// Starburst celebration effect when an item is tapped or popped.
class SparkleBurst extends StatefulWidget {
  const SparkleBurst({super.key, required this.position});

  final Offset position;

  @override
  State<SparkleBurst> createState() => _SparkleBurstState();
}

class _SparkleBurstState extends State<SparkleBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
  )..forward();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: _anim,
      builder: (context, _) {
        final t = _anim.value;
        if (t >= 1.0) return const SizedBox.shrink();
        return CustomPaint(
          painter: _SparklePainter(
            center: widget.position,
            progress: t,
          ),
          size: Size.infinite,
        );
      },
    ),
  );
}

class _SparklePainter extends CustomPainter {
  _SparklePainter({required this.center, required this.progress});

  final Offset center;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const count = 6;
    final dist = progress * 42.0;
    final scale = (1.0 - progress) * 5.0;
    final paint = Paint()
      ..color = const Color(0xFFFDCB6E).withValues(alpha: (1.0 - progress).clamp(0.0, 1.0))
      ..style = PaintingStyle.fill;

    for (var i = 0; i < count; i++) {
      final angle = (i * 2 * math.pi / count) + (progress * 0.5);
      final offset = center + Offset(math.cos(angle) * dist, math.sin(angle) * dist);
      canvas.drawCircle(offset, scale, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparklePainter oldDelegate) =>
      oldDelegate.progress != progress;
}
