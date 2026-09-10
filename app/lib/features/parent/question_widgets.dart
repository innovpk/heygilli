import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/hg_cta.dart';
import '../../core/theme.dart';

/// The pieces of a one-question-at-a-time page, shared by the setup steps
/// that ask a parent things: what a child may watch, and what they like.
///
/// Both used to be one long page of cards or chips, and a parent reading it
/// could not tell where one decision stopped and the next began.

/// A question page: where you are, what is asked, why, and the answers.
class QuestionPage extends StatelessWidget {
  const QuestionPage({
    super.key,
    required this.step,
    required this.of,
    required this.question,
    required this.hint,
    required this.children,
  });

  final int step;
  final int of;
  final String question;
  final String hint;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          QuestionProgress(step: step, of: of),
          const SizedBox(height: 14),
          Text(question, style: HgText.display(size: 30, color: HgColors.ink)),
          if (hint.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(hint, style: HgText.body(size: 15, color: HgColors.brown)),
          ],
          const SizedBox(height: 18),
          ...children,
        ],
      ),
    ),
  );
}

/// Answers as tiles: one to a row on a phone, two on anything wider. Two to a
/// row on a phone left the longest labels about fifty points, and they broke
/// mid-word.
class AnswerGrid extends StatelessWidget {
  const AnswerGrid({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final columns = box.maxWidth >= 640 ? 2 : 1;
      const gap = 12.0;
      final width = (box.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final c in children) SizedBox(width: width, child: c)],
      );
    },
  );
}

/// "Question 1 of 2", and a bar for it.
class QuestionProgress extends StatelessWidget {
  const QuestionProgress({super.key, required this.step, required this.of});
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

/// A big answer: a picture if there is one, the words, and a tick once it is
/// chosen.
class AnswerTile extends StatelessWidget {
  const AnswerTile({
    super.key,
    required this.label,
    required this.chosen,
    required this.onTap,
    this.icon,
  });

  final String label;

  /// The name of an icon under assets/icons, without the extension.
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
          constraints: const BoxConstraints(minHeight: 64),
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
                    size: 16,
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
class QuestionBottomBar extends StatelessWidget {
  const QuestionBottomBar({
    super.key,
    required this.error,
    required this.showBack,
    required this.onBack,
    required this.label,
    required this.busy,
    required this.onNext,
    this.footnote,
  });

  final String? error;
  final bool showBack;
  final VoidCallback? onBack;
  final String label;
  final bool busy;
  final VoidCallback onNext;
  final String? footnote;

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
                    // Never disabled: "I don't know yet" is a real answer, and
                    // a dead button would say otherwise. Its own width, but no
                    // more than what Back leaves, so a long label on a small
                    // phone shortens instead of pushing off the edge.
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: HgCta(
                          label: label,
                          busy: busy,
                          onPressed: onNext,
                        ),
                      ),
                    ),
                  ],
                ),
                if (footnote != null)
                  Text(
                    footnote!,
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
