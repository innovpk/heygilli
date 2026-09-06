import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/protocol.dart';
import '../../core/speech.dart';
import '../../core/theme.dart';
import 'gilli_widget.dart';

/// There is nothing approved to watch. Said out loud, calmly, once.
///
/// This is the state every household is in before the Curator has finished,
/// and it is the first thing a child sees on a brand new profile. Until now
/// the home rendered an empty list: a dark screen with nothing on it and no
/// way to tell whether the app was broken, still loading, or simply had
/// nothing yet.
///
/// Three rules it keeps, all of them the same ones [DayDoneScreen] keeps:
///
///  - **It is not an error.** Same teal, same Gilli, no red, and nothing that
///    suggests the child did anything wrong or should go and ask someone.
///  - **A pre-reader sees no text.** Band 4_6 gets the line spoken and nothing
///    written, like every other screen they meet (SPEC 5.1).
///  - **It promises nothing.** No "coming soon", no "Gilli is looking" — when
///    a household has added no channels at all, nothing *is* happening, and a
///    screen that implies otherwise is a screen that lies to a five-year-old.
class NothingYetScreen extends StatefulWidget {
  const NothingYetScreen({super.key, required this.kid});

  final Kid kid;

  @override
  State<NothingYetScreen> createState() => _NothingYetScreenState();
}

class _NothingYetScreenState extends State<NothingYetScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final preReader = widget.kid.band == AgeBand.b4to6;
      context.read<GilliVoice>().say(
        url: '',
        fallbackText: preReader
            ? 'Nothing to watch yet. Let us try again in a little while.'
            : 'Nothing to watch here yet. New videos turn up once they have '
                  'been checked.',
        slow: preReader,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<GilliVoice>();
    final showText = widget.kid.band.showsQuestionText;
    // Sits under the home's header in landscape, where height is short, so
    // Gilli is sized off what is actually left rather than a fixed number.
    return LayoutBuilder(
      builder: (context, box) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              GilliWidget(
                size: (box.maxHeight * 0.44).clamp(90.0, 180.0),
                gesture: Gesture.idle,
                talking: voice.speaking,
              ),
              if (showText) ...[
                Text(
                  'Nothing to watch yet',
                  textAlign: TextAlign.center,
                  style: HgText.display(size: 28),
                ),
                Text(
                  'Videos turn up here once they have been checked.',
                  textAlign: TextAlign.center,
                  style: HgText.body(size: 17, color: HgColors.sky),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
