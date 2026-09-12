import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../../core/app_state.dart';
import '../../../core/models.dart';
import '../../../core/play.dart';
import '../../../core/protocol.dart';
import '../../../core/sounds.dart';
import '../../../core/speech.dart';
import '../gilli_widget.dart';
import 'game_fx.dart';
import 'game_parts.dart';

/// "Find Gilli": he hides behind one of the trees, and the child taps trees
/// until he pops out.
///
/// There is no losing. A tree he is not behind gives a shake and fades, and
/// after two of those the right one starts to rustle. The Playmate agent sets
/// how many trees and whether his tail pokes out, round by round, from how
/// quickly the last ones went.
class FindGilliGame extends StatefulWidget {
  const FindGilliGame({
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
  State<FindGilliGame> createState() => _FindGilliGameState();
}

class _FindGilliGameState extends State<FindGilliGame> {
  late final PlayCoach _coach = PlayCoach(
    gateway: context.read<AppState>().gateway,
    voice: context.read<GilliVoice>(),
    kid: widget.kid,
    game: PlayGame.findGilli,
  );

  PlayTurn? _turn;
  PlayTurn? _end;
  int _taps = 0;
  final _wrong = <int>{};
  final _shakes = <int, int>{};
  bool _found = false;
  int _stars = 0;
  Offset? _foundPos;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _next());
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
      _taps = 0;
      _wrong.clear();
      _shakes.clear();
      _found = false;
      _foundPos = null;
    });
    sayLater(_coach.say(t));
  }

  Future<void> _tap(int i, [BuildContext? treeCtx]) async {
    final t = _turn;
    if (t == null || _found || _wrong.contains(i)) return;
    setState(() {
      _taps++;
      _shakes[i] = (_shakes[i] ?? 0) + 1;
      if (i != t.spot) {
        _wrong.add(i);
      } else {
        _found = true;
        _stars++;
        if (treeCtx != null) {
          final box = treeCtx.findRenderObject() as RenderBox?;
          if (box != null && box.hasSize) {
            _foundPos = box.localToGlobal(box.size.center(Offset.zero));
          }
        }
      }
    });
    if (i != t.spot) return;
    KidSounds.instance.cheer();
    _coach.record(
      PlayRound(round: t.round, won: true, taps: _taps, level: t.level),
    );
    // Ask for the next round while he is still cheering.
    final pending = _coach.next();
    await Future<void>.delayed(const Duration(milliseconds: 1600));
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
    return Stack(
      children: [
        const FloatingMeadowAmbiance(),
        Column(
          children: [
            GameTopBar(onBack: widget.onBack, stars: _stars),
            Expanded(
              child: t == null
                  ? const SizedBox.shrink()
                  : LayoutBuilder(builder: (context, box) => _meadow(t, box)),
            ),
          ],
        ),
        if (_foundPos != null)
          SparkleBurst(
            key: ValueKey('found-sparkle-$_stars'),
            position: _foundPos!,
          ),
      ],
    );
  }

  Widget _meadow(PlayTurn t, BoxConstraints box) {
    final n = t.trees.clamp(1, 8);
    final rows = n <= 4 ? 1 : 2;
    final perRow = (n / rows).ceil();
    final size = math
        .min(box.maxWidth / (perRow * 1.25), box.maxHeight / (rows * 1.3))
        .clamp(56.0, 140.0);
    final hint = _wrong.length >= 2 && !_found;
    Widget tree(int i) => Builder(
      builder: (treeCtx) => _Tree(
        key: Key('tree-$i'),
        size: size,
        shakes: _shakes[i] ?? 0,
        dim: _wrong.contains(i),
        rustle: hint && i == t.spot,
        peek: t.peek && i == t.spot && !_found,
        found: _found && i == t.spot,
        onTap: () => _tap(i, treeCtx),
      ),
    );
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (var r = 0; r < rows; r++)
          Padding(
            // The back row sits a little in, so the meadow is not a grid.
            padding: EdgeInsets.symmetric(horizontal: r.isOdd ? size * 0.5 : 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var i = r * perRow; i < math.min(n, (r + 1) * perRow); i++)
                  tree(i),
              ],
            ),
          ),
      ],
    );
  }
}

class _Tree extends StatefulWidget {
  const _Tree({
    super.key,
    required this.size,
    required this.shakes,
    required this.dim,
    required this.rustle,
    required this.peek,
    required this.found,
    required this.onTap,
  });

  final double size;
  final int shakes;
  final bool dim;
  final bool rustle;
  final bool peek;
  final bool found;
  final VoidCallback onTap;

  @override
  State<_Tree> createState() => _TreeState();
}

class _TreeState extends State<_Tree> with SingleTickerProviderStateMixin {
  late final AnimationController _rustle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_Tree old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.rustle && !_rustle.isAnimating) {
      _rustle.repeat();
    } else if (!widget.rustle && _rustle.isAnimating) {
      _rustle
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _rustle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return Semantics(
      button: true,
      label: 'Tree',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Down, not up: a small hand lifts slowly and a mouse click should
        // feel instant.
        onTapDown: (_) {
          KidSounds.instance.tap();
          widget.onTap();
        },
        child: SizedBox(
          width: s,
          height: s,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // His tail, behind the tree, poking out at the side.
              if (widget.peek)
                Positioned(
                  // The tail layer is a full Gilli canvas with the tail in
                  // its lower left, so this puts the tail itself beside the
                  // left of the leaves rather than the canvas.
                  left: -s * 0.04,
                  bottom: s * 0.15,
                  width: s * 0.7,
                  height: s * 0.7,
                  child: const _WaggingTail(key: Key('gilli-tail')),
                ),
              Positioned.fill(
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(widget.shakes),
                  tween: Tween(begin: widget.shakes == 0 ? 1 : 0, end: 1),
                  duration: const Duration(milliseconds: 450),
                  builder: (context, v, child) => AnimatedBuilder(
                    animation: _rustle,
                    builder: (context, child) => Transform.rotate(
                      alignment: Alignment.bottomCenter,
                      angle:
                          math.sin(v * math.pi * 6) * 0.09 * (1 - v) +
                          math.sin(_rustle.value * 2 * math.pi) * 0.05,
                      child: child,
                    ),
                    child: child,
                  ),
                  child: AnimatedOpacity(
                    opacity: widget.dim ? 0.4 : 1,
                    duration: const Duration(milliseconds: 300),
                    child: SvgPicture.asset('assets/icons/tree.svg'),
                  ),
                ),
              ),
              // Found: up he pops from behind the leaves.
              if (widget.found)
                Positioned(
                  left: s * 0.15,
                  top: -s * 0.32,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeOutBack,
                    builder: (context, v, child) => Transform.translate(
                      offset: Offset(0, (1 - v) * s * 0.45),
                      child: Opacity(opacity: v.clamp(0, 1), child: child),
                    ),
                    child: GilliWidget(
                      key: const Key('gilli-found'),
                      size: s * 0.7,
                      gesture: Gesture.cheer,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Just his tail, swishing. The clue that he is behind this one.
class _WaggingTail extends StatefulWidget {
  const _WaggingTail({super.key});

  @override
  State<_WaggingTail> createState() => _WaggingTailState();
}

class _WaggingTailState extends State<_WaggingTail>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, child) => Transform.rotate(
      angle: (_c.value - 0.5) * 0.4,
      alignment: const Alignment(-0.51, 0.56),
      child: child,
    ),
    child: SvgPicture.asset('assets/gilli/tail.svg'),
  );
}
