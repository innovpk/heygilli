import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../main.dart';
import 'channel_reviews_screen.dart';
import 'digest_screen.dart';
import 'import_subscriptions_screen.dart';
import 'parent_widgets.dart';
import 'progress_screen.dart';
import 'takeout_import_screen.dart';
import 'time_limits_card.dart';

/// One kid: enter kid mode, open the digest or progress, manage channels.
class KidDetailScreen extends StatefulWidget {
  const KidDetailScreen({super.key, required this.kid});
  final Kid kid;

  @override
  State<KidDetailScreen> createState() => _KidDetailScreenState();
}

class _KidDetailScreenState extends State<KidDetailScreen> {
  /// How many channel tiles this page shows before handing over to the review
  /// screen.
  static const _previewCount = 8;

  /// Shared by the two import buttons so they read as one pair of options.
  static final _importButtonStyle = OutlinedButton.styleFrom(
    foregroundColor: HgColors.ink,
    backgroundColor: HgColors.white,
    side: const BorderSide(color: HgColors.line, width: 2),
    shape: const StadiumBorder(),
    textStyle: HgText.body(size: 16, color: HgColors.ink),
  );

  late Future<List<Channel>> _channels = _load();
  final _url = TextEditingController();
  bool _adding = false;
  String? _error;

  void _reload() => setState(() {
    _channels = _load();
  });

  Future<List<Channel>> _load() =>
      context.read<AppState>().gateway.channels(widget.kid.id);

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _addChannel() async {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      await context.read<AppState>().gateway.addChannel(widget.kid.id, url);
      _url.clear();
      setState(() {
        _channels = _load();
      });
    } catch (e) {
      setState(() {
        _error = 'Could not add: $e';
      });
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// The second way to add channels: pick from what the parent already
  /// follows on YouTube, instead of pasting one URL at a time.
  Future<void> _importFromYouTube() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ImportSubscriptionsScreen(kid: widget.kid),
      ),
    );
    if (added ?? false) _reload();
  }

  /// The third way, and the only one that reaches a child's own YouTube Kids
  /// profile: a Google Takeout export (PROTOCOL "Takeout import").
  Future<void> _importFromTakeout() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const TakeoutImportScreen()),
    );
    if (added ?? false) _reload();
  }

  /// What each approved channel actually publishes, so a pile of 153 imported
  /// subscriptions is something a parent can work through.
  Future<void> _openReviews() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ChannelReviewsScreen(kid: widget.kid)),
    );
    if (changed ?? false) _reload();
  }

  void _enterKidMode() {
    context.read<AppState>().enterKidMode(widget.kid);
    // Replace the whole stack: from here the only way back is the PIN gate.
    Navigator.of(context).pushNamedAndRemoveUntil(Routes.kid, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final kid = widget.kid;
    return ParentScaffold(
      title: kid.nickname,
      subtitle: 'Age ${kid.age}  |  band ${kid.band.label}',
      actions: [KidAvatar(kid: kid, size: 48)],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          SizedBox(
            height: 64,
            child: FilledButton.icon(
              onPressed: _enterKidMode,
              icon: const Icon(Icons.play_arrow_rounded, size: 30),
              label: Text(
                'Enter kid mode',
                style: HgText.display(size: 22, color: HgColors.ink),
              ),
            ),
          ),
          const SizedBox(height: 12),
          PCard(
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => DigestScreen(kid: kid))),
            child: Row(
              spacing: 14,
              children: [
                const Icon(Icons.auto_stories_rounded, color: HgColors.brown),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Today's digest",
                        style: HgText.display(size: 22, color: HgColors.ink),
                      ),
                      Text(
                        kid.band == AgeBand.b4to6
                            ? 'Words said, words heard, one thing to try'
                            : 'Understood, shaky, one question for dinner',
                        style: HgText.body(size: 14, color: HgColors.brown),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: HgColors.brown),
              ],
            ),
          ),
          const SizedBox(height: 12),
          PCard(
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => ProgressScreen(kid: kid))),
            child: Row(
              spacing: 14,
              children: [
                const Icon(Icons.insights_rounded, color: HgColors.brown),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Progress',
                        style: HgText.display(size: 22, color: HgColors.ink),
                      ),
                      Text(
                        kid.band == AgeBand.b4to6
                            ? 'Minutes, words coming back, what to try'
                            : 'Minutes, what stuck, what needs another look',
                        style: HgText.body(size: 14, color: HgColors.brown),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: HgColors.brown),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TimeLimitsCard(kid: kid),
          const SizedBox(height: 24),
          Text('CHANNELS', style: HgText.label()),
          const SizedBox(height: 8),
          Text(
            'Only videos from these channels ever reach ${kid.nickname}. '
            'A Google Takeout export is the only way to read a YouTube Kids '
            'profile, so start there. You can also paste a channel, @handle '
            'or video URL.',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
          const SizedBox(height: 12),
          // Takeout first: it is the only route to a YouTube Kids profile's
          // subscriptions. Importing the parent's own account only helps the
          // households where the kids watch on a shared login, so it sits
          // underneath as the secondary path.
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _importFromTakeout,
              icon: const Icon(Icons.folder_zip_outlined, size: 22),
              label: Text(
                "Import ${kid.nickname}'s YouTube Kids channels",
                style: HgText.body(size: 15, color: HgColors.ink),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 52,
            child: OutlinedButton.icon(
              onPressed: _importFromYouTube,
              icon: const Icon(Icons.subscriptions_outlined, size: 22),
              label: const Text('Import from my own account'),
              style: _importButtonStyle,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            spacing: 10,
            children: [
              Expanded(
                child: TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  style: HgText.body(size: 15, color: HgColors.ink),
                  decoration: const InputDecoration(
                    hintText: 'https://youtube.com/@SciShowKids',
                  ),
                  onSubmitted: (_) => _addChannel(),
                ),
              ),
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _adding ? null : _addChannel,
                  child: const Text('Add'),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: HgText.body(color: HgColors.coral)),
          ],
          const SizedBox(height: 14),
          FutureBuilder<List<Channel>>(
            future: _channels,
            builder: (context, snap) {
              if (snap.hasError) {
                return LoadError(snap.error!, onRetry: _reload);
              }
              final list = snap.data;
              if (list == null) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: CircularProgressIndicator(color: HgColors.mango),
                  ),
                );
              }
              if (list.isEmpty) {
                return Text(
                  'No channels yet.',
                  style: HgText.body(color: HgColors.muted),
                );
              }
              return Column(
                spacing: 10,
                children: [
                  // The way through a big imported pile. Shown with the count
                  // because 153 is the number that makes it worth opening.
                  PCard(
                    onTap: _openReviews,
                    child: Row(
                      spacing: 14,
                      children: [
                        const Icon(
                          Icons.fact_check_outlined,
                          color: HgColors.brown,
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'What these channels show',
                                style: HgText.display(
                                  size: 22,
                                  color: HgColors.ink,
                                ),
                              ),
                              Text(
                                'Review all ${list.length} and drop the ones '
                                'you do not want',
                                style: HgText.body(
                                  size: 14,
                                  color: HgColors.brown,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right_rounded,
                          color: HgColors.brown,
                        ),
                      ],
                    ),
                  ),
                  // Only a first handful here. A Takeout import can leave 153
                  // channels on a kid, and this page is a Column inside a
                  // ListView: every tile would be built at once. The review
                  // screen is the lazily built list.
                  for (final c in list.take(_previewCount))
                    _ChannelTile(channel: c),
                  if (list.length > _previewCount)
                    SizedBox(
                      height: 48,
                      child: TextButton(
                        onPressed: _openReviews,
                        style: TextButton.styleFrom(
                          foregroundColor: HgColors.brown,
                        ),
                        child: Text(
                          'and ${list.length - _previewCount} more',
                          style: HgText.body(size: 15, color: HgColors.brown),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.channel});
  final Channel channel;

  @override
  Widget build(BuildContext context) {
    return PCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        spacing: 12,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 72,
              height: 48,
              child: channel.thumbUrl.isEmpty
                  ? const ColoredBox(
                      color: HgColors.line,
                      child: Icon(Icons.tv_rounded, color: HgColors.brown),
                    )
                  : Image.network(
                      channel.thumbUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: HgColors.line,
                        child: Icon(Icons.tv_rounded, color: HgColors.brown),
                      ),
                    ),
            ),
          ),
          Expanded(
            child: Text(
              channel.title,
              style: HgText.body(size: 16, color: HgColors.ink),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: channel.approved
                  ? HgColors.green.withValues(alpha: 0.15)
                  : HgColors.mango.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              channel.approved ? 'approved' : 'pending',
              style: HgText.body(
                size: 12,
                color: channel.approved ? HgColors.green : HgColors.brown,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
