import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/hg_cta.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

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
const _breakIcons = {
  'stretch': 'tree',
  'jump': 'star',
  'water': 'water',
  'window': 'sun',
  'draw': 'triangle',
  'tidy': 'house',
  'walk': 'leaf',
  'pet': 'cat',
};

class _PreferencesScreenState extends State<PreferencesScreen> {
  final _picked = <String>{};
  final _breaks = <String>{};
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
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: _step == 0
                          ? _Question(
                              key: const ValueKey('q-topics'),
                              step: 0,
                              of: _steps,
                              question: 'What is $name into?',
                              // Not punished with a blank screen: "I do not
                              // know yet" is the commonest answer here. The
                              // same words whatever is picked, so the answers
                              // do not jump under the finger on the first tap.
                              hint:
                                  'Pick any. Or none — Gilli will look at '
                                  'everything suited to age ${widget.kid.age}.',
                              options: data?.topics ?? const [],
                              icons: _topicIcons,
                              chosen: _picked,
                              onTap: _busy
                                  ? null
                                  : (id) => _toggle(_picked, id),
                            )
                          : _Question(
                              key: const ValueKey('q-breaks'),
                              step: 1,
                              of: _steps,
                              question: 'What should Gilli suggest at a break?',
                              hint:
                                  'Pick a few $name would really get up and '
                                  'do. Gilli says those when the video pauses.',
                              options: data?.breakActivities ?? const [],
                              icons: _breakIcons,
                              chosen: _breaks,
                              onTap: _busy
                                  ? null
                                  : (id) => _toggle(_breaks, id),
                            ),
                    ),
                  ),
                ),
                _BottomBar(
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

/// One question: where you are, what is asked, and the answers as tiles.
class _Question extends StatelessWidget {
  const _Question({
    super.key,
    required this.step,
    required this.of,
    required this.question,
    required this.hint,
    required this.options,
    required this.icons,
    required this.chosen,
    required this.onTap,
  });

  final int step;
  final int of;
  final String question;
  final String hint;
  final List<StarterTopic> options;
  final Map<String, String> icons;
  final Set<String> chosen;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
    children: [
      _Progress(step: step, of: of),
      const SizedBox(height: 14),
      Text(question, style: HgText.display(size: 30, color: HgColors.ink)),
      const SizedBox(height: 6),
      Text(hint, style: HgText.body(size: 15, color: HgColors.brown)),
      const SizedBox(height: 18),
      LayoutBuilder(
        builder: (context, box) {
          // One answer to a row on a phone: two to a row left the longest
          // labels ("Letters, numbers and school subjects") about fifty
          // points, and they broke mid-word.
          final columns = box.maxWidth >= 640 ? 2 : 1;
          const gap = 12.0;
          final width = (box.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final o in options)
                SizedBox(
                  width: width,
                  child: _Tile(
                    label: o.label,
                    icon: icons[o.id],
                    chosen: chosen.contains(o.id),
                    onTap: onTap == null ? null : () => onTap!(o.id),
                  ),
                ),
            ],
          );
        },
      ),
    ],
  );
}

/// "Question 1 of 2", and a bar for it.
class _Progress extends StatelessWidget {
  const _Progress({required this.step, required this.of});
  final int step;
  final int of;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 12,
    children: [
      Text(
        'QUESTION ${step + 1} OF $of',
        style: HgText.label(color: HgColors.mango),
      ),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: (step + 1) / of,
            minHeight: 6,
            backgroundColor: HgColors.white,
            valueColor: const AlwaysStoppedAnimation(HgColors.mango),
          ),
        ),
      ),
    ],
  );
}

/// A big answer: a picture, the words, and a tick once it is chosen.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.icon,
    required this.chosen,
    required this.onTap,
  });

  final String label;
  final String? icon;
  final bool chosen;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: chosen,
    label: label,
    excludeSemantics: true,
    child: Material(
      color: HgColors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: chosen ? HgColors.mango : HgColors.line,
              width: chosen ? 3 : 1.5,
            ),
          ),
          child: Row(
            spacing: 12,
            children: [
              if (icon != null)
                Container(
                  width: 44,
                  height: 44,
                  padding: const EdgeInsets.all(7),
                  decoration: const BoxDecoration(
                    color: HgColors.cream,
                    shape: BoxShape.circle,
                  ),
                  child: SvgPicture.asset('assets/icons/$icon.svg'),
                ),
              Expanded(
                child: Text(
                  label,
                  style: HgText.body(
                    size: 15,
                    color: HgColors.ink,
                    weight: chosen ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 140),
                opacity: chosen ? 1 : 0,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: const BoxDecoration(
                    color: HgColors.mango,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: HgColors.white,
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

/// Back and the next step, fixed to the bottom, instead of a button floating
/// over the answers it was covering.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.error,
    required this.showBack,
    required this.onBack,
    required this.label,
    required this.busy,
    required this.onNext,
    required this.footnote,
  });

  final String? error;
  final bool showBack;
  final VoidCallback? onBack;
  final String label;
  final bool busy;
  final VoidCallback onNext;
  final String footnote;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: HgColors.white,
      border: Border(top: BorderSide(color: HgColors.line)),
    ),
    child: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                if (error != null)
                  Text(
                    error!,
                    style: HgText.body(size: 14, color: HgColors.coral),
                  ),
                Row(
                  spacing: 12,
                  children: [
                    if (showBack)
                      TextButton.icon(
                        onPressed: onBack,
                        icon: const Icon(Icons.arrow_back_rounded, size: 18),
                        label: const Text('Back'),
                        style: TextButton.styleFrom(
                          foregroundColor: HgColors.ink,
                          minimumSize: const Size(0, 48),
                        ),
                      ),
                    const Spacer(),
                    // Never disabled: "I don't know yet" is a real answer to
                    // both questions, and a dead button would say otherwise.
                    HgCta(label: label, busy: busy, onPressed: onNext),
                  ],
                ),
                Text(
                  footnote,
                  textAlign: TextAlign.center,
                  style: HgText.body(size: 12, color: HgColors.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
