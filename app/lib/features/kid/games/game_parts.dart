import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/api_client.dart' show ApiException;
import '../../../core/gateway.dart';
import '../../../core/models.dart';
import '../../../core/play.dart';
import '../../../core/protocol.dart';
import '../../../core/speech.dart';
import '../../../core/theme.dart';
import '../gilli_widget.dart';
import '../kid_palette.dart';

/// One game's worth of rounds, and the go-between with the Playmate agent.
///
/// The agent is asked for each round as the last one ends, while Gilli is
/// still celebrating, so a child rarely waits on it. When it is slow or out
/// of reach the device's own rule takes over; a break starting or the day
/// running out ends the game, because games follow the same gate as videos.
class PlayCoach {
  PlayCoach({
    required this.gateway,
    required this.voice,
    required this.kid,
    required this.game,
  });

  final Gateway gateway;
  final GilliVoice voice;
  final Kid kid;
  final PlayGame game;
  final rounds = <PlayRound>[];

  /// Long enough for a model call and Polly on a cold gateway; short enough
  /// that a child is not left looking at an empty meadow.
  static const wait = Duration(seconds: 6);

  Future<PlayTurn> next() async {
    try {
      return await gateway
          .playTurn(kid.id, game, List.of(rounds))
          .timeout(wait);
    } on ApiException catch (e) {
      if (e.status == 409) {
        return PlayTurn(
          game: game,
          done: true,
          line: 'Time to stop playing now.',
        );
      }
    } catch (_) {
      // Slow or unreachable: the rule below does the same job.
    }
    return PlayTurn.local(game, rounds, kid.band);
  }

  void record(PlayRound r) => rounds.add(r);

  Future<void> say(PlayTurn t) async {
    if (t.line.isEmpty) return;
    try {
      await voice.say(
        url: t.ttsUrl,
        fallbackText: t.line,
        slow: kid.band == AgeBand.b4to6,
      );
    } catch (_) {
      // Games carry on without a voice.
    }
  }
}

/// A big round picture button: 56 dp, the same size as the shelf's own.
class KidRoundButton extends StatelessWidget {
  const KidRoundButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.size = 56,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double size;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: filled ? HgColors.mango : palette.chip,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: size,
            child: Icon(
              icon,
              size: size * 0.5,
              color: filled ? HgColors.white : palette.onGround,
            ),
          ),
        ),
      ),
    );
  }
}

/// One star per round played. Every round earns one: nobody loses a round
/// to Gilli, he is only sneakier some times than others.
class RoundStars extends StatelessWidget {
  const RoundStars({super.key, required this.done, this.size = 30});
  final int done;
  final double size;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: size * 0.25,
    children: [
      for (var i = 0; i < roundsPerGame; i++)
        Opacity(
          key: Key('round-star-$i-${i < done ? 'on' : 'off'}'),
          opacity: i < done ? 1 : 0.22,
          child: SvgPicture.asset(
            'assets/icons/star.svg',
            width: size,
            height: size,
          ),
        ),
    ],
  );
}

/// Back, and the stars so far.
class GameTopBar extends StatelessWidget {
  const GameTopBar({
    super.key,
    required this.onBack,
    required this.stars,
    this.below,
  });

  final VoidCallback onBack;
  final int stars;

  /// Anything that belongs under the stars, like "Catch"'s count of catches.
  final Widget? below;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: Row(
      children: [
        KidRoundButton(
          icon: Icons.arrow_back_rounded,
          label: 'Back',
          onTap: onBack,
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              RoundStars(done: stars),
              ?below,
            ],
          ),
        ),
        const SizedBox(width: 56),
      ],
    ),
  );
}

/// The end of a game: Gilli cheering, the stars, and where to go next.
class GameOver extends StatelessWidget {
  const GameOver({
    super.key,
    required this.kid,
    required this.stars,
    required this.onAgain,
    required this.onHome,
  });

  final Kid kid;
  final int stars;

  /// Null once today's rounds are spent: there is no "again" to offer.
  final VoidCallback? onAgain;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
    final readers = kid.band.showsQuestionText;
    Widget choice(IconData icon, String label, VoidCallback onTap, Key key) =>
        Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            KidRoundButton(
              key: key,
              icon: icon,
              label: label,
              onTap: onTap,
              size: 72,
              filled: true,
            ),
            if (readers)
              Text(
                label,
                style: HgText.display(size: 20, color: palette.onGround),
              ),
          ],
        );
    return LayoutBuilder(
      builder: (context, box) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 18,
            children: [
              GilliWidget(
                size: (box.maxHeight * 0.3).clamp(80.0, 140.0),
                gesture: Gesture.cheer,
              ),
              RoundStars(done: stars, size: 32),
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 40,
                children: [
                  if (onAgain != null)
                    choice(
                      Icons.replay_rounded,
                      'Again',
                      onAgain!,
                      const Key('game-again'),
                    ),
                  choice(
                    Icons.video_library_rounded,
                    'Videos',
                    onHome,
                    const Key('game-home'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fires `unawaited` without the lint, for lines Gilli says while play goes on.
void sayLater(Future<void> f) => unawaited(f);
