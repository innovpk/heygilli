import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

/// Somewhere to start, for a household that has no channels yet.
///
/// The alternative was asking a parent who has just arrived to request a
/// Takeout export from Google and wait for it to arrive by email, or to hand
/// over an account before they know whether they want the thing. Both are a
/// strange first request, and a parent who did neither had an empty app.
///
/// The parent says what their child likes, sees the channels that match, and
/// approves them together. Nothing is preselected and nothing is approved by
/// arriving here: being suggested buys a channel nothing, and the Curator
/// still reads every upload against this household's own answers afterwards.
class StarterChannelsScreen extends StatefulWidget {
  const StarterChannelsScreen({super.key, required this.kid});

  final Kid kid;

  @override
  State<StarterChannelsScreen> createState() => _StarterChannelsScreenState();
}

class _StarterChannelsScreenState extends State<StarterChannelsScreen> {
  final _topics = <String>{};
  final _chosen = <String>{};
  late Future<StarterChannels> _suggestions = _load();
  bool _adding = false;
  String? _error;

  Future<StarterChannels> _load() => context
      .read<AppState>()
      .gateway
      .starterChannels(band: widget.kid.band.wire, topics: _topics.toList());

  void _toggleTopic(String id, bool on) {
    setState(() {
      if (on) {
        _topics.add(id);
      } else {
        _topics.remove(id);
      }
      // The list changes underneath, so a channel ticked and then filtered
      // away must not be added invisibly.
      _chosen.clear();
      _suggestions = _load();
    });
  }

  Future<void> _add(List<StarterChannel> channels) async {
    final picked = channels.where((c) => _chosen.contains(c.channelId)).toList();
    if (picked.isEmpty) return;
    setState(() {
      _adding = true;
      _error = null;
    });
    final state = context.read<AppState>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      for (final c in picked) {
        // The same call a pasted channel goes through, so screening starts on
        // its own exactly as it does for one added by hand.
        await state.gateway.addChannel(
          widget.kid.id,
          'https://www.youtube.com/channel/${c.channelId}',
        );
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            picked.length == 1
                ? 'Added ${picked.first.title}. Gilli is reading its videos now; '
                      'they appear as they pass.'
                : 'Added ${picked.length} channels. Gilli is reading their '
                      'videos now; they appear as they pass.',
          ),
        ),
      );
      navigator.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _adding = false;
          _error = 'Could not add: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ParentScaffold(
    title: 'Channels to start with',
    subtitle: 'For ${widget.kid.nickname}, age ${widget.kid.age}',
    body: FutureBuilder<StarterChannels>(
      future: _suggestions,
      builder: (context, snap) {
        if (snap.hasError) {
          return LoadError(
            snap.error!,
            onRetry: () => setState(() => _suggestions = _load()),
          );
        }
        if (!snap.hasData) {
          return const Center(
            child: CircularProgressIndicator(color: HgColors.mango),
          );
        }
        final data = snap.data!;
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            Text(
              'Pick what ${widget.kid.nickname} likes, then choose the channels '
              'you are happy for them to have. Gilli reads every new video from '
              'these against your answers before it reaches them.',
              style: HgText.body(size: 15, color: HgColors.brown),
            ),
            const SizedBox(height: 16),
            Text('WHAT THEY LIKE', style: HgText.label()),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in data.topics)
                  FilterChip(
                    label: Text(t.label),
                    selected: _topics.contains(t.id),
                    onSelected: (on) => _toggleTopic(t.id, on),
                    selectedColor: HgColors.mango,
                    checkmarkColor: HgColors.ink,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _topics.isEmpty
                  ? 'Nothing picked, so this is everything suited to their age.'
                  : 'Showing channels for what you picked.',
              style: HgText.body(size: 13, color: HgColors.muted),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(child: Text('CHANNELS', style: HgText.label())),
                if (data.channels.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() {
                      final all = data.channels.map((c) => c.channelId).toSet();
                      // Toggles: a parent who ticked everything by accident
                      // needs one tap back, not twenty.
                      if (_chosen.containsAll(all)) {
                        _chosen.clear();
                      } else {
                        _chosen.addAll(all);
                      }
                    }),
                    child: Text(
                      _chosen.containsAll(
                            data.channels.map((c) => c.channelId).toSet(),
                          )
                          ? 'Clear all'
                          : 'Select all',
                      style: HgText.body(size: 14, color: HgColors.mangoDeep),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (data.channels.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'Nothing here for that combination yet. Try fewer things, or '
                  'paste a channel yourself on the Channels tab.',
                  style: HgText.body(size: 14, color: HgColors.brown),
                ),
              )
            else
              for (final c in data.channels)
                CheckboxListTile(
                  value: _chosen.contains(c.channelId),
                  onChanged: _adding
                      ? null
                      : (on) => setState(() {
                          if (on == true) {
                            _chosen.add(c.channelId);
                          } else {
                            _chosen.remove(c.channelId);
                          }
                        }),
                  activeColor: HgColors.mango,
                  checkColor: HgColors.ink,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    c.title,
                    style: HgText.body(size: 16, color: HgColors.ink),
                  ),
                  subtitle: Text(
                    c.blurb,
                    style: HgText.body(size: 13.5, color: HgColors.muted),
                  ),
                ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: HgText.body(color: HgColors.coral)),
            ],
            const SizedBox(height: 18),
            SizedBox(
              height: 56,
              child: FilledButton(
                onPressed: _adding || _chosen.isEmpty
                    ? null
                    : () => _add(data.channels),
                child: Text(
                  _chosen.isEmpty
                      ? 'Choose at least one'
                      : _chosen.length == 1
                      ? 'Add 1 channel'
                      : 'Add ${_chosen.length} channels',
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'These are places to start, not recommendations. Whether any '
              'particular video suits ${widget.kid.nickname} is decided against '
              'your own answers, and you can drop a channel at any time.',
              style: HgText.body(size: 13, color: HgColors.muted),
            ),
          ],
        );
      },
    ),
  );
}
