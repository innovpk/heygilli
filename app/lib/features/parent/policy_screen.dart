import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';
import 'question_widgets.dart';

/// What this household actually wants (PROTOCOL "Household policy"), saved
/// with `PUT /kids/{id}/policy`.
///
/// "Is this all right for a child" has no general answer, so HeyGilli asks
/// instead of guessing. Three things follow, and they are enforced here rather
/// than left to a prompt:
///
///  - **The questions come from this child's own channels.** Every card shows
///    the `why` the Coach sent with it, naming what prompted it. A question
///    with nothing behind it says so plainly instead of implying a finding.
///  - **Skipping is an answer.** An unanswered question carries no weight, so
///    an untouched question is never sent as a quiet "fine", and a policy with
///    nothing in it is a valid setting, not an unfinished setup step.
///  - **Nothing here hides a video.** The strongest thing a parent can say is
///    "Rather not", and that routes a video to their inbox. The card says so
///    under the button, where they are deciding.
class PolicyScreen extends StatefulWidget {
  /// Picking an answer turns the page by itself. Long enough to see the tile
  /// light up and read what the answer does; short enough that Next is not
  /// missed.
  static const advanceAfter = Duration(milliseconds: 700);

  const PolicyScreen({super.key, required this.kid, this.setup = false});

  final Kid kid;

  /// Part of setting a child up, rather than a settings page reached later.
  ///
  /// The answers are what every upload is then read against, so they belong
  /// before the channels and not after: a household that picked channels
  /// first had them screened against nothing it had said, and the screen a
  /// parent finally found was in the Rules tab, under the time limits.
  ///
  /// In setup it moves on when it saves, and can be skipped — skipping is an
  /// answer here too, and a parent who wants to look at the app before
  /// deciding what they think must not be held at a wall of questions.
  final bool setup;

  @override
  State<PolicyScreen> createState() => _PolicyScreenState();
}

/// The two calls this screen opens with, kept together so the questions and
/// the answers already given arrive as one thing to render.
typedef _Loaded = ({Policy policy, PolicyQuestions questions});

class _PolicyScreenState extends State<PolicyScreen> {
  late Future<_Loaded> _future = _load();

  final _notes = TextEditingController();

  /// Only the questions this parent has actually answered. A question missing
  /// from here is unanswered, and unanswered is not a choice with a weight.
  final _choices = <String, PolicyChoice>{};

  Map<String, PolicyChoice> _savedChoices = const {};
  String _savedNotes = '';

  /// The questions as they were asked, so a saved answer stays readable after
  /// the Coach stops proposing that question.
  final _asked = <String, String>{};

  Policy? _policy;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _advance?.cancel();
    _notes.dispose();
    super.dispose();
  }

  Future<_Loaded> _load() async {
    final gateway = context.read<AppState>().gateway;
    // Both start together: the questions are a model call and the saved policy
    // is a read, and waiting for one before the other only makes the parent
    // wait twice.
    final policyCall = gateway.policy(widget.kid.id);
    final questionsCall = gateway.policyQuestions(widget.kid.id);
    final policy = await policyCall;
    final questions = await questionsCall;

    _policy = policy;
    _choices
      ..clear()
      ..addEntries([for (final a in policy.answers) MapEntry(a.id, a.choice)]);
    _savedChoices = Map.of(_choices);
    _asked.addEntries([
      for (final a in policy.answers) MapEntry(a.id, a.question),
      for (final q in questions.questions) MapEntry(q.id, q.question),
    ]);
    _notes.text = policy.notes;
    _savedNotes = policy.notes;
    return (policy: policy, questions: questions);
  }

  void _reload() => setState(() {
    _future = _load();
  });

  bool get _dirty =>
      _notes.text.trim() != _savedNotes.trim() ||
      _choices.length != _savedChoices.length ||
      _choices.entries.any((e) => _savedChoices[e.key] != e.value);

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Answered questions only. Sending an untouched question as "fine"
      // would put an opinion in this household's mouth.
      final answers = [
        for (final e in _choices.entries)
          PolicyAnswer(
            id: e.key,
            question: _asked[e.key] ?? '',
            choice: e.value,
            // The weight is the server's. An answer the parent left alone
            // keeps the one it earned; a changed one starts again at nothing
            // rather than carrying the old answer's weight.
            weight: _savedChoices[e.key] == e.value
                ? (_policy?.answerFor(e.key)?.weight ?? 0)
                : 0,
          ),
      ];
      final saved = await context.read<AppState>().gateway.savePolicy(
        widget.kid.id,
        answers: answers,
        notes: _notes.text.trim(),
      );
      if (!mounted) return;
      if (widget.setup) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _policy = saved;
        _savedChoices = Map.of(_choices);
        _savedNotes = saved.notes;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Which page of the setup questionnaire is showing. One past the last
  /// question is the page for the parent's own words.
  int _step = 0;

  Timer? _advance;

  void _go(int step) {
    _advance?.cancel();
    _advance = null;
    setState(() => _step = step);
  }

  void _choose(PolicyQuestion q, PolicyChoice c, int step) {
    _advance?.cancel();
    _advance = null;
    setState(() {
      // Tapping the choice again clears it: a parent who answered by accident
      // can get back to unanswered, which is a different thing from "fine".
      if (_choices[q.id] == c) {
        _choices.remove(q.id);
      } else {
        _choices[q.id] = c;
      }
    });
    if (_choices[q.id] == null) return;
    // One choice is the whole answer, so it turns the page. Only if the
    // parent is still on it: Back or Next in the meantime wins.
    _advance = Timer(PolicyScreen.advanceAfter, () {
      _advance = null;
      if (mounted && _step == step) setState(() => _step = step + 1);
    });
  }

  /// Setup asks one question to a page. As a list of cards it was a wall a
  /// parent scrolled past; one at a time, each is a thing to decide, and
  /// "Skip this one" says out loud that skipping is allowed.
  ///
  /// Settings keeps the list: a parent who comes back is looking for one
  /// answer to change, and paging through the rest to find it is slower.
  Widget _questionnaire(List<PolicyQuestion> questions) {
    final name = widget.kid.nickname;
    final pages = questions.length + 1;
    final step = _step.clamp(0, pages - 1);
    final last = step == pages - 1;
    final q = last ? null : questions[step];
    final chosen = q == null ? null : _choices[q.id];

    return PopScope(
      // Back goes to the previous question rather than out of setup, so an
      // answer being corrected does not cost the others.
      canPop: step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && step > 0) _go(step - 1);
      },
      child: Column(
        children: [
          Expanded(
            child: q != null
                ? QuestionPage(
                    key: ValueKey('policy-${q.id}'),
                    step: step,
                    of: pages,
                    question: q.question,
                    // Always shown. A question a parent cannot trace back to
                    // their own child's channels is a question from nowhere.
                    hint: q.why.isNotEmpty
                        ? q.why
                        : 'Gilli did not say which channels prompted this one.',
                    children: [
                      AnswerGrid(
                        children: [
                          for (final option in q.options)
                            AnswerTile(
                              label: option.label,
                              chosen: chosen == option,
                              onTap: _saving
                                  ? null
                                  : () => _choose(q, option, step),
                            ),
                        ],
                      ),
                      if (chosen != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          chosen.effect,
                          style: HgText.body(size: 14, color: HgColors.brown),
                        ),
                      ],
                    ],
                  )
                : QuestionPage(
                    key: const ValueKey('policy-notes'),
                    step: step,
                    of: pages,
                    question: 'Anything else, in your own words?',
                    hint:
                        'Anything the questions missed, said as you would to '
                        'a person. Or leave it empty.',
                    children: [
                      _NotesField(
                        controller: _notes,
                        onChanged: () => setState(() {}),
                      ),
                    ],
                  ),
          ),
          QuestionBottomBar(
            error: _error,
            showBack: step > 0,
            onBack: _saving ? null : () => _go(step - 1),
            // An answered page has already turned by itself; Next is for the
            // parent who came Back to check one and is happy with it.
            label: last
                ? 'Save and go on'
                : chosen == null
                ? 'Skip this one'
                : 'Next',
            busy: _saving,
            onNext: last
                // Nothing answered is still an answer, so the last page goes
                // on either way; it only saves when there is something to.
                ? (_dirty ? _save : () => Navigator.of(context).pop(true))
                : () => _go(step + 1),
            footnote: "All of this can be changed later from $name's page.",
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.kid.nickname;
    return ParentScaffold(
      title: widget.setup
          ? 'What $name may watch'
          : 'What your household wants',
      actions: [
        if (widget.setup)
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Skip for now',
              style: HgText.body(size: 15, color: HgColors.brown),
            ),
          ),
      ],
      subtitle: name.toUpperCase(),
      body: FutureBuilder<_Loaded>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return LoadError(snap.error!, onRetry: _reload);
          final loaded = snap.data;
          if (loaded == null) {
            return const Center(
              child: CircularProgressIndicator(color: HgColors.mango),
            );
          }
          // Anything answered that is no longer proposed still gets a card:
          // a parent must be able to find and change what they told us.
          final ids = {for (final q in loaded.questions.questions) q.id};
          final extras = [
            for (final a in loaded.policy.answers)
              if (!ids.contains(a.id))
                PolicyQuestion(id: a.id, question: a.question),
          ];
          if (widget.setup) {
            return _questionnaire([...loaded.questions.questions, ...extras]);
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              _Intro(
                name: name,
                updatedAt: loaded.policy.updatedAt,
                basedOn: loaded.questions.basedOn,
              ),
              const SizedBox(height: 12),
              for (final q in [...loaded.questions.questions, ...extras]) ...[
                _QuestionCard(
                  question: q,
                  chosen: _choices[q.id],
                  answer: _policy?.answerFor(q.id),
                  onChoose: (c) => setState(() {
                    // Tapping the choice again clears it: a parent who
                    // answered by accident can get back to unanswered, which
                    // is a different thing from answering "fine".
                    if (_choices[q.id] == c) {
                      _choices.remove(q.id);
                    } else {
                      _choices[q.id] = c;
                    }
                  }),
                ),
                const SizedBox(height: 12),
              ],
              _NotesCard(controller: _notes, onChanged: () => setState(() {})),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: HgText.body(size: 14, color: HgColors.coral),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _dirty && !_saving ? _save : null,
                  style: FilledButton.styleFrom(
                    disabledBackgroundColor: HgColors.line,
                    disabledForegroundColor: HgColors.brown,
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: HgColors.white,
                          ),
                        )
                      : Text(
                          _dirty
                              ? (widget.setup
                                    ? 'Save and pick channels'
                                    : 'Save these answers')
                              : 'Saved',
                          style: HgText.body(
                            size: 16,
                            color: _dirty ? HgColors.white : HgColors.brown,
                          ),
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro({
    required this.name,
    required this.updatedAt,
    required this.basedOn,
  });

  final String name;
  final String updatedAt;

  /// The channels the questions were actually drawn from. Empty means there
  /// were none to draw on.
  final List<String> basedOn;

  @override
  Widget build(BuildContext context) {
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Gilli screens every video before $name sees it',
            style: HgText.display(size: 22, color: HgColors.ink),
          ),
          const SizedBox(height: 6),
          Text(
            // Two short sentences. It was a heading and two paragraphs, read by
            // nobody on their way to the first question. What survives is where
            // the questions came from — claiming they came from $name's
            // channels when none did is a small lie every "why" below would
            // contradict — and that skipping is allowed.
            '${basedOn.isEmpty ? 'These are the questions every family is '
                      'asked.' : 'Some come from the channels $name is '
                      'already subscribed to.'} '
            'Answer the ones you care about and skip the rest.',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
          if (updatedAt.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Last saved ${_day(updatedAt)}',
              style: HgText.body(size: 13, color: HgColors.muted),
            ),
          ],
        ],
      ),
    );
  }

  /// "2026-09-06T10:11:12Z" → "2026-09-06". A date is all a parent needs, and
  /// an unparseable one is shown as it came rather than dropped.
  static String _day(String iso) =>
      iso.length >= 10 ? iso.substring(0, 10) : iso;
}

/// One question, the reason it was asked, and the three answers.
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.chosen,
    required this.answer,
    required this.onChoose,
  });

  final PolicyQuestion question;
  final PolicyChoice? chosen;

  /// The saved answer behind this question, when there is one. Only used for
  /// the weight: how much this answer has actually moved the screening.
  final PolicyAnswer? answer;
  final ValueChanged<PolicyChoice> onChoose;

  @override
  Widget build(BuildContext context) {
    final weight = chosen == answer?.choice ? answer?.weightLabel : null;
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            question.question,
            style: HgText.display(size: 20, color: HgColors.ink),
          ),
          const SizedBox(height: 4),
          Text(
            // Always shown. A question a parent cannot trace back to their own
            // child's channels is a question from nowhere.
            question.why.isNotEmpty
                ? question.why
                : 'Gilli did not say which channels prompted this one.',
            style: HgText.body(size: 13, color: HgColors.muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in question.options)
                _ChoiceButton(
                  choice: option,
                  selected: chosen == option,
                  onTap: () => onChoose(option),
                ),
            ],
          ),
          if (chosen != null) ...[
            const SizedBox(height: 10),
            Text(
              chosen!.effect,
              style: HgText.body(size: 13, color: HgColors.brown),
            ),
          ],
          if (weight != null) ...[
            const SizedBox(height: 4),
            Text(weight, style: HgText.body(size: 13, color: HgColors.muted)),
          ],
        ],
      ),
    );
  }
}

class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  final PolicyChoice choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? HgColors.mango : HgColors.cream,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? HgColors.mango : HgColors.line,
            width: 2,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Text(
              choice.label,
              style: HgText.body(
                size: 15,
                color: selected ? HgColors.white : HgColors.brown,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The parent's own words. Free text, and allowed to stay empty.
class _NotesCard extends StatelessWidget {
  const _NotesCard({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Anything else in your own words',
            style: HgText.display(size: 20, color: HgColors.ink),
          ),
          const SizedBox(height: 6),
          Text(
            'Anything the questions missed. Say it as you would to a person.',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
          const SizedBox(height: 12),
          _NotesField(controller: controller, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// The box itself, on its own so the setup questionnaire can give it a page.
class _NotesField extends StatelessWidget {
  const _NotesField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: (_) => onChanged(),
      maxLines: null,
      minLines: 3,
      textCapitalization: TextCapitalization.sentences,
      style: HgText.body(size: 15, color: HgColors.ink),
      decoration: InputDecoration(
        hintText:
            'We keep Fridays for family viewing. Nothing about '
            'weight or diets, please.',
        hintStyle: HgText.body(size: 15, color: HgColors.muted),
        filled: true,
        fillColor: HgColors.white,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: HgColors.line, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: HgColors.mango, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
    );
  }
}
