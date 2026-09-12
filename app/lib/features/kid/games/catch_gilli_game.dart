import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../../core/app_state.dart';
import '../../../core/models.dart';
import '../../../core/play.dart';
import '../../../core/protocol.dart';
import '../../../core/sounds.dart';
import '../../../core/speech.dart';
import '../../../core/theme.dart';
import '../gilli_widget.dart';
import '../kid_palette.dart';
import 'game_fx.dart';
import 'game_parts.dart';

/// "Catch Gilli": he pops up somewhere in the meadow, and a tap or a mouse
/// click catches him before he ducks away.
///
/// Five pops a round. The Playmate agent sets how long he stays up, from how
/// many the child caught last time, and the code holds it above a floor for
/// each age band so a five-year-old is never chasing a blur.
class CatchGilliGame extends StatefulWidget {
  const CatchGilliGame({
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
  State<CatchGilliGame> createState() => _CatchGilliGameState();
}

class _CatchGilliGameState extends State<CatchGilliGame> {
  late final PlayCoach _coach = PlayCoach(
    gateway: context.read<AppState>().gateway,
    voice: context.read<GilliVoice>(),
    kid: widget.kid,
    game: PlayGame.catchGilli,
  );

  final _rng = Random();
  PlayTurn? _turn;
  PlayTurn? _end;
  int _stars = 0;
  int _caught = 0;
  int _pop = 0;
  bool _up = false;
  Offset _at = const Offset(0.5, 0.5);
  Offset? _burst;
  Completer<void>? _popDone;
  Timer? _hide;

  /// Bumped when this game goes away, so a round loop still awaiting a
  /// timer knows to stop.
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _next());
  }

  @override
  void dispose() {
    _gen++;
    _hide?.cancel();
    super.dispose();
  }

  Future<void> _next([Future<PlayTurn>? pending]) async {
    final t = await (pending ?? _coach.next());
    if (!mounted) return;
    setState(() {
      if (t.done) {
        _end = t;
        return;
      }
      _turn = t;
      _caught = 0;
      _pop = 0;
      _burst = null;
    });
    sayLater(_coach.say(t));
    if (!t.done) await _round(t);
  }

  Future<void> _round(PlayTurn t) async {
    final gen = ++_gen;
    // A moment for Gilli's line before the first pop.
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    for (var i = 0; i < t.pops; i++) {
      if (!mounted || gen != _gen) return;
      final done = Completer<void>();
      setState(() {
        _pop = i + 1;
        _up = true;
        _at = Offset(
          0.14 + _rng.nextDouble() * 0.72,
          0.18 + _rng.nextDouble() * 0.64,
        );
      });
      _popDone = done;
      _hide = Timer(Duration(milliseconds: t.showMs), () {
        if (!done.isCompleted) done.complete();
      });
      await done.future;
      _hide?.cancel();
      if (!mounted || gen != _gen) return;
      setState(() => _up = false);
      await Future<void>.delayed(
        Duration(milliseconds: 450 + _rng.nextInt(500)),
      );
    }
    if (!mounted || gen != _gen) return;
    _coach.record(
      PlayRound(
        round: t.round,
        won: _caught >= 3,
        caught: _caught,
        level: t.level,
      ),
    );
    setState(() => _stars++);
    final pending = _coach.next();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted || gen != _gen) return;
    await _next(pending);
  }

  void _catch() {
    final done = _popDone;
    if (!_up || done == null || done.isCompleted) return;
    KidSounds.instance.cheer();
    setState(() {
      _caught++;
      _burst = _at;
      _up = false;
    });
    done.complete();
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
    return Stack(
      children: [
        const FloatingMeadowAmbiance(),
        Column(
          children: [
            GameTopBar(
              onBack: widget.onBack,
              stars: _stars,
              below: _turn == null ? null : _CatchDots(caught: _caught),
            ),
            Expanded(child: LayoutBuilder(builder: _meadow)),
          ],
        ),
      ],
    );
  }

  Widget _meadow(BuildContext context, BoxConstraints box) {
    final w = box.maxWidth;
    final h = box.maxHeight;
    final big = widget.kid.band == AgeBand.b4to6;
    final g = (min(w, h) * (big ? 0.26 : 0.2)).clamp(56.0, 120.0);
    Offset place(Offset f) => Offset(f.dx * w - g / 2, f.dy * h - g / 2);
    final burst = _burst;
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        // Scenery for him to pop out of. Not tappable: only he is.
        for (final (x, y, s) in const [
          (0.08, 0.72, 0.30),
          (0.30, 0.20, 0.22),
          (0.62, 0.64, 0.34),
          (0.86, 0.26, 0.26),
        ])
          Positioned(
            left: x * w - s * h / 2,
            top: y * h - s * h / 2,
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.35,
                child: SvgPicture.asset(
                  'assets/icons/tree.svg',
                  width: s * h,
                  height: s * h,
                ),
              ),
            ),
          ),
        if (burst != null) ...[
          Positioned(
            left: place(burst).dx,
            top: place(burst).dy,
            child: IgnorePointer(
              child: TweenAnimationBuilder<double>(
                key: ValueKey('burst-$_caught'),
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 520),
                builder: (context, v, child) => Opacity(
                  opacity: 1 - v,
                  child: Transform.scale(scale: 0.6 + v, child: child),
                ),
                child: SvgPicture.asset(
                  'assets/icons/star.svg',
                  width: g,
                  height: g,
                ),
              ),
            ),
          ),
          SparkleBurst(
            key: ValueKey('sparkle-$_caught'),
            position: Offset(place(burst).dx + g / 2, place(burst).dy + g / 2),
          ),
        ],
        if (_up)
          Positioned(
            left: place(_at).dx,
            top: place(_at).dy,
            child: Semantics(
              button: true,
              label: 'Catch Gilli',
              child: GestureDetector(
                key: const Key('catch-gilli'),
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) {
                  KidSounds.instance.tap();
                  _catch();
                },
                child: TweenAnimationBuilder<double>(
                  key: ValueKey('pop-$_pop'),
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutBack,
                  builder: (context, v, child) =>
                      Transform.scale(scale: v, child: child),
                  child: GilliWidget(size: g, gesture: Gesture.point),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One dot per pop this round, filled for each catch. No numbers to read.
class _CatchDots extends StatelessWidget {
  const _CatchDots({required this.caught});
  final int caught;

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        for (var i = 0; i < popsPerRound; i++)
          AnimatedContainer(
            key: Key('catch-dot-$i-${i < caught ? 'on' : 'off'}'),
            duration: const Duration(milliseconds: 200),
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < caught ? HgColors.mango : palette.chip,
            ),
          ),
      ],
    );
  }
}
