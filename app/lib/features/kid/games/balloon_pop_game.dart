import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../../core/app_state.dart';
import '../../../core/models.dart';
import '../../../core/play.dart';
import '../../../core/sounds.dart';
import '../../../core/speech.dart';
import '../../../core/theme.dart';
import '../kid_palette.dart';
import 'game_fx.dart';
import 'game_parts.dart';

/// "Balloon Pop": a cheerful floating balloon popping game.
///
/// Colorful balloons drift upward on a meadow breeze. The child taps to
/// pop them with satisfying burst animations and joyful sound effects!
class BalloonPopGame extends StatefulWidget {
  const BalloonPopGame({
    super.key,
    required this.kid,
    required this.onBack,
    required this.onAgain,
    required this.onHome,
  });

  final Kid kid;
  final VoidCallback onBack;
  final VoidCallback onAgain;
  final VoidCallback onHome;

  @override
  State<BalloonPopGame> createState() => _BalloonPopGameState();
}

class _BalloonItem {
  _BalloonItem({
    required this.id,
    required this.icon,
    required this.color,
    required this.xRatio,
    required this.speed,
    required this.wobblePhase,
  });

  final int id;
  final String icon;
  final Color color;
  final double xRatio; // 0.1 to 0.9
  final double speed;
  final double wobblePhase;
  double y = 1.15; // starts below screen, moves up to -0.2
  bool isPopped = false;
}

class _BalloonPopGameState extends State<BalloonPopGame>
    with SingleTickerProviderStateMixin {
  late final PlayCoach _coach = PlayCoach(
    gateway: context.read<AppState>().gateway,
    voice: context.read<GilliVoice>(),
    kid: widget.kid,
    game: PlayGame.balloonPop,
  );

  final math.Random _rng = math.Random();
  PlayTurn? _turn;
  PlayTurn? _end;
  int _stars = 0;
  int _caught = 0;
  int _targetPops = 3;

  late final AnimationController _ticker = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  final List<_BalloonItem> _balloons = [];
  Timer? _spawnTimer;
  int _balloonId = 0;
  Offset? _popBurstPos;

  static const List<Color> _balloonColors = [
    Color(0xFFFF7675), // coral pink
    Color(0xFF74B9FF), // sky blue
    Color(0xFFFDCB6E), // sunny yellow
    Color(0xFF55EFC4), // mint green
    Color(0xFFA29BFE), // gentle purple
    Color(0xFFFF9F43), // joyful orange
  ];

  static const List<String> _balloonIcons = [
    'star',
    'apple',
    'cat',
    'sun',
    'flower',
    'rocket',
    'duck',
    'butterfly',
  ];

  @override
  void initState() {
    super.initState();
    _ticker.addListener(_onTick);
    WidgetsBinding.instance.addPostFrameCallback((_) => _next());
  }

  @override
  void dispose() {
    _ticker.removeListener(_onTick);
    _ticker.dispose();
    _spawnTimer?.cancel();
    super.dispose();
  }

  void _onTick() {
    if (!mounted || _balloons.isEmpty) return;
    setState(() {
      for (final b in _balloons) {
        if (!b.isPopped) {
          b.y -= b.speed * 0.0075;
          if (b.y < -0.25) {
            b.y = 1.15 + _rng.nextDouble() * 0.3;
          }
        }
      }
    });
  }

  Future<void> _next([Future<PlayTurn>? pending]) async {
    final t = await (pending ?? _coach.next());
    if (!mounted) return;
    setState(() {
      if (t.done) {
        _end = t;
        _spawnTimer?.cancel();
        return;
      }
      _turn = t;
      _caught = 0;
      _targetPops = widget.kid.band == AgeBand.b4to6 ? 3 : (3 + (t.level > 2 ? 1 : 0));
      _popBurstPos = null;
      _initBalloons();
    });
    sayLater(_coach.say(t));
  }

  void _initBalloons() {
    _balloons.clear();
    final count = widget.kid.band == AgeBand.b4to6 ? 4 : 6;
    for (var i = 0; i < count; i++) {
      _spawnBalloon(initialY: 0.2 + (i / count) * 0.9);
    }
  }

  void _spawnBalloon({double? initialY}) {
    final color = _balloonColors[_rng.nextInt(_balloonColors.length)];
    final icon = _balloonIcons[_rng.nextInt(_balloonIcons.length)];
    final x = 0.12 + _rng.nextDouble() * 0.76;
    final speed = 0.8 + _rng.nextDouble() * 0.6;
    final phase = _rng.nextDouble() * math.pi * 2;

    _balloons.add(
      _BalloonItem(
        id: _balloonId++,
        icon: icon,
        color: color,
        xRatio: x,
        speed: speed,
        wobblePhase: phase,
      )..y = initialY ?? (1.15 + _rng.nextDouble() * 0.2),
    );
  }

  void _onPop(int index, BuildContext balloonCtx) {
    if (index >= _balloons.length) return;
    final b = _balloons[index];
    if (b.isPopped) return;

    final box = balloonCtx.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      setState(() => _popBurstPos = pos);
    }

    KidSounds.instance.tap();

    setState(() {
      b.isPopped = true;
      _caught++;
    });

    if (_caught >= _targetPops) {
      _onRoundWon();
    } else {
      // Respawn balloon after pop
      Timer(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        setState(() {
          b.isPopped = false;
          b.y = 1.15 + _rng.nextDouble() * 0.15;
        });
      });
    }
  }

  Future<void> _onRoundWon() async {
    final t = _turn;
    if (t == null) return;
    KidSounds.instance.cheer();
    setState(() => _stars++);
    _coach.record(
      PlayRound(
        round: t.round,
        won: true,
        caught: _caught,
        level: t.level,
      ),
    );
    final pending = _coach.next();
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (!mounted) return;
    await _next(pending);
  }

  @override
  Widget build(BuildContext context) {
    final end = _end;
    if (end != null) {
      return GameOver(
        kid: widget.kid,
        stars: _stars,
        onAgain: end.roundsLeftToday > 0 ? widget.onAgain : null,
        onHome: widget.onHome,
      );
    }

    final t = _turn;
    final palette = KidPalette.of(context);

    return Stack(
      children: [
        const FloatingMeadowAmbiance(),
        Column(
          children: [
            GameTopBar(
              onBack: widget.onBack,
              stars: _stars,
              below: t != null
                  ? Text(
                      '$_caught / $_targetPops popped!',
                      style: HgText.display(size: 18, color: palette.onGround),
                    )
                  : null,
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (var i = 0; i < _balloons.length; i++)
                      _renderBalloon(i, box),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (_popBurstPos != null)
          SparkleBurst(
            key: ValueKey('pop-burst-$_caught'),
            position: _popBurstPos!,
          ),
      ],
    );
  }

  Widget _renderBalloon(int index, BoxConstraints box) {
    final b = _balloons[index];
    if (b.isPopped) return const SizedBox.shrink();

    final balloonW = (box.maxWidth * 0.18).clamp(64.0, 110.0);
    final balloonH = balloonW * 1.35;

    // Wobble horizontally on sinusoidal path
    final wobble = math.sin((_ticker.value * 2 * math.pi) + b.wobblePhase) * 12.0;
    final x = (b.xRatio * box.maxWidth) + wobble - (balloonW * 0.5);
    final y = b.y * box.maxHeight;

    return Positioned(
      left: x.clamp(8.0, box.maxWidth - balloonW - 8.0),
      top: y,
      width: balloonW,
      height: balloonH,
      child: Builder(
        builder: (balloonCtx) => BouncyTouch(
          scaleDown: 0.88,
          onTap: () => _onPop(index, balloonCtx),
          child: _BalloonWidget(
            color: b.color,
            icon: b.icon,
            width: balloonW,
            height: balloonH,
          ),
        ),
      ),
    );
  }
}

class _BalloonWidget extends StatelessWidget {
  const _BalloonWidget({
    required this.color,
    required this.icon,
    required this.width,
    required this.height,
  });

  final Color color;
  final String icon;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        // Balloon Body
        Container(
          width: width,
          height: height * 0.88,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.all(
              Radius.elliptical(width * 0.5, height * 0.44),
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.38),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Stack(
            children: [
              // Glossy highlight
              Positioned(
                top: height * 0.09,
                left: width * 0.15,
                child: Container(
                  width: width * 0.22,
                  height: height * 0.14,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.all(
                      Radius.elliptical(width * 0.11, height * 0.07),
                    ),
                  ),
                ),
              ),
              // Icon on balloon
              Center(
                child: SizedBox.square(
                  dimension: width * 0.45,
                  child: SvgPicture.asset(
                    'assets/icons/$icon.svg',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ],
          ),
        ),
        // Knot and string
        Positioned(
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Knot
              Container(
                width: 10,
                height: 6,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              // String
              Container(
                width: 2,
                height: height * 0.1,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
