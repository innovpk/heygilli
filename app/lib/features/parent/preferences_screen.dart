import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/break_activities.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';
import 'question_widgets.dart';

/// What this child likes, asked one question at a time.
///
/// Setting a child up used to mean picking channels off a list. That is the
/// wrong question to put to a parent: they are being asked to vouch for a
/// channel's entire future output on the strength of a one-line blurb, before
/// they have seen a single thing it makes. And the blurbs could be wrong —
/// two of twenty-six pointed somewhere else entirely, which is how a
/// motivational-quotes channel came to be offered as science and a repost
/// account with a "horror video" on it came to be offered to four-year-olds.
///
/// So the channels are the server's problem, and the parent is asked the
/// questions they can actually answer. What comes back is videos, each with
/// Gilli's reading of it, which is a thing they can look at and judge.
///
/// Two questions, each on a page of its own. They used to share one page as
/// two walls of chips, and a parent reading it could not tell where one
/// decision stopped and the next began.
class PreferencesScreen extends StatefulWidget {
  const PreferencesScreen({super.key, required this.kid});
  final Kid kid;

  @override
  State<PreferencesScreen> createState() => _PreferencesScreenState();
}

/// A picture for each answer, from the icons the app already ships. Scanning
/// eight pictures is quicker than reading eight labels; an id with no picture
/// here still shows, as text alone.
const _topicIcons = {
  'songs': 'happy',
  'stories': 'moon',
  'science': 'rocket',
  'animals': 'giraffe',
  'making': 'flower',
  'school': 'bus',
};

class _PreferencesScreenState extends State<PreferencesScreen> {
  final _picked = <String>{};

  /// Two gentle ones start ticked. With nothing picked, a break is Gilli
  /// saying "break time" and nothing else, and a child left with no idea what
  /// to do waits it out. These are still the parent's choice: ticked in front
  /// of them, and one tap to untick.
  final _breaks = <String>{'stretch', 'water'};
  late final Future<StarterChannels> _data = context
      .read<AppState>()
      .gateway
      .starterChannels(band: widget.kid.band.wire);
  bool _busy = false;
  String? _error;

  /// 0 is what they are into, 1 is what to do at a break.
  int _step = 0;
  static const _steps = 2;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      await context.read<AppState>().gateway.setPreferences(
        widget.kid.id,
        _picked.toList(),
        breakActivities: _breaks.toList(),
      );
      navigator.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not save that: $e';
        });
      }
    }
  }

  void _toggle(Set<String> into, String id) =>
      setState(() => into.contains(id) ? into.remove(id) : into.add(id));

  List<Widget> _tiles(
    List<StarterTopic> options,
    Map<String, String> icons,
    Set<String> chosen,
  ) => [
    AnswerGrid(
      children: [
        for (final o in options)
          AnswerTile(
            label: o.label,
            icon: icons[o.id],
            chosen: chosen.contains(o.id),
            onTap: _busy ? null : () => _toggle(chosen, o.id),
          ),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final name = widget.kid.nickname;
    return PopScope(
      // Back on the second question goes to the first, not out of the flow:
      // a parent correcting an answer should not lose the other one.
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step > 0) setState(() => _step--);
      },
      child: ParentScaffold(
        title: 'What $name likes',
        subtitle: 'FOR $name, AGE ${widget.kid.age}'.toUpperCase(),
        body: FutureBuilder<StarterChannels>(
          future: _data,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(
                child: CircularProgressIndicator(color: HgColors.mango),
              );
            }
            final data = snap.data;
            return Column(
              children: [
                Expanded(
                  child: _step == 0
                      ? QuestionPage(
                          key: const ValueKey('q-topics'),
                          step: 0,
                          of: _steps,
                          question: 'What is $name into?',
                          // Not punished with a blank screen: "I do not know
                          // yet" is the commonest answer here. The same words
                          // whatever is picked, so the answers do not jump
                          // under the finger on the first tap.
                          hint:
                              'Pick any. Or none — Gilli will look at '
                              'everything suited to age ${widget.kid.age}.',
                          children: _tiles(
                            data?.topics ?? const [],
                            _topicIcons,
                            _picked,
                          ),
                        )
                      : QuestionPage(
                          key: const ValueKey('q-breaks'),
                          step: 1,
                          of: _steps,
                          question: 'What should Gilli suggest at a break?',
                          hint:
                              'Pick a few $name would really get up and '
                              'do. Gilli says those when the video pauses.',
                          children: _tiles(
                            data?.breakActivities ?? const [],
                            breakActivityIcons,
                            _breaks,
                          ),
                        ),
                ),
                QuestionBottomBar(
                  error: _error,
                  showBack: _step > 0,
                  onBack: _busy ? null : () => setState(() => _step--),
                  label: _step < _steps - 1 ? 'Next' : 'Find videos',
                  busy: _busy,
                  onNext: _step < _steps - 1
                      ? () => setState(() => _step++)
                      : _go,
                  footnote:
                      "All of this can be changed later from $name's page.",
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
