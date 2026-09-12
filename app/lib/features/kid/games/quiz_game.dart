import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../../core/app_state.dart';
import '../../../core/icon_library.dart';
import '../../../core/models.dart';
import '../../../core/play.dart';
import '../../../core/protocol.dart';
import '../../../core/sounds.dart';
import '../../../core/speech.dart';
import '../../../core/theme.dart';
import '../gilli_widget.dart';
import '../kid_palette.dart';
import 'game_parts.dart';
import 'quiz_rounds.dart';

/// The card games: letters, sums, guess the animal, spot the animal.
///
/// One shape for all four. Gilli asks; cards go on the table; the child taps
/// one. A wrong card shakes and fades and the round goes on, and after two
/// of those the right card starts to wobble, so nobody is ever stuck. Every
/// round earns its star. The Playmate agent sets the level round by round
/// from how many tries the last ones took; the question itself is written
/// here, on the device, by [buildQuizRound].
class QuizGame extends StatefulWidget {
  const QuizGame({
    super.key,
    required this.kid,
    required this.game,
    required this.onBack,
    required this.onAgain,
    required this.onHome,
    this.rng,
  }) : assert(game != PlayGame.findGilli && game != PlayGame.catchGilli);

  final Kid kid;
  final PlayGame game;
  final VoidCallback onBack;
  final VoidCallback onAgain;
  final VoidCallback onHome;

  /// Seeded by tests so a round can be predicted; the app leaves it null.
  final Random? rng;

  @override
  State<QuizGame> createState() => QuizGameState();
}

class QuizGameState extends State<QuizGame> {
  late final PlayCoach _coach = PlayCoach(
    gateway: context.read<AppState>().gateway,
    voice: context.read<GilliVoice>(),
    kid: widget.kid,
    game: widget.game,
  );
  late final Random _rng = widget.rng ?? Random();

  PlayTurn? _turn;
  PlayTurn? _end;
  QuizRound? _round;
  int _taps = 0;
  final _wrong = <int>{};
  bool _got = false;
  int _stars = 0;

  /// The round on the table, for a test to learn the answer from.
  QuizRound? get round => _round;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _next());
  }

  Future<void> _next([Future<PlayTurn>? pending]) async {
    final t = await (pending ?? _coach.next());
    if (!mounted) return;
    final icons = context.read<IconLibrary>();
    setState(() {
      if (t.done) {
        _end = t;
        return;
      }
      _turn = t;
      _round = buildQuizRound(
        widget.game,
        t.level,
        widget.kid.band,
        _rng,
        icons,
      );
      _taps = 0;
      _wrong.clear();
      _got = false;
    });
    if (_end != null) {
      sayLater(_coach.say(t));
      return;
    }
    // Gilli's line, then the question, in one breath.
    sayLater(_sayRoundOf(t));
  }

  Future<void> _sayRoundOf(PlayTurn t) async {
    await _coach.say(t);
    final r = _round;
    if (!mounted || r == null || _turn != t) return;
    await _coach.say(PlayTurn(game: widget.game, line: r.speak));
  }

  Future<void> _tap(int i) async {
    final t = _turn;
    final r = _round;
    if (t == null || r == null || _got || _wrong.contains(i)) return;
    setState(() {
      _taps++;
      if (i != r.correct) {
        _wrong.add(i);
      } else {
        _got = true;
        _stars++;
      }
    });
    if (i != r.correct) return;
    KidSounds.instance.cheer();
    _coach.record(
      PlayRound(round: t.round, won: true, taps: _taps, level: t.level),
    );
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
    final r = _round;
    return Column(
      children: [
        GameTopBar(onBack: widget.onBack, stars: _stars),
        Expanded(
          child: r == null
              ? const SizedBox.shrink()
              : LayoutBuilder(builder: (context, box) => _table(r, box)),
        ),
      ],
    );
  }

  Widget _table(QuizRound r, BoxConstraints box) {
    final palette = KidPalette.of(context);
    final icons = context.read<IconLibrary>();
    final readers = widget.kid.band.showsQuestionText;
    final n = r.cards.length;
    final columns = r.columns ?? (n <= 3 ? n : (n <= 4 ? 2 : 3));
    final rows = (n / columns).ceil();
    final headRoom = readers || r.showing.isNotEmpty ? 0.34 : 0.22;
    final size = min(
      (box.maxWidth - 24) / columns - 12,
      (box.maxHeight * (1 - headRoom)) / rows - 12,
    ).clamp(64.0, 150.0);
    final hint = _wrong.length >= 2 && !_got;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            spacing: 12,
            children: [
              GilliWidget(
                size: (box.maxHeight * 0.16).clamp(56.0, 96.0),
                gesture: _got ? Gesture.cheer : Gesture.think,
                celebrateTick: _stars,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: [
                    if (readers)
                      Text(
                        r.prompt,
                        key: const Key('quiz-prompt'),
                        style: HgText.display(
                          size: widget.kid.band == AgeBand.b9to11 ? 22 : 24,
                          color: palette.onGround,
                        ),
                      ),
                    if (r.showing.isNotEmpty)
                      Wrap(
                        key: const Key('quiz-showing'),
                        spacing: 6,
                        children: [
                          for (final id in r.showing)
                            SvgPicture.asset(
                              icons.assetFor(id),
                              width: 44,
                              height: 44,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (var i = 0; i < n; i++)
                    _QuizCardTile(
                      key: Key('quiz-card-$i'),
                      card: r.cards[i],
                      size: size,
                      icons: icons,
                      showLabel: readers && widget.game != PlayGame.spotAnimal,
                      dim: _wrong.contains(i),
                      wobble:
                          (hint && i == r.correct) || (_got && i == r.correct),
                      onTap: _got || _wrong.contains(i) ? null : () => _tap(i),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _QuizCardTile extends StatefulWidget {
  const _QuizCardTile({
    super.key,
    required this.card,
    required this.size,
    required this.icons,
    required this.showLabel,
    required this.dim,
    required this.wobble,
    required this.onTap,
  });

  final QuizCard card;
  final double size;
  final IconLibrary icons;
  final bool showLabel;
  final bool dim;
  final bool wobble;
  final VoidCallback? onTap;

  @override
  State<_QuizCardTile> createState() => _QuizCardTileState();
}

class _QuizCardTileState extends State<_QuizCardTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wob = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
  );

  @override
  void didUpdateWidget(covariant _QuizCardTile old) {
    super.didUpdateWidget(old);
    if (widget.wobble && !old.wobble) {
      _wob.repeat(reverse: true);
    } else if (!widget.wobble && old.wobble) {
      _wob.stop();
      _wob.value = 0;
    }
  }

  @override
  void dispose() {
    _wob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.card;
    final size = widget.size;
    final label = widget.showLabel ? c.label : null;
    final body = c.isPicture
        ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 6,
            children: [
              SvgPicture.asset(
                widget.icons.assetFor(c.iconId!),
                width: size * (label != null && label.isNotEmpty ? 0.56 : 0.68),
                height:
                    size * (label != null && label.isNotEmpty ? 0.56 : 0.68),
              ),
              if (label != null && label.isNotEmpty)
                Text(
                  label,
                  textDirection: isUrduScript(label)
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  style: isUrduScript(label)
                      ? HgText.urdu(size: 18, color: HgColors.ink)
                      : HgText.display(size: 18, color: HgColors.ink),
                ),
            ],
          )
        : Center(
            child: FittedBox(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  c.text!,
                  style: HgText.display(
                    size: c.text!.length <= 2 ? size * 0.5 : size * 0.26,
                    color: HgColors.ink,
                  ),
                ),
              ),
            ),
          );
    final tile = AnimatedOpacity(
      duration: const Duration(milliseconds: 250),
      opacity: widget.dim ? 0.3 : 1,
      child: AnimatedBuilder(
        animation: _wob,
        builder: (context, child) =>
            Transform.rotate(angle: (_wob.value - 0.5) * 0.14, child: child),
        child: Container(
          width: size,
          height: size,
          constraints: const BoxConstraints(minWidth: 64, minHeight: 64),
          decoration: BoxDecoration(
            color: HgColors.white,
            borderRadius: BorderRadius.circular(size * 0.18),
            border: widget.wobble
                ? Border.all(color: HgColors.mango, width: 5)
                : null,
            boxShadow: const [
              BoxShadow(color: Color(0x1F0F2A33), offset: Offset(0, 8)),
            ],
          ),
          child: body,
        ),
      ),
    );
    return Semantics(
      button: widget.onTap != null,
      label: c.text ?? c.label ?? c.iconId,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Down, not up: a child's finger lands and lifts a little late.
        onTapDown: widget.onTap == null
            ? null
            : (_) {
                KidSounds.instance.tap();
                widget.onTap!();
              },
        child: tile,
      ),
    );
  }
}
