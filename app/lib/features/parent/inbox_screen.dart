import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

/// The Curator's yes/no questions for the parent (GET /parent/inbox).
/// Each card says why the agent was unsure; the parent approves or hides.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  late Future<List<ParentPrompt>> _inbox = _load();
  final _busy = <String>{};

  /// Whose questions are being shown, or null for everyone's.
  ///
  /// A household with two children had both their questions in one list, and
  /// a parent deciding about one child had to read past the other's. Deciding
  /// is per child — the same video can be right for one and not the other —
  /// so the list is too.
  String? _onlyKid;

  void _reload() => setState(() {
    _inbox = _load();
  });

  Future<List<ParentPrompt>> _load() async {
    final list = await context.read<AppState>().gateway.inbox();
    // The list has just been fetched, so the rail's count can be corrected for
    // free rather than by asking again.
    if (mounted) context.read<AppState>().setWaiting(list.length);
    return list;
  }

  Future<void> _decide(ParentPrompt p, String decision) async {
    setState(() => _busy.add(p.id));
    try {
      await context.read<AppState>().gateway.decide(p.id, decision);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            decision == 'approve'
                ? '"${p.subject}" approved.'
                : '"${p.subject}" hidden.',
          ),
        ),
      );
      setState(() {
        _inbox = _load();
      });
    } finally {
      if (mounted) setState(() => _busy.remove(p.id));
    }
  }

  /// Approve everything waiting from one channel.
  ///
  /// A household that has just added channels arrives with a queue in the
  /// hundreds, and most of a channel's queue gets the same answer — that is
  /// what grouping by channel showed in the first place. Tapping Approve two
  /// hundred times is not a decision, it is a chore that ends in the parent
  /// approving without reading.
  ///
  /// Confirmed first, because it is bulk and it changes what a child is shown.
  /// The dialog names the channel and the count, so "approve all" cannot mean
  /// something bigger than the parent thought.
  Future<void> _approveGroup(String channel, List<ParentPrompt> prompts) async {
    final decidable = [
      for (final p in prompts)
        if (p.isDecidable) p,
    ];
    if (decidable.isEmpty) return;

    final where = channel.isEmpty ? 'these channels' : channel;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: HgColors.white,
        title: Text(
          'Approve all ${decidable.length}?',
          style: HgText.display(size: 22, color: HgColors.ink),
        ),
        content: Text(
          'Every video waiting from $where goes to the child it was screened '
          'for. You can still take any of them away later from that '
          "child's Channels.",
          style: HgText.body(size: 15, color: HgColors.brown),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Approve ${decidable.length}'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;

    setState(() => _busy.addAll(decidable.map((p) => p.id)));
    final messenger = ScaffoldMessenger.of(context);
    final gateway = context.read<AppState>().gateway;
    var done = 0;
    String? failed;
    try {
      for (final p in decidable) {
        try {
          await gateway.decide(p.id, 'approve');
          done++;
        } catch (e) {
          // One that will not go through must not swallow the ones that did:
          // the parent is told how far it got rather than being left unsure
          // whether any of it happened.
          failed = '$e';
          break;
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy.removeAll(decidable.map((p) => p.id));
          _inbox = _load();
        });
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              failed == null
                  ? '$done approved from $where.'
                  : '$done of ${decidable.length} approved, then it stopped: $failed',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final kids = context.select<AppState, List<Kid>>((s) => s.kids);
    return FutureBuilder<List<ParentPrompt>>(
      future: _inbox,
      builder: (context, snap) {
        if (snap.hasError) {
          return LoadError(snap.error!, onRetry: _reload);
        }
        final list = snap.data;
        if (list == null) {
          return const Center(
            child: CircularProgressIndicator(color: HgColors.mango),
          );
        }
        if (list.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 12,
                children: [
                  const GilliMini(size: 96),
                  Text(
                    'All caught up. Nothing is waiting.',
                    textAlign: TextAlign.center,
                    style: HgText.display(size: 24, color: HgColors.ink),
                  ),
                  Text(
                    'When the Curator is unsure about a video it asks you '
                    'here instead of guessing.',
                    textAlign: TextAlign.center,
                    style: HgText.body(color: HgColors.brown),
                  ),
                ],
              ),
            ),
          );
        }
        // Grouped by channel, in the order the channels first appear. A
        // parent working through this is mostly deciding about a channel
        // rather than about videos one at a time: four borderline uploads in
        // a row are usually one channel, and the answer to all four is the
        // same answer. Ungrouped, they were four unrelated-looking cards.
        // Whose questions these are. Only worth the space when the household
        // has more than one child; with one, every card is theirs already.
        final counts = <String, int>{};
        for (final p in list) {
          counts[p.kidId] = (counts[p.kidId] ?? 0) + 1;
        }
        final tabbed = kids.length > 1;
        final shown = tabbed && _onlyKid != null
            ? [
                for (final p in list)
                  if (p.kidId == _onlyKid) p,
              ]
            : list;

        final groups = <String, List<ParentPrompt>>{};
        for (final p in shown) {
          groups.putIfAbsent(p.channelTitle, () => []).add(p);
        }
        final rows = <Widget>[];
        for (final entry in groups.entries) {
          rows.add(
            Padding(
              padding: EdgeInsets.only(top: rows.isEmpty ? 0 : 22, bottom: 8),
              child: Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: Text(
                      entry.key.isEmpty ? 'From your channels' : entry.key,
                      style: HgText.label(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    entry.value.length == 1
                        ? '1 waiting'
                        : '${entry.value.length} waiting',
                    style: HgText.body(size: 13, color: HgColors.muted),
                  ),
                  // Only when there is more than one: "approve all 1" is the
                  // card's own button with extra words and an extra tap.
                  if (entry.value.where((p) => p.isDecidable).length > 1)
                    TextButton.icon(
                      onPressed: _busy.isNotEmpty
                          ? null
                          : () => _approveGroup(entry.key, entry.value),
                      icon: const Icon(Icons.done_all_rounded, size: 18),
                      label: const Text('Approve all'),
                      style: TextButton.styleFrom(
                        foregroundColor: HgColors.mangoDeep,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: HgText.body(size: 14),
                      ),
                    ),
                ],
              ),
            ),
          );
          for (final p in entry.value) {
            final kid = kids.where((k) => k.id == p.kidId).firstOrNull;
            rows.add(
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _PromptCard(
                  prompt: p,
                  // Only when it is not already the tab they are standing in.
                  kidName: tabbed && _onlyKid == null
                      ? (kid?.nickname ?? 'a kid')
                      : '',
                  busy: _busy.contains(p.id),
                  onApprove: () => _decide(p, 'approve'),
                  onHide: () => _decide(p, 'hide'),
                ),
              ),
            );
          }
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            if (tabbed) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  spacing: 8,
                  children: [
                    _KidTab(
                      label: 'Everyone',
                      count: list.length,
                      selected: _onlyKid == null,
                      onTap: () => setState(() => _onlyKid = null),
                    ),
                    for (final kid in kids)
                      if ((counts[kid.id] ?? 0) > 0)
                        _KidTab(
                          label: kid.nickname,
                          count: counts[kid.id] ?? 0,
                          selected: _onlyKid == kid.id,
                          onTap: () => setState(() => _onlyKid = kid.id),
                        ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],
            ...rows,
          ],
        );
      },
    );
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.prompt,
    required this.kidName,
    required this.busy,
    required this.onApprove,
    required this.onHide,
  });

  final ParentPrompt prompt;

  /// Empty when the list is already filtered to one child: repeating their
  /// name on every card is a line of text per card that says nothing new.
  final String kidName;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final v = prompt.video;
    // One row rather than four stacked blocks. A parent with a dozen of these
    // was scrolling past a heading, a thumbnail, a boxed sentence and a pair
    // of full-width buttons for every single one — most of a screen each, to
    // answer a yes/no question. Everything that says *what* this is sits on
    // the left, the two answers on the right, and the card ends.
    return PCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          // A channel drift raises an inbox entry too, and a drift has no
          // video in it (PROTOCOL "Channel drift"). An entry with nothing to
          // show a thumbnail of still has to reach the parent.
          if (v != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 92,
                height: 52,
                child: Image.network(
                  v.thumb,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const ColoredBox(color: HgColors.line),
                ),
              ),
            )
          else
            Icon(
              prompt.drift != null
                  ? Icons.change_circle_outlined
                  : Icons.tv_rounded,
              size: 28,
              color: HgColors.brown,
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 3,
              children: [
                Text(
                  prompt.subject,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HgText.body(
                    size: 15,
                    color: HgColors.ink,
                    weight: FontWeight.w700,
                  ),
                ),
                // "For you" leads the meta line rather than sitting beside
                // the title: the card is deliberately one compact row, and a
                // pill up there took width the title did not have. Same words
                // as the stamps on the landing page, so the same idea reads
                // the same wherever a parent meets it.
                Text.rich(
                  TextSpan(
                    children: [
                      if (prompt.isDecidable)
                        TextSpan(
                          text: 'For you',
                          style: HgText.body(
                            size: 12,
                            color: HgColors.mango,
                            weight: FontWeight.w800,
                          ),
                        ),
                      TextSpan(
                        text: [
                          if (kidName.isNotEmpty) 'For $kidName',
                          if (v != null) '${(v.durationS / 60).round()} min',
                        ].map((part) => '  \u00b7  $part').join(),
                        style: HgText.body(size: 12, color: HgColors.muted),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  prompt.drift != null
                      ? (prompt.drift!.whatChanged.isNotEmpty
                            ? prompt.drift!.whatChanged
                            : prompt.reason)
                      : prompt.reason,
                  // Two lines is enough to say why and short enough that a
                  // dozen of these still fit on a screen. The whole reason is
                  // one sentence by design (CuratorDecision), so this rarely
                  // cuts anything off.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HgText.body(size: 13, color: HgColors.brown),
                ),
              ],
            ),
          ),
          if (prompt.isDecidable)
            Column(
              spacing: 6,
              children: [
                _Answer(
                  label: 'Show it',
                  icon: Icons.check_rounded,
                  filled: true,
                  onPressed: busy ? null : onApprove,
                ),
                _Answer(
                  label: 'Not this one',
                  icon: Icons.close_rounded,
                  filled: false,
                  onPressed: busy ? null : onHide,
                ),
              ],
            )
          else
            SizedBox(
              width: 120,
              child: Text(
                'Nothing has been done — open Channels to decide.',
                style: HgText.body(size: 12, color: HgColors.brown),
              ),
            ),
        ],
      ),
    );
  }
}

/// One of the two answers. Icon and word together: the word alone made the
/// buttons as wide as the card, and the icon alone would leave a parent
/// guessing which cross means what.
class _Answer extends StatelessWidget {
  const _Answer({
    required this.label,
    required this.icon,
    required this.filled,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool filled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 116,
    height: 38,
    child: filled
        ? FilledButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            label: Text(label, style: HgText.body(size: 14)),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            label: Text(label, style: HgText.body(size: 14)),
            style: OutlinedButton.styleFrom(
              foregroundColor: HgColors.coral,
              side: const BorderSide(color: HgColors.coral, width: 1.5),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
  );
}

/// Whose questions to show. A count on each, so a parent can see at a glance
/// which child has a queue building up.
class _KidTab extends StatelessWidget {
  const _KidTab({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? HgColors.mango : HgColors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? HgColors.mango : HgColors.line),
        ),
        child: Text(
          '$label  $count',
          style: HgText.body(
            size: 14,
            color: HgColors.ink,
            weight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    ),
  );
}
