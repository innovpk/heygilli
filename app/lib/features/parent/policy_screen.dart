import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

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
                            color: _dirty ? HgColors.ink : HgColors.brown,
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
            // Which sentence is true depends on whether there was anything to
            // read. Claiming these came from $name's channels when they did
            // not is a small lie, and every 'why' below would contradict it.
            basedOn.isEmpty
                ? 'Without your answers it screens on age alone, which is '
                      "somebody else's taste. $name has no channels yet, so "
                      'these are the questions every family is asked.'
                : 'Without your answers it screens on age alone, which is '
                      'somebody else\'s taste. These questions come from the '
                      'channels $name is already subscribed to.',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
          const SizedBox(height: 10),
          Text(
            // Two things a parent would otherwise have to guess at, said
            // where they are about to start tapping.
            'Answer the ones you have a view on and leave the rest. A question '
            'you skip counts for nothing. Nothing here is hidden from you: the '
            'strongest answer sends a video to your inbox to decide.',
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
          const SizedBox(height: 8),
          Text('WHY YOU ARE BEING ASKED', style: HgText.label()),
          const SizedBox(height: 4),
          Text(
            // Always shown. A question a parent cannot trace back to their own
            // child's channels is a question from nowhere.
            question.why.isNotEmpty
                ? question.why
                : 'Gilli did not say which channels prompted this one.',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
          const SizedBox(height: 14),
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
                color: selected ? HgColors.ink : HgColors.brown,
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
            'Whatever the questions above did not cover. Gilli reads this when '
            'it screens; it is not a filter list, so say it the way you would '
            'say it to a person.',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
          const SizedBox(height: 12),
          TextField(
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
              fillColor: HgColors.cream,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
