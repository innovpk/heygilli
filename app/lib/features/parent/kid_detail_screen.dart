import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../main.dart';
import 'break_messages_card.dart';
import 'channel_reviews_screen.dart';
import 'digest_screen.dart';
import 'history_screen.dart';
import 'inbox_screen.dart';
import 'parent_home.dart';
import '../gate/pin_gate.dart';
import 'add_kid_sheet.dart';
import 'parent_widgets.dart';
import 'prompts_card.dart';
import 'hidden_screen.dart';
import 'setup_review_screen.dart';
import 'starter_channels_screen.dart';
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

  /// Open on Channels when this child has none.
  ///
  /// "How it is going" is the right first tab for a child who is watching, and
  /// the wrong one for a child added a minute ago: it is empty, and the one
  /// thing that has to happen next — approving channels, without which kid
  /// mode shows nothing at all — is behind the third tab. A parent who added a
  /// child and stopped here is a parent whose app never started.
  void _openOnChannelsIfEmpty() {
    _channels
        .then((list) {
          if (mounted && list.isEmpty) _tabs.animateTo(2);
        })
        .catchError((_) {
          // A channel list that would not load says nothing about which tab
          // to open on; leave the parent where they landed.
        });
  }

  final _url = TextEditingController();
  bool _adding = false;
  bool _curating = false;
  Kid? _edited;

  /// Deleting is several server calls over a sleeping free-tier gateway, so it
  /// can take seconds with nothing to show for it. Without this the parent
  /// taps Delete, the dialog closes, and the page sits there looking as
  /// though nothing happened — so they tap it again.
  bool _deleting = false;

  // Owned here rather than made inside _deleteKid: the dialog's TextField is
  // still built while the route animates out, so disposing it the moment
  // showDialog returns is a use-after-dispose.
  final TextEditingController _confirmName = TextEditingController();
  String? _error;

  void _reload() => setState(() {
    _channels = _load();
  });

  Future<List<Channel>> _load() =>
      context.read<AppState>().gateway.channels(widget.kid.id);

  @override
  void initState() {
    super.initState();
    _openOnChannelsIfEmpty();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _url.dispose();
    _confirmName.dispose();
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

  /// Remove this child and everything about them.
  ///
  /// Behind the PIN, then behind typing their name. Two gates because it is
  /// irreversible and there is nowhere to undo it: the PIN says a parent is
  /// holding the device, and the name says they meant this child rather than
  /// the row above.
  Future<void> _deleteKid() async {
    final kid = _edited ?? widget.kid;
    if (!await showPinGate(context)) return;
    if (!mounted) return;

    _confirmName.clear();
    final typed = _confirmName;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: HgColors.white,
        title: Text(
          'Delete ${kid.nickname}?',
          style: HgText.display(size: 22, color: HgColors.ink),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Their channels, what they have watched, their answers and '
              'their limits all go. This cannot be undone, and nothing is '
              'kept behind.',
              style: HgText.body(size: 15, color: HgColors.brown),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: typed,
              autofocus: true,
              decoration: InputDecoration(hintText: 'Type ${kid.nickname}'),
              style: HgText.body(size: 16, color: HgColors.ink),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep them'),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: typed,
            builder: (context, value, _) => FilledButton(
              // Enabled only once the name matches, so the destructive button
              // cannot be the one a thumb lands on by accident.
              onPressed:
                  value.text.trim().toLowerCase() ==
                      kid.nickname.trim().toLowerCase()
                  ? () => Navigator.of(context).pop(true)
                  : null,
              style: FilledButton.styleFrom(backgroundColor: HgColors.coral),
              child: const Text('Delete'),
            ),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _deleting = true);
    try {
      await context.read<AppState>().deleteKid(kid);
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(content: Text('${kid.nickname} was deleted.')),
      );
    } catch (e) {
      if (mounted) setState(() => _deleting = false);
      messenger.showSnackBar(SnackBar(content: Text('Could not delete: $e')));
    }
  }

  /// Channels to start with, for a household that has none.
  ///
  /// Reloads the list on the way back: the point of the screen is that the
  /// Channels tab is no longer empty afterwards.
  Future<void> _startFromSuggestions() async {
    final kid = _edited ?? widget.kid;
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => StarterChannelsScreen(kid: kid)),
    );
    if (added != true || !mounted) return;
    setState(() => _channels = _load());
    // Straight on to what those channels actually contain. Approving a
    // channel approves a channel: the uploads are then read one at a time,
    // and until somebody says yes to them the child's screen is empty. That
    // step used to live in the inbox, later, in a different part of the app.
    await _reviewVideos();
  }

  /// What the child will see, with the Curator's verdict on each.
  Future<void> _reviewVideos() async {
    final decided = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SetupReviewScreen(kid: _edited ?? widget.kid),
      ),
    );
    if (decided == true && mounted) setState(() => _channels = _load());
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
            'Looking for new videos, and going back over any that were read '
            'on their title alone. It takes a few minutes; '
            '${widget.kid.nickname}\'s videos appear as they pass.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start: $e');
    } finally {
      if (mounted) setState(() => _curating = false);
    }
  }

  /// The other way to reach a child's own YouTube Kids profile: a Google
  /// Takeout export (PROTOCOL "Takeout import").
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
    final page = ParentScaffold(
      title: kid.nickname,
      subtitle: 'Age ${kid.age}  |  band ${kid.band.label}',
      // The rail comes with the child's page rather than being left behind on
      // the list. Switching child from here replaces this route instead of
      // stacking another one on it.
      sidebar: HouseholdSidebar(
        selectedKidId: kid.id,
        onKids: () => Navigator.of(context).maybePop(),
        onInbox: () => Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const InboxScreen()),
        ),
        onKid: (next) {
          if (next.id == kid.id) return;
          openKid(context, next, replace: true);
        },
        onAddKid: () => addKidFlow(context),
      ),
      actions: [
        // The age is right there in the subtitle and used to be unchangeable:
        // no edit anywhere, and no delete either, so a child entered wrong
        // stayed wrong. It belongs next to the thing it corrects.
        IconButton(
          onPressed: _deleting ? null : _editKid,
          icon: const Icon(Icons.edit_outlined),
          tooltip: 'Edit ${kid.nickname}',
          color: HgColors.brown,
        ),
        // In the header, so it is reachable from any tab rather than only
        // from the bottom of one of them. It was at the end of Rules, where
        // nobody looked for it — and "Delete Abdul" was never a rule about
        // what Abdul may watch.
        IconButton(
          onPressed: _deleting ? null : _deleteKid,
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete ${kid.nickname}',
          color: HgColors.coral,
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
                      style: HgText.display(size: 22, color: HgColors.white),
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
                    // Four independent cards. In one column a parent scrolls
                    // past Time limits to reach Break time on a window with
                    // room for both; side by side once there is room for two
                    // readable columns.
                    HgCardColumns(
                      children: [
                        TimeLimitsCard(kid: kid),
                        BreakMessagesCard(kid: kid),
                        PromptsCard(kid: kid),
                      ],
                    ),
                    // Deleting used to live down here, at the end of Rules.
                    // It is in the header now, on every tab, because a parent
                    // who wants a child gone should not have to guess which
                    // tab hides the button.
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
                      'Start from suggestions if you are not sure, bring across a '
                      'YouTube Kids profile from a Takeout export, or paste a '
                      'channel, @handle or video URL.',
                      style: HgText.body(size: 14, color: HgColors.brown),
                    ),
                    const SizedBox(height: 12),
                    // First, because it is the only one that asks nothing of
                    // the parent. Takeout means requesting an export from
                    // Google and waiting for it, and importing an account
                    // means handing one over before they know they want this
                    // — strange things to ask of somebody who has just
                    // arrived, and the reason an empty app stayed empty.
                    SizedBox(
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _startFromSuggestions,
                        icon: const Icon(Icons.auto_awesome, size: 22),
                        label: Text(
                          'Suggest channels for ${kid.nickname}',
                          style: HgText.body(size: 15, color: HgColors.white),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Screening that only shows its successes has to be taken
                    // on trust. The child is never told a video was hidden,
                    // which is right for them and wrong for the person who
                    // set the rules.
                    SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => HiddenScreen(kid: kid),
                          ),
                        ),
                        icon: const Icon(
                          Icons.visibility_off_outlined,
                          size: 22,
                        ),
                        label: Text(
                          'What was kept from ${kid.nickname}',
                          style: HgText.body(size: 15, color: HgColors.ink),
                        ),
                        style: _importButtonStyle,
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Screening takes minutes, so the parent who left while it
                    // was still running needs a way back to the list rather
                    // than a one-time screen they can miss.
                    SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: _reviewVideos,
                        icon: const Icon(Icons.fact_check_outlined, size: 22),
                        label: Text(
                          'Review what Gilli screened',
                          style: HgText.body(size: 15, color: HgColors.ink),
                        ),
                        style: _importButtonStyle,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: _importFromTakeout,
                        icon: const Icon(Icons.folder_zip_outlined, size: 22),
                        label: Text(
                          "Import ${kid.nickname}'s YouTube Kids channels",
                          style: HgText.body(size: 15, color: HgColors.ink),
                        ),
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
                          _curating ? 'Starting...' : 'Look for new videos now',
                          style: HgText.body(size: 15, color: HgColors.ink),
                        ),
                        style: _importButtonStyle,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'HeyGilli checks these channels on its own. Use this when '
                      "${kid.nickname}'s videos have not appeared yet, or when "
                      'some of them say "read: the title only" — this goes back '
                      'and reads those properly, so the questions come from '
                      'what is said in them.',
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

    // While a delete runs the page is dimmed and the whole thing is
    // uninteractable, so a parent cannot start it twice and can see that
    // something is happening. Deleting is several server calls over a
    // free-tier gateway that may be asleep; without this it looks like
    // nothing happened.
    return Stack(
      children: [
        page,
        if (_deleting)
          Positioned.fill(
            child: ColoredBox(
              color: HgColors.cream.withValues(alpha: 0.82),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 16,
                  children: [
                    const CircularProgressIndicator(color: HgColors.mango),
                    Text(
                      'Deleting ${kid.nickname}...',
                      style: HgText.body(size: 16, color: HgColors.brown),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
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
