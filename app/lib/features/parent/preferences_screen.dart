import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

/// What this child likes, and nothing else.
///
/// Setting a child up used to mean picking channels off a list. That is the
/// wrong question to put to a parent: they are being asked to vouch for a
/// channel's entire future output on the strength of a one-line blurb, before
/// they have seen a single thing it makes. And the blurbs could be wrong —
/// two of twenty-six pointed somewhere else entirely, which is how a
/// motivational-quotes channel came to be offered as science and a repost
/// account with a "horror video" on it came to be offered to four-year-olds.
///
/// So the channels are the server's problem now, and the parent is asked the
/// question they can actually answer. What comes back is videos, each with
/// Gilli's reading of it, which is a thing they can look at and judge.
class PreferencesScreen extends StatefulWidget {
  const PreferencesScreen({super.key, required this.kid});
  final Kid kid;

  @override
  State<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends State<PreferencesScreen> {
  final _picked = <String>{};
  late Future<StarterChannels> _data = context
      .read<AppState>()
      .gateway
      .starterChannels(band: widget.kid.band.wire);
  bool _busy = false;
  String? _error;

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

  @override
  Widget build(BuildContext context) {
    final name = widget.kid.nickname;
    return ParentScaffold(
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
          final topics = snap.data?.topics ?? const <StarterTopic>[];
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
            children: [
              Text(
                'Pick anything that sounds like $name. Gilli goes and finds '
                'videos, reads each one against the answers you just gave, and '
                'shows you what it made of them before $name sees anything.',
                style: HgText.body(size: 15, color: HgColors.brown),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final t in topics)
                    FilterChip(
                      label: Text(t.label),
                      selected: _picked.contains(t.id),
                      onSelected: _busy
                          ? null
                          : (on) => setState(
                              () => on ? _picked.add(t.id) : _picked.remove(t.id),
                            ),
                      selectedColor: HgColors.mango,
                      checkmarkColor: HgColors.ink,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                _picked.isEmpty
                    // Not punished with a blank screen: "I do not know yet" is
                    // the commonest answer during setup.
                    ? 'Nothing picked, so Gilli will look at everything suited '
                          'to their age.'
                    : 'Gilli will look for these.',
                style: HgText.body(size: 13, color: HgColors.muted),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: HgText.body(size: 14, color: HgColors.coral),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                'You can add a channel by name later, or drop any of them, from '
                "$name's page.",
                style: HgText.body(size: 13, color: HgColors.muted),
              ),
            ],
          );
        },
      ),
      floating: FloatingActionButton.extended(
        onPressed: _busy ? null : _go,
        backgroundColor: HgColors.mango,
        foregroundColor: HgColors.ink,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: HgColors.ink,
                ),
              )
            : const Icon(Icons.search_rounded),
        label: Text(
          _picked.isEmpty ? 'Find videos' : 'Find videos for this',
          style: HgText.body(color: HgColors.ink),
        ),
      ),
    );
  }
}
