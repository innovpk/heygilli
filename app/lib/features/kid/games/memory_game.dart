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

/// "Flip & Match": a delightful memory card matching game.
///
/// Cards are laid out face down. The child taps a card to flip it over,
/// then taps another. If they match, they sparkle and stay matched!
/// Short 5-round game with progressive pair counts.
class MemoryGame extends StatefulWidget {
  const MemoryGame({
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
  State<MemoryGame> createState() => _MemoryGameState();
}

class _MemoryCardItem {
  _MemoryCardItem({required this.id, required this.icon});

  final int id;
  final String icon;
  bool isFaceUp = false;
  bool isMatched = false;
}

class _MemoryGameState extends State<MemoryGame> {
  late final PlayCoach _coach = PlayCoach(
    gateway: context.read<AppState>().gateway,
    voice: context.read<GilliVoice>(),
    kid: widget.kid,
    game: PlayGame.memoryMatch,
  );

  final math.Random _rng = math.Random();
  PlayTurn? _turn;
  PlayTurn? _end;
  int _stars = 0;
  int _taps = 0;

  List<_MemoryCardItem> _cards = [];
  int? _firstFlippedIndex;
  bool _checking = false;
  Offset? _sparklePos;

  static const List<String> _iconPool = [
    'cat',
    'dog',
    'lion',
    'elephant',
    'duck',
    'frog',
    'butterfly',
    'apple',
    'banana',
    'star',
    'car',
    'rocket',
    'sun',
    'flower',
  ];

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
      _firstFlippedIndex = null;
      _checking = false;
      _sparklePos = null;
      _setupCards(t);
    });
    sayLater(_coach.say(t));
  }

  void _setupCards(PlayTurn t) {
    // Number of pairs based on round and level
    int pairs;
    if (t.round <= 2) {
      pairs = 2; // 4 cards
    } else if (t.round <= 4) {
      pairs = 3; // 6 cards
    } else {
      pairs = (widget.kid.band == AgeBand.b4to6 || t.level <= 2) ? 3 : 4; // 6 or 8 cards
    }

    final pool = List<String>.of(_iconPool)..shuffle(_rng);
    final chosen = pool.take(pairs).toList();
    final items = <_MemoryCardItem>[];
    var id = 0;
    for (final icon in chosen) {
      items.add(_MemoryCardItem(id: id++, icon: icon));
      items.add(_MemoryCardItem(id: id++, icon: icon));
    }
    items.shuffle(_rng);
    _cards = items;
  }

  void _onCardTap(int index, BuildContext cardContext) {
    if (_checking) return;
    final card = _cards[index];
    if (card.isFaceUp || card.isMatched) return;

    setState(() {
      _taps++;
      card.isFaceUp = true;
    });

    if (_firstFlippedIndex == null) {
      _firstFlippedIndex = index;
    } else {
      final firstIdx = _firstFlippedIndex!;
      final firstCard = _cards[firstIdx];
      _firstFlippedIndex = null;

      if (firstCard.icon == card.icon) {
        // Matched!
        firstCard.isMatched = true;
        card.isMatched = true;
        KidSounds.instance.cheer();

        final box = cardContext.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) {
          final pos = box.localToGlobal(box.size.center(Offset.zero));
          setState(() => _sparklePos = pos);
        }

        final allMatched = _cards.every((c) => c.isMatched);
        if (allMatched) {
          _onRoundWon();
        }
      } else {
        // Did not match: flip back over after a short moment
        _checking = true;
        Timer(const Duration(milliseconds: 950), () {
          if (!mounted) return;
          setState(() {
            firstCard.isFaceUp = false;
            card.isFaceUp = false;
            _checking = false;
          });
        });
      }
    }
  }

  Future<void> _onRoundWon() async {
    final t = _turn;
    if (t == null) return;
    setState(() => _stars++);
    _coach.record(
      PlayRound(
        round: t.round,
        won: true,
        taps: _taps,
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
            ),
            Expanded(
              child: t == null
                  ? const SizedBox.shrink()
                  : LayoutBuilder(
                      builder: (context, box) => _grid(box, palette),
                    ),
            ),
          ],
        ),
        if (_sparklePos != null)
          SparkleBurst(
            key: ValueKey('sparkle-$_stars-$_taps'),
            position: _sparklePos!,
          ),
      ],
    );
  }

  Widget _grid(BoxConstraints box, KidPalette palette) {
    final count = _cards.length;
    final columns = count <= 4 ? 2 : (box.maxWidth >= 600 ? 4 : 3);
    final rows = (count / columns).ceil();

    final maxW = (box.maxWidth - 48 - (columns - 1) * 14) / columns;
    final maxH = (box.maxHeight - 32 - (rows - 1) * 14) / rows;
    final cardDim = math.min(maxW, maxH).clamp(64.0, 130.0);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Wrap(
          spacing: 14,
          runSpacing: 14,
          alignment: WrapAlignment.center,
          children: [
            for (var i = 0; i < _cards.length; i++)
              Builder(
                builder: (cardCtx) => SizedBox.square(
                  key: Key('memory-card-$i'),
                  dimension: cardDim,
                  child: _FlipCard(
                    card: _cards[i],
                    dim: cardDim,
                    onTap: () => _onCardTap(i, cardCtx),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FlipCard extends StatelessWidget {
  const _FlipCard({
    required this.card,
    required this.dim,
    required this.onTap,
  });

  final _MemoryCardItem card;
  final double dim;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final showFace = card.isFaceUp || card.isMatched;

    return BouncyTouch(
      onTap: showFace ? null : onTap,
      scaleDown: 0.94,
      child: TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeInOutBack,
        tween: Tween<double>(begin: 0, end: showFace ? 1.0 : 0.0),
        builder: (context, angle, child) {
          final isFront = angle >= 0.5;
          final transform = Matrix4.identity()
            ..setEntry(3, 2, 0.002)
            ..rotateY(angle * math.pi);

          return Transform(
            alignment: Alignment.center,
            transform: transform,
            child: isFront
                ? Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()..rotateY(math.pi),
                    child: _front(context),
                  )
                : _back(context),
          );
        },
      ),
    );
  }

  Widget _front(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: HgColors.white,
        borderRadius: BorderRadius.circular(dim * 0.18),
        border: Border.all(
          color: card.isMatched ? HgColors.green : HgColors.mango,
          width: card.isMatched ? 3.0 : 2.0,
        ),
        boxShadow: [
          BoxShadow(
            color: (card.isMatched ? HgColors.green : HgColors.mango)
                .withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: EdgeInsets.all(dim * 0.18),
      child: SvgPicture.asset(
        'assets/icons/${card.icon}.svg',
        fit: BoxFit.contain,
      ),
    );
  }

  Widget _back(BuildContext context) {
    final palette = KidPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.chip,
        borderRadius: BorderRadius.circular(dim * 0.18),
        border: Border.all(color: HgColors.sky.withValues(alpha: 0.4), width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Center(
        child: Icon(
          Icons.star_rounded,
          size: dim * 0.44,
          color: palette.accent.withValues(alpha: 0.65),
        ),
      ),
    );
  }
}
