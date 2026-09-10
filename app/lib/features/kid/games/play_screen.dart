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
import 'catch_gilli_game.dart';
import 'find_gilli_game.dart';
import 'game_parts.dart';

/// Where a child picks one of Gilli's games. Reached by tapping him on the
/// shelf once he is awake.
///
/// Two big pictures and no words for a pre-reader; a label under each for
/// everyone else. Back goes from a game to this picker, and from here to the
/// shelf. None of it is behind the PIN: it is all still kid mode.
class PlayScreen extends StatefulWidget {
  const PlayScreen({super.key, required this.kid});
  final Kid kid;

  @override
  State<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends State<PlayScreen> {
  PlayGame? _game;

  /// Bumped for "again", so the game starts over with a fresh set of rounds.
  int _run = 0;

  late final GilliVoice _voice = context.read<GilliVoice>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      speakLine(
        context.read<AppState>().gateway,
        _voice,
        widget.kid.band == AgeBand.b4to6
            ? 'Let us play! Find me in the trees, or catch me!'
            : 'Which game? Find me in the trees, or catch me if you can!',
        slow: widget.kid.band == AgeBand.b4to6,
      );
    });
  }

  @override
  void dispose() {
    _voice.stop();
    super.dispose();
  }

  void _pick(PlayGame g) {
    _voice.stop();
    setState(() {
      _game = g;
      _run++;
    });
  }

  void _toPicker() => setState(() => _game = null);
  void _home() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
    final game = _game;
    return PopScope(
      // Back from a game is back to the picker, not out of play altogether.
      canPop: game == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _toPicker();
      },
      child: Scaffold(
        backgroundColor: palette.ground,
        body: SafeArea(
          child: switch (game) {
            null => _picker(palette),
            PlayGame.findGilli => FindGilliGame(
              key: ValueKey('find-$_run'),
              kid: widget.kid,
              onBack: _toPicker,
              onAgain: () => _pick(PlayGame.findGilli),
              onHome: _home,
            ),
            PlayGame.catchGilli => CatchGilliGame(
              key: ValueKey('catch-$_run'),
              kid: widget.kid,
              onBack: _toPicker,
              onAgain: () => _pick(PlayGame.catchGilli),
              onHome: _home,
            ),
          },
        ),
      ),
    );
  }

  Widget _picker(KidPalette palette) {
    final readers = widget.kid.band.showsQuestionText;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              KidRoundButton(
                icon: Icons.arrow_back_rounded,
                label: 'Back to videos',
                onTap: _home,
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              // Sized off the tile's width as well as the height: in a tall,
              // narrow window the height alone made Gilli fill the screen.
              final tileWidth = (box.maxWidth - 72) / 2;
              final pic = [
                box.maxHeight * 0.36,
                tileWidth * 0.55,
              ].reduce((a, b) => a < b ? a : b).clamp(56.0, 130.0);
              return Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Row(
                  spacing: 24,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: _GameTile(
                        key: const Key('game-find'),
                        label: 'Find Gilli',
                        showLabel: readers,
                        onTap: tapping(() => _pick(PlayGame.findGilli)),
                        picture: SizedBox.square(
                          dimension: pic,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              // Poking out from behind the leaves, left.
                              Positioned(
                                left: pic * 0.01,
                                bottom: pic * 0.23,
                                width: pic * 0.6,
                                height: pic * 0.6,
                                child: SvgPicture.asset(
                                  'assets/gilli/tail.svg',
                                ),
                              ),
                              Positioned.fill(
                                child: SvgPicture.asset(
                                  'assets/icons/tree.svg',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _GameTile(
                        key: const Key('game-catch'),
                        label: 'Catch Gilli',
                        showLabel: readers,
                        onTap: tapping(() => _pick(PlayGame.catchGilli)),
                        picture: SizedBox.square(
                          dimension: pic,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              GilliWidget(size: pic, gesture: Gesture.idle),
                              Positioned(
                                right: -pic * 0.05,
                                bottom: -pic * 0.05,
                                child: Icon(
                                  Icons.touch_app_rounded,
                                  size: pic * 0.42,
                                  color: HgColors.mango,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _GameTile extends StatelessWidget {
  const _GameTile({
    super.key,
    required this.label,
    required this.showLabel,
    required this.onTap,
    required this.picture,
  });

  final String label;
  final bool showLabel;
  final VoidCallback onTap;
  final Widget picture;

  @override
  Widget build(BuildContext context) {
    final palette = KidPalette.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: palette.card,
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(28),
          // As tall as what is in it, not the whole screen.
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 10,
              children: [
                picture,
                if (showLabel)
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: HgText.display(size: 20, color: palette.onGround),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
