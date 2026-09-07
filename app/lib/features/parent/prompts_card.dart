import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

/// What Gilli is allowed to ask this child.
///
/// The questions are written, not invented per video, and graded by band: a
/// four-year-old is asked to name a colour or make a sound, an eleven-year-old
/// what they would tell a friend who missed it. Change the child's age and
/// this list changes with it.
///
/// Everything is on until the parent turns it off. A household that never
/// opens this screen still has a working app, so this is a place to remove
/// things rather than a form to fill in — which is why saving sends the ids
/// that are OFF and why turning every one off is a real setting: the video
/// plays and Gilli asks nothing.
class PromptsCard extends StatefulWidget {
  const PromptsCard({super.key, required this.kid});

  final Kid kid;

  @override
  State<PromptsCard> createState() => _PromptsCardState();
}

class _PromptsCardState extends State<PromptsCard> {
  late Future<List<KidPrompt>> _prompts = _load();
  List<KidPrompt>? _live;
  bool _saving = false;
  String? _error;
  bool _saved = false;

  Future<List<KidPrompt>> _load() =>
      context.read<AppState>().gateway.prompts(widget.kid.id);

  @override
  void didUpdateWidget(PromptsCard old) {
    super.didUpdateWidget(old);
    // The band decides the list, so a corrected age has to reload it rather
    // than leave the parent ticking questions their child is no longer asked.
    if (old.kid.band != widget.kid.band) {
      setState(() {
        _live = null;
        _prompts = _load();
      });
    }
  }

  Future<void> _toggle(KidPrompt prompt, bool on) async {
    final list = [
      for (final p in _live ?? const <KidPrompt>[])
        p.id == prompt.id ? p.copyWith(enabled: on) : p,
    ];
    setState(() {
      _live = list;
      _saving = true;
      _saved = false;
      _error = null;
    });
    try {
      final saved = await context.read<AppState>().gateway.savePrompts(
        widget.kid.id,
        [for (final p in list) if (!p.enabled) p.id],
      );
      if (!mounted) return;
      setState(() {
        _live = saved;
        _saved = true;
      });
    } catch (e) {
      if (!mounted) return;
      // Put the switch back: a toggle that looks saved and is not is worse
      // than one that refuses.
      setState(() {
        _live = [
          for (final p in list)
            p.id == prompt.id ? p.copyWith(enabled: !on) : p,
        ];
        _error = 'Could not save: $e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'What Gilli asks ${widget.kid.nickname}',
          style: HgText.display(size: 20, color: HgColors.ink),
        ),
        const SizedBox(height: 6),
        Text(
          'These are written for ages ${widget.kid.band.label}, and Gilli picks '
          'one at the end of a video. Turn off any you would rather '
          '${widget.kid.nickname} was not asked.',
          style: HgText.body(size: 14, color: HgColors.brown),
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<KidPrompt>>(
          future: _prompts,
          builder: (context, snap) {
            if (snap.hasError) {
              return LoadError(
                snap.error!,
                onRetry: () => setState(() => _prompts = _load()),
              );
            }
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final list = _live ??= snap.data!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final p in list)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: p.enabled,
                    onChanged: _saving ? null : (v) => _toggle(p, v),
                    activeThumbColor: HgColors.mango,
                    title: Text(
                      p.label,
                      style: HgText.body(size: 15, color: HgColors.ink),
                    ),
                    subtitle: Text(
                      _how(p.input),
                      style: HgText.body(size: 13, color: HgColors.muted),
                    ),
                  ),
                if (list.every((p) => !p.enabled)) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Nothing is on, so videos play through and Gilli asks '
                    '${widget.kid.nickname} nothing. That is a fine way to '
                    'use it.',
                    style: HgText.body(size: 13, color: HgColors.brown),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: HgText.body(color: HgColors.coral)),
                ] else if (_saved) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Saved.',
                    style: HgText.body(size: 13, color: HgColors.muted),
                  ),
                ],
              ],
            );
          },
        ),
      ],
    ),
  );

  /// What the child actually does to answer. "Say a word" and "do a thing" are
  /// different asks of a four-year-old, and a parent deciding should see which.
  static String _how(String input) => switch (input) {
    'copy' => 'They do it, no talking needed',
    'pick' => 'They tap a picture',
    _ => 'They answer out loud',
  };
}
