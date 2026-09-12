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

  /// What this child already has. A household that arrived here with nineteen
  /// channels would otherwise be offered ones it approved months ago, with
  /// nothing to say so — the parent ticks it, nothing changes, and the screen
  /// looks broken. Adding again is harmless on the server; being told is the
  /// point.
  Set<String> _already = const {};

  late Future<StarterChannels> _suggestions = _load();
  bool _adding = false;
  String? _error;

  final _query = TextEditingController();

  /// What a search came back with, or null when the parent has not searched.
  /// Empty is a real answer — "nothing on YouTube matched" — and reads
  /// differently from "you have not looked yet".
  List<StarterChannel>? _results;
  bool _searching = false;
  String? _searchError;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Search YouTube for a channel.
  ///
  /// The one place HeyGilli asks YouTube a question. It costs a shared daily
  /// allowance, so it runs when the parent asks and never as they type.
  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final found = await context.read<AppState>().gateway.searchChannels(q);
      if (mounted) setState(() => _results = found);
    } catch (e) {
      // A search that cannot run at all is not an empty result: a parent
      // retyping their query would never fix a daily limit.
      if (mounted) setState(() => _searchError = '$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<StarterChannels> _load() async {
    final gateway = context.read<AppState>().gateway;
    final have = await gateway.channels(widget.kid.id);
    if (mounted) {
      _already = {
        for (final c in have)
          if (c.approved) c.id,
      };
    }
    return gateway.starterChannels(
      band: widget.kid.band.wire,
      topics: _topics.toList(),
    );
  }

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
    final picked = channels
        .where((c) => _chosen.contains(c.channelId))
        .toList();
    if (picked.isEmpty) return;
    setState(() {
      _adding = true;
      _error = null;
    });
    final state = context.read<AppState>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // One call rather than one per channel: it carries the topics the
      // parent picked, which the screening needs and which a per-channel add
      // has nowhere to put, and it starts the Curator once instead of once
      // per channel over a gateway that may be asleep.
      await state.gateway.importChannels(widget.kid.id, [
        for (final c in picked) c.channelId,
      ], topics: _topics.toList());
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
            Text('SEARCH YOUTUBE', style: HgText.label()),
            const SizedBox(height: 8),
            Row(
              spacing: 10,
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    style: HgText.body(size: 15, color: HgColors.ink),
                    decoration: const InputDecoration(
                      hintText: 'A channel your child already likes',
                    ),
                  ),
                ),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: _searching ? null : _search,
                    style: FilledButton.styleFrom(
                      disabledBackgroundColor: HgColors.line,
                      disabledForegroundColor: HgColors.brown,
                    ),
                    child: Text(
                      _searching ? '…' : 'Search',
                      style: HgText.body(
                        size: 16,
                        color: _searching ? HgColors.brown : HgColors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_searchError != null) ...[
              const SizedBox(height: 8),
              Text(
                'Could not search: $_searchError',
                style: HgText.body(size: 13, color: HgColors.coral),
              ),
            ],
            if (_results != null) ...[
              const SizedBox(height: 12),
              if (_results!.isEmpty)
                Text(
                  'Nothing on YouTube matched that.',
                  style: HgText.body(size: 14, color: HgColors.brown),
                )
              else
                for (final c in _results!) _channelTile(c),
              const SizedBox(height: 6),
              Text(
                'Adding one screens its videos the same way as any other '
                'channel — nothing reaches ${widget.kid.nickname} unread.',
                style: HgText.body(size: 13, color: HgColors.muted),
              ),
            ],
            const SizedBox(height: 22),
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
                    checkmarkColor: HgColors.white,
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
                      // Only what they do not already have: "select all"
                      // must not mean "tick the nineteen you approved
                      // months ago".
                      final all = data.channels
                          .map((c) => c.channelId)
                          .where((id) => !_already.contains(id))
                          .toSet();
                      // Toggles: a parent who ticked everything by accident
                      // needs one tap back, not twenty.
                      if (all.isEmpty || _chosen.containsAll(all)) {
                        _chosen.clear();
                      } else {
                        _chosen
                          ..clear()
                          ..addAll(all);
                      }
                    }),
                    child: Text(
                      _chosen.isNotEmpty &&
                              _chosen.containsAll(
                                data.channels
                                    .map((c) => c.channelId)
                                    .where((id) => !_already.contains(id))
                                    .toSet(),
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
              for (final c in data.channels) _channelTile(c),
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
                    : () => _add([...data.channels, ...?_results]),
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

  /// One channel, offered the same way whether it came from the suggested
  /// list or from a search: a parent should not have to learn two shapes for
  /// the same decision.
  Widget _channelTile(StarterChannel c) {
    final have = _already.contains(c.channelId);
    return CheckboxListTile(
      // Already theirs: shown ticked and left alone, so the list reads as
      // "here is everything, and here is what you have" rather than hiding
      // channels they would recognise.
      value: have || _chosen.contains(c.channelId),
      onChanged: _adding || have
          ? null
          : (on) => setState(() {
              if (on == true) {
                _chosen.add(c.channelId);
              } else {
                _chosen.remove(c.channelId);
              }
            }),
      activeColor: HgColors.mango,
      checkColor: HgColors.white,
      contentPadding: EdgeInsets.zero,
      title: Text(c.title, style: HgText.body(size: 16, color: HgColors.ink)),
      subtitle: Text(
        have ? 'Already added for ${widget.kid.nickname}' : c.blurb,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: HgText.body(
          size: 13.5,
          color: have ? HgColors.green : HgColors.muted,
        ),
      ),
    );
  }
}
