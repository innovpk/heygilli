import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/sounds.dart';
import '../../core/theme.dart';

/// Thematic wallpapers for the kid shelf, inspired by YouTube Kids.
///
/// Gives children visual agency over their own screen environment without
/// altering content boundaries or parent rules.
enum KidBackgroundTheme {
  cosmic(
    id: 'cosmic',
    name: 'Space',
    emoji: '🚀',
    icon: Icons.rocket_launch_rounded,
    primaryGround: Color(0xFF0F2620),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0xFF0A1C17),
        Color(0xFF132D26),
        Color(0xFF1E3A34),
      ],
    ),
  ),
  ocean(
    id: 'ocean',
    name: 'Ocean',
    emoji: '🌊',
    icon: Icons.waves_rounded,
    primaryGround: Color(0xFF0B262D),
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFF081F26),
        Color(0xFF0E323A),
        Color(0xFF15444E),
      ],
    ),
  ),
  jungle(
    id: 'jungle',
    name: 'Jungle',
    emoji: '🌴',
    icon: Icons.park_rounded,
    primaryGround: Color(0xFF10281D),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0xFF0C2016),
        Color(0xFF143526),
        Color(0xFF1B4431),
      ],
    ),
  ),
  sunset(
    id: 'sunset',
    name: 'Sunset',
    emoji: '🌅',
    icon: Icons.wb_twilight_rounded,
    primaryGround: Color(0xFF281928),
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFF201322),
        Color(0xFF331C2E),
        Color(0xFF452436),
      ],
    ),
  ),
  classic(
    id: 'classic',
    name: 'Classic',
    emoji: '✨',
    icon: Icons.auto_awesome_rounded,
    primaryGround: HgColors.teal,
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFF162C27),
        HgColors.teal,
        Color(0xFF1E3A34),
      ],
    ),
  );

  const KidBackgroundTheme({
    required this.id,
    required this.name,
    required this.emoji,
    required this.icon,
    required this.primaryGround,
    required this.gradient,
  });

  final String id;
  final String name;
  final String emoji;
  final IconData icon;
  final Color primaryGround;
  final Gradient gradient;

  static KidBackgroundTheme fromId(String? id) {
    if (id == null) return KidBackgroundTheme.cosmic;
    for (final theme in KidBackgroundTheme.values) {
      if (theme.id == id) return theme;
    }
    return KidBackgroundTheme.cosmic;
  }
}

/// Paints the decorative background gradient and playful illustrations behind
/// the kid shelf.
class KidBackground extends StatelessWidget {
  const KidBackground({
    super.key,
    required this.theme,
    required this.child,
  });

  final KidBackgroundTheme theme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(gradient: theme.gradient),
      child: CustomPaint(
        painter: KidBackgroundPainter(theme: theme),
        child: child,
      ),
    );
  }
}

/// Miniature preview thumbnail of a theme, used inside the picker cards.
class KidBackgroundThumbnail extends StatelessWidget {
  const KidBackgroundThumbnail({super.key, required this.theme});

  final KidBackgroundTheme theme;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(gradient: theme.gradient),
      child: CustomPaint(
        painter: KidBackgroundPainter(theme: theme, isThumbnail: true),
      ),
    );
  }
}

/// Custom vector painter that renders tasteful, high-contrast decorative art
/// on canvas. Uses normalized coordinates for pixel-perfect scaling across
/// phones, tablets, foldables, and desktop widths.
class KidBackgroundPainter extends CustomPainter {
  KidBackgroundPainter({required this.theme, this.isThumbnail = false});

  final KidBackgroundTheme theme;
  final bool isThumbnail;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    switch (theme) {
      case KidBackgroundTheme.cosmic:
        _paintCosmic(canvas, size);
      case KidBackgroundTheme.ocean:
        _paintOcean(canvas, size);
      case KidBackgroundTheme.jungle:
        _paintJungle(canvas, size);
      case KidBackgroundTheme.sunset:
        _paintSunset(canvas, size);
      case KidBackgroundTheme.classic:
        _paintClassic(canvas, size);
    }
  }

  // --- Space / Cosmic ---
  void _paintCosmic(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Glowing crescent moon
    final moonCenter = Offset(w * 0.88, h * 0.16);
    final moonRadius = (size.shortestSide * 0.08).clamp(16.0, 52.0);
    _drawCrescentMoon(canvas, moonCenter, moonRadius, const Color(0x3CDCEEEA));

    // Little Saturn / ringed planet
    final planetCenter = Offset(w * 0.09, h * 0.76);
    final planetR = (size.shortestSide * 0.035).clamp(8.0, 22.0);
    canvas.drawCircle(
      planetCenter,
      planetR,
      Paint()..color = const Color(0x35E0A96D),
    );
    canvas.save();
    canvas.translate(planetCenter.dx, planetCenter.dy);
    canvas.rotate(-0.35);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: planetR * 2.8, height: planetR * 0.8),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = isThumbnail ? 1.5 : 2.5
        ..color = const Color(0x3CF0A48C),
    );
    canvas.restore();

    // Shooting star trail
    if (!isThumbnail) {
      final cometStart = Offset(w * 0.28, h * 0.08);
      final cometEnd = Offset(w * 0.16, h * 0.16);
      canvas.drawLine(
        cometStart,
        cometEnd,
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0x55F0A48C), Color(0x00F0A48C)],
          ).createShader(Rect.fromPoints(cometStart, cometEnd))
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round,
      );
      _drawTwinkleStar(canvas, cometStart, 5.0, const Color(0x77FFFFFF));
    }

    // Twinkling stars
    const starPoints = [
      Offset(0.12, 0.18),
      Offset(0.24, 0.42),
      Offset(0.40, 0.12),
      Offset(0.58, 0.32),
      Offset(0.72, 0.14),
      Offset(0.82, 0.48),
      Offset(0.20, 0.68),
      Offset(0.38, 0.84),
      Offset(0.66, 0.78),
      Offset(0.92, 0.70),
      Offset(0.50, 0.60),
    ];

    for (var i = 0; i < starPoints.length; i++) {
      final p = starPoints[i];
      final pos = Offset(p.dx * w, p.dy * h);
      final r = (i % 3 == 0) ? 6.0 : (i % 2 == 0 ? 4.5 : 3.0);
      _drawTwinkleStar(
        canvas,
        pos,
        isThumbnail ? r * 0.7 : r,
        const Color(0x40DCEEEA),
      );
    }
  }

  // --- Ocean Adventure ---
  void _paintOcean(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Gentle surface waves
    final wavePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = isThumbnail ? 2.0 : 3.0
      ..strokeCap = StrokeCap.round
      ..color = const Color(0x187AD1C4);

    final wave1 = Path()..moveTo(0, h * 0.08);
    for (double x = 0; x <= w; x += 60) {
      wave1.quadraticBezierTo(
        x + 15,
        h * 0.08 - 8,
        x + 30,
        h * 0.08,
      );
      wave1.quadraticBezierTo(
        x + 45,
        h * 0.08 + 8,
        x + 60,
        h * 0.08,
      );
    }
    canvas.drawPath(wave1, wavePaint);

    // Swimming fish
    final fish1 = Offset(w * 0.20, h * 0.36);
    final fish2 = Offset(w * 0.76, h * 0.65);
    _drawFish(canvas, fish1, isThumbnail ? 16.0 : 28.0, true, const Color(0x2870C8B8));
    _drawFish(canvas, fish2, isThumbnail ? 14.0 : 24.0, false, const Color(0x25F0A48C));

    // Floating bubbles
    const bubblePoints = [
      Offset(0.08, 0.40),
      Offset(0.15, 0.64),
      Offset(0.32, 0.22),
      Offset(0.48, 0.72),
      Offset(0.64, 0.26),
      Offset(0.82, 0.44),
      Offset(0.88, 0.82),
      Offset(0.94, 0.32),
    ];

    for (var i = 0; i < bubblePoints.length; i++) {
      final bp = bubblePoints[i];
      final pos = Offset(bp.dx * w, bp.dy * h);
      final r = isThumbnail ? (i % 2 == 0 ? 5.0 : 3.5) : (i % 2 == 0 ? 11.0 : 7.0);
      _drawBubble(canvas, pos, r, const Color(0x289CC9BE));
    }

    // Starfish at bottom right
    final starCenter = Offset(w * 0.88, h * 0.90);
    _drawStarfish(canvas, starCenter, isThumbnail ? 12.0 : 22.0, const Color(0x30F0A48C));

    // Seaweed fronds swaying up from bottom left
    _drawSeaweed(canvas, Offset(w * 0.05, h), isThumbnail ? 35.0 : 75.0, const Color(0x222E7A68));
    _drawSeaweed(canvas, Offset(w * 0.08, h), isThumbnail ? 25.0 : 55.0, const Color(0x1C3A9480));
  }

  // --- Jungle Safari ---
  void _paintJungle(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Corner leaves arching in
    final leafSize = (size.shortestSide * 0.22).clamp(30.0, 110.0);
    _drawLeaf(
      canvas,
      Offset.zero,
      Offset(w * 0.12, h * 0.14),
      leafSize,
      const Color(0x2E55A675),
    );
    _drawLeaf(
      canvas,
      Offset(w * 0.04, 0),
      Offset(w * 0.20, h * 0.08),
      leafSize * 0.8,
      const Color(0x22438C5E),
    );
    _drawLeaf(
      canvas,
      Offset(w, 0),
      Offset(w * 0.86, h * 0.16),
      leafSize,
      const Color(0x284AA06E),
    );

    // Glowing fireflies / forest spores
    const fireflyPoints = [
      Offset(0.18, 0.35),
      Offset(0.35, 0.55),
      Offset(0.52, 0.25),
      Offset(0.70, 0.45),
      Offset(0.85, 0.32),
      Offset(0.28, 0.80),
      Offset(0.78, 0.75),
    ];

    for (final fp in fireflyPoints) {
      final pos = Offset(fp.dx * w, fp.dy * h);
      final r = isThumbnail ? 3.0 : 5.0;
      canvas.drawCircle(pos, r * 2.2, Paint()..color = const Color(0x18B5EAA8));
      canvas.drawCircle(pos, r, Paint()..color = const Color(0x45B5EAA8));
    }

    // Rolling jungle hill silhouette across bottom
    final hillPaint = Paint()..color = const Color(0x20143526);
    final hillPath = Path()
      ..moveTo(0, h)
      ..lineTo(0, h * 0.92)
      ..quadraticBezierTo(w * 0.35, h * 0.85, w * 0.70, h * 0.91)
      ..quadraticBezierTo(w * 0.88, h * 0.94, w, h * 0.88)
      ..lineTo(w, h)
      ..close();
    canvas.drawPath(hillPath, hillPaint);
  }

  // --- Sunset Desert ---
  void _paintSunset(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Setting sun disk with warm glow
    final sunCenter = Offset(w * 0.50, h * 0.82);
    final sunR = (size.shortestSide * 0.12).clamp(24.0, 70.0);
    canvas.drawCircle(sunCenter, sunR * 1.8, Paint()..color = const Color(0x10F0A48C));
    canvas.drawCircle(sunCenter, sunR * 1.3, Paint()..color = const Color(0x18F0A48C));
    canvas.drawCircle(sunCenter, sunR, Paint()..color = const Color(0x35F0A48C));

    // Fluffy clouds
    final cloudWidth = isThumbnail ? 40.0 : 90.0;
    _drawCloud(canvas, Offset(w * 0.18, h * 0.22), cloudWidth, const Color(0x24FAD6CE));
    _drawCloud(canvas, Offset(w * 0.74, h * 0.18), cloudWidth * 1.2, const Color(0x22FAD6CE));
    if (!isThumbnail) {
      _drawCloud(canvas, Offset(w * 0.42, h * 0.32), cloudWidth * 0.8, const Color(0x1AFAD6CE));
    }

    // Distant mountain ridges across bottom
    final ridgePaint = Paint()..color = const Color(0x2A281426);
    final ridgePath = Path()
      ..moveTo(0, h)
      ..lineTo(0, h * 0.90)
      ..lineTo(w * 0.25, h * 0.84)
      ..lineTo(w * 0.52, h * 0.89)
      ..lineTo(w * 0.78, h * 0.83)
      ..lineTo(w, h * 0.88)
      ..lineTo(w, h)
      ..close();
    canvas.drawPath(ridgePath, ridgePaint);

    // Flying bird silhouettes
    final birdSize = isThumbnail ? 5.0 : 9.0;
    _drawBird(canvas, Offset(w * 0.35, h * 0.15), birdSize, const Color(0x3CF0A48C));
    _drawBird(canvas, Offset(w * 0.39, h * 0.18), birdSize * 0.75, const Color(0x32F0A48C));
    _drawBird(canvas, Offset(w * 0.62, h * 0.25), birdSize * 0.85, const Color(0x35F0A48C));
  }

  // --- Classic HeyGilli ---
  void _paintClassic(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = isThumbnail ? 1.5 : 2.0
      ..color = const Color(0x0EFFFFFF);

    // Gentle concentric geometric circles
    final corner = Offset(w * 0.95, h * 0.10);
    final r1 = (size.shortestSide * 0.20).clamp(30.0, 100.0);
    canvas.drawCircle(corner, r1, arcPaint);
    canvas.drawCircle(corner, r1 * 1.6, arcPaint);

    final corner2 = Offset(w * 0.05, h * 0.90);
    canvas.drawCircle(corner2, r1 * 0.8, arcPaint);
    canvas.drawCircle(corner2, r1 * 1.4, arcPaint);

    // Little spark dots
    _drawTwinkleStar(canvas, Offset(w * 0.15, h * 0.25), isThumbnail ? 4.0 : 6.0, const Color(0x22FFFFFF));
    _drawTwinkleStar(canvas, Offset(w * 0.80, h * 0.75), isThumbnail ? 4.0 : 6.0, const Color(0x22FFFFFF));
  }

  // --- Helper Vector Drawing Methods ---

  void _drawCrescentMoon(Canvas canvas, Offset center, double radius, Color color) {
    final moon = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    final cutter = Path()
      ..addOval(Rect.fromCircle(
        center: center + Offset(radius * 0.35, -radius * 0.20),
        radius: radius * 0.85,
      ));
    final crescent = Path.combine(PathOperation.difference, moon, cutter);
    canvas.drawPath(crescent, Paint()..color = color);
  }

  void _drawTwinkleStar(Canvas canvas, Offset center, double radius, Color color) {
    final path = Path();
    path.moveTo(center.dx, center.dy - radius);
    path.quadraticBezierTo(center.dx, center.dy, center.dx + radius, center.dy);
    path.quadraticBezierTo(center.dx, center.dy, center.dx, center.dy + radius);
    path.quadraticBezierTo(center.dx, center.dy, center.dx - radius, center.dy);
    path.quadraticBezierTo(center.dx, center.dy, center.dx, center.dy - radius);
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _drawBubble(Canvas canvas, Offset center, double radius, Color color) {
    canvas.drawCircle(center, radius, Paint()..color = color);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color.withValues(alpha: (color.a * 1.6).clamp(0.0, 1.0)),
    );
    canvas.drawCircle(
      center + Offset(-radius * 0.32, -radius * 0.32),
      (radius * 0.22).clamp(1.0, 3.5),
      Paint()..color = const Color(0x66FFFFFF),
    );
  }

  void _drawFish(Canvas canvas, Offset center, double size, bool facingRight, Color color) {
    final dir = facingRight ? 1.0 : -1.0;
    final path = Path();
    path.moveTo(center.dx + dir * size * 0.5, center.dy);
    path.quadraticBezierTo(center.dx, center.dy - size * 0.3, center.dx - dir * size * 0.3, center.dy);
    path.lineTo(center.dx - dir * size * 0.6, center.dy - size * 0.25);
    path.lineTo(center.dx - dir * size * 0.45, center.dy);
    path.lineTo(center.dx - dir * size * 0.6, center.dy + size * 0.25);
    path.lineTo(center.dx - dir * size * 0.3, center.dy);
    path.quadraticBezierTo(center.dx, center.dy + size * 0.3, center.dx + dir * size * 0.5, center.dy);
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _drawStarfish(Canvas canvas, Offset center, double radius, Color color) {
    final path = Path();
    const points = 5;
    for (var i = 0; i < points * 2; i++) {
      final angle = i * math.pi / points - math.pi / 2;
      final r = i.isEven ? radius : radius * 0.45;
      final pt = Offset(center.dx + r * math.cos(angle), center.dy + r * math.sin(angle));
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _drawSeaweed(Canvas canvas, Offset base, double height, Color color) {
    final path = Path()..moveTo(base.dx, base.dy);
    const segments = 4;
    final segHeight = height / segments;
    for (var i = 0; i < segments; i++) {
      final y = base.dy - (i + 1) * segHeight;
      final dx = (i.isEven ? 8.0 : -8.0);
      path.quadraticBezierTo(base.dx + dx, y + segHeight * 0.5, base.dx, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  void _drawLeaf(Canvas canvas, Offset start, Offset tip, double width, Color color) {
    final path = Path();
    final mid = (start + tip) / 2;
    final delta = tip - start;
    final normal = Offset(-delta.dy, delta.dx);
    final len = normal.distance;
    final n = len > 0 ? normal / len : const Offset(0, 1);
    path.moveTo(start.dx, start.dy);
    path.quadraticBezierTo(mid.dx + n.dx * width, mid.dy + n.dy * width, tip.dx, tip.dy);
    path.quadraticBezierTo(mid.dx - n.dx * width * 0.4, mid.dy - n.dy * width * 0.4, start.dx, start.dy);
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _drawCloud(Canvas canvas, Offset center, double width, Color color) {
    final r = width * 0.25;
    final paint = Paint()..color = color;
    canvas.drawCircle(center + Offset(-r * 0.75, 0), r * 0.7, paint);
    canvas.drawCircle(center + Offset(0, -r * 0.35), r, paint);
    canvas.drawCircle(center + Offset(r * 0.75, 0), r * 0.65, paint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: center + Offset(0, r * 0.18), width: width, height: r * 0.8),
        Radius.circular(r * 0.4),
      ),
      paint,
    );
  }

  void _drawBird(Canvas canvas, Offset center, double size, Color color) {
    final path = Path();
    path.moveTo(center.dx - size, center.dy);
    path.quadraticBezierTo(center.dx - size * 0.5, center.dy - size * 0.6, center.dx, center.dy);
    path.quadraticBezierTo(center.dx + size * 0.5, center.dy - size * 0.6, center.dx + size, center.dy);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant KidBackgroundPainter oldDelegate) =>
      oldDelegate.theme != theme || oldDelegate.isThumbnail != isThumbnail;
}

/// Displays the playful bottom sheet allowing the child to tap and pick
/// their background.
void showKidBackgroundPicker({
  required BuildContext context,
  required KidBackgroundTheme currentTheme,
  required ValueChanged<KidBackgroundTheme> onSelected,
}) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => _KidBackgroundPickerSheet(
      currentTheme: currentTheme,
      onSelected: onSelected,
    ),
  );
}

class _KidBackgroundPickerSheet extends StatelessWidget {
  const _KidBackgroundPickerSheet({
    required this.currentTheme,
    required this.onSelected,
  });

  final KidBackgroundTheme currentTheme;
  final ValueChanged<KidBackgroundTheme> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF162C27),
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 20,
            offset: Offset(0, -4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: const Color(0x44DCEEEA),
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Header title row
            Row(
              children: [
                const Icon(
                  Icons.palette_rounded,
                  color: HgColors.accentTint,
                  size: 26,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Choose your background',
                    style: HgText.display(size: 24, color: HgColors.cream),
                  ),
                ),
                Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  child: InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    customBorder: const CircleBorder(),
                    child: const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Icon(
                        Icons.close_rounded,
                        color: HgColors.cream,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Horizontal cards list
            SizedBox(
              height: 144,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: KidBackgroundTheme.values.length,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (ctx, i) {
                  final theme = KidBackgroundTheme.values[i];
                  final isSelected = theme == currentTheme;
                  return _ThemeCard(
                    theme: theme,
                    isSelected: isSelected,
                    onTap: () {
                      KidSounds.instance.tap();
                      onSelected(theme);
                      Navigator.of(context).pop();
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.theme,
    required this.isSelected,
    required this.onTap,
  });

  final KidBackgroundTheme theme;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: isSelected,
      label: '${theme.name} background',
      child: Material(
        color: const Color(0xFF1E3A34),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: isSelected
              ? const BorderSide(color: HgColors.accentTint, width: 3.5)
              : const BorderSide(color: Color(0x26DCEEEA), width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 120,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top thumbnail preview
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: KidBackgroundThumbnail(theme: theme),
                      ),
                      Center(
                        child: Text(
                          theme.emoji,
                          style: const TextStyle(fontSize: 32),
                        ),
                      ),
                      if (isSelected)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: HgColors.mango,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.check_rounded,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // Bottom theme label
                Container(
                  color: isSelected
                      ? const Color(0x28F0A48C)
                      : const Color(0x18DCEEEA),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    theme.name,
                    textAlign: TextAlign.center,
                    style: HgText.display(
                      size: 17,
                      color: isSelected ? HgColors.accentTint : HgColors.cream,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
