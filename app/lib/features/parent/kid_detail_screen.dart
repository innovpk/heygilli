import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../main.dart';
import 'break_messages_card.dart';
import 'channel_reviews_screen.dart';
import 'digest_screen.dart';
import 'history_screen.dart';
import 'import_subscriptions_screen.dart';
import 'add_kid_sheet.dart';
import 'parent_widgets.dart';
import 'policy_screen.dart';
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

class _KidDetailScreenState extends State<KidDetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

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
  bool _curating = false;
  Kid? _edited;
  String? _error;

  void _reload() => setState(() {
    _channels = _load();
  });

  Future<List<Channel>> _load() =>
      context.read<AppState>().gateway.channels(widget.kid.id);

  @override
  void dispose() {
    _tabs.dispose();
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

  /// Correct this child's nickname, age or languages.
  ///
  /// Changing the age changes the band, which is what the Curator screens
  /// against and what decides whether the child is read to or shown text, so
  /// the screen is rebuilt from the returned kid rather than the stale one.
  Future<void> _editKid() async {
    final updated = await showEditKidSheet(context, _edited ?? widget.kid);
    if (updated == null || !mounted) return;
    setState(() => _edited = updated);
  }

  /// Ask the server to screen this kid's channels again.
  ///
  /// Screening used to be kicked off only by an import, so a household whose
  /// first run came back with nothing — the server could not read a
  /// transcript, the model was briefly down — had an empty home for their
  /// child and nothing at all they could press. The work happens on the
  /// server and takes minutes, so this says it started and no more: claiming
  /// it had finished would be a lie, and a spinner held for minutes is worse.
  Future<void> _curateNow() async {
    setState(() {
      _curating = true;
      _error = null;
    });
    try {
      await context.read<AppState>().gateway.curateNow(widget.kid.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Looking through these channels for new videos. It takes a few '
            'minutes; ${widget.kid.nickname}\'s videos appear as they pass.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start: $e');
    } finally {
      if (mounted) setState(() => _curating = false);
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
    // The edit sheet returns the corrected child; until this screen is popped
    // and rebuilt, widget.kid still holds the old age and band.
    final kid = _edited ?? widget.kid;
    return ParentScaffold(
      title: kid.nickname,
      subtitle: 'Age ${kid.age}  |  band ${kid.band.label}',
      actions: [
        // The age is right there in the subtitle and used to be unchangeable:
        // no edit anywhere, and no delete either, so a child entered wrong
        // stayed wrong. It belongs next to the thing it corrects.
        IconButton(
          onPressed: _editKid,
          icon: const Icon(Icons.edit_outlined),
          tooltip: 'Edit ${kid.nickname}',
          color: HgColors.brown,
        ),
        KidAvatar(kid: kid, size: 48),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
              ],
            ),
          ),
          // Three tabs rather than one column holding everything a parent
          // might ever want about a child. The answer to "where do I change
          // this" had become "keep scrolling": the device setting sat below
          // the break messages and nobody found it.
          //
          // Split by question rather than by feature — what happened, what
          // is allowed, and what they can watch.
          TabBar(
            controller: _tabs,
            labelColor: HgColors.ink,
            unselectedLabelColor: HgColors.brown,
            indicatorColor: HgColors.mango,
            indicatorWeight: 3,
            tabs: const [
              Tab(text: 'How it is going'),
              Tab(text: 'Rules'),
              Tab(text: 'Channels'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  children: [
                    PCard(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => DigestScreen(kid: kid),
                        ),
                      ),
                      child: Row(
                        spacing: 14,
                        children: [
                          const Icon(
                            Icons.auto_stories_rounded,
                            color: HgColors.brown,
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "Today's digest",
                                  style: HgText.display(
                                    size: 22,
                                    color: HgColors.ink,
                                  ),
                                ),
                                Text(
                                  kid.band == AgeBand.b4to6
                                      ? 'Words said, words heard, one thing to try'
                                      : 'Understood, shaky, one question for dinner',
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
                    const SizedBox(height: 12),
                    PCard(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ProgressScreen(kid: kid),
                        ),
                      ),
                      child: Row(
                        spacing: 14,
                        children: [
                          const Icon(
                            Icons.insights_rounded,
                            color: HgColors.brown,
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Progress',
                                  style: HgText.display(
                                    size: 22,
                                    color: HgColors.ink,
                                  ),
                                ),
                                Text(
                                  kid.band == AgeBand.b4to6
                                      ? 'Minutes, words coming back, what to try'
                                      : 'Minutes, what stuck, what needs another look',
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
                    const SizedBox(height: 12),
                    // Only says anything once a parent has ticked history on an import.
                    // Shown anyway, because the empty state is where they find out the
                    // option exists and that it is off.
                    PCard(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => HistoryScreen(kid: kid),
                        ),
                      ),
                      child: Row(
                        spacing: 14,
                        children: [
                          const Icon(
                            Icons.history_rounded,
                            color: HgColors.brown,
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'What they actually watched',
                                  style: HgText.display(
                                    size: 22,
                                    color: HgColors.ink,
                                  ),
                                ),
                                Text(
                                  'How much came from channels nobody chose. Only if '
                                  'you asked for it during an import',
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
                    const SizedBox(height: 12),
                    // Sits above the time settings because it is the one that decides
                    // what reaches this child at all, rather than for how long.
                  ],
                ),
                ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  children: [
                    PCard(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PolicyScreen(kid: kid),
                        ),
                      ),
                      child: Row(
                        spacing: 14,
                        children: [
                          const Icon(Icons.rule_rounded, color: HgColors.brown),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'What your household wants',
                                  style: HgText.display(
                                    size: 22,
                                    color: HgColors.ink,
                                  ),
                                ),
                                Text(
                                  'A few questions about what is fine here, drawn from '
                                  "${kid.nickname}'s own channels",
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
                    const SizedBox(height: 12),
                    TimeLimitsCard(kid: kid),
                    const SizedBox(height: 16),
                    BreakMessagesCard(kid: kid),
                    const SizedBox(height: 24),
                  ],
                ),
                ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  children: [
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
                        icon: const Icon(
                          Icons.subscriptions_outlined,
                          size: 22,
                        ),
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
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: _curating ? null : _curateNow,
                        icon: const Icon(Icons.refresh, size: 20),
                        label: Text(
                          _curating
                              ? 'Starting...'
                              : 'Look for new videos now',
                          style: HgText.body(size: 15, color: HgColors.ink),
                        ),
                        style: _importButtonStyle,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'HeyGilli checks these channels on its own. Use this when '
                      "${kid.nickname}'s videos have not appeared yet.",
                      style: HgText.body(size: 13, color: HgColors.muted),
                    ),
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
                              child: CircularProgressIndicator(
                                color: HgColors.mango,
                              ),
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
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
                                    style: HgText.body(
                                      size: 15,
                                      color: HgColors.brown,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
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
