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

  void _reload() => setState(() {
    _inbox = _load();
  });

  Future<List<ParentPrompt>> _load() =>
      context.read<AppState>().gateway.inbox();

  Future<void> _decide(ParentPrompt p, String decision) async {
    setState(() => _busy.add(p.id));
    try {
      await context.read<AppState>().gateway.decide(p.id, decision);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            decision == 'approve'
                ? '"${p.video.title}" approved.'
                : '"${p.video.title}" hidden.',
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
                    'Nothing waiting',
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
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          itemCount: list.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, i) {
            final p = list[i];
            final kid = kids.where((k) => k.id == p.kidId).firstOrNull;
            return _PromptCard(
              prompt: p,
              kidName: kid?.nickname ?? 'a kid',
              busy: _busy.contains(p.id),
              onApprove: () => _decide(p, 'approve'),
              onHide: () => _decide(p, 'hide'),
            );
          },
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
  final String kidName;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final v = prompt.video;
    return PCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text('FOR $kidName'.toUpperCase(), style: HgText.label()),
          Row(
            spacing: 12,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 112,
                  height: 63,
                  child: Image.network(
                    v.thumb,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const ColoredBox(color: HgColors.line),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(
                      v.title,
                      style: HgText.body(size: 16, color: HgColors.ink),
                    ),
                    Text(
                      '${(v.durationS / 60).round()} min',
                      style: HgText.body(size: 13, color: HgColors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: HgColors.cream,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              'Curator: ${prompt.reason}',
              style: HgText.body(
                size: 14,
                color: HgColors.brown,
                weight: FontWeight.w600,
              ),
            ),
          ),
          Row(
            spacing: 10,
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: busy ? null : onApprove,
                    child: const Text('Approve'),
                  ),
                ),
              ),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    onPressed: busy ? null : onHide,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: HgColors.coral,
                      side: const BorderSide(color: HgColors.coral, width: 2),
                      shape: const StadiumBorder(),
                      textStyle: HgText.body(size: 16),
                    ),
                    child: const Text('Hide'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
