import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/channel_reviews.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

/// Every channel one kid has, with an AI note on what each one actually
/// publishes, so a parent can drop the ones they do not want.
///
/// Sized for the real problem: one child in the household is subscribed to 153
/// channels. Nobody audits 153 channels by hand, so this list has to stay fast
/// and calm at that size - lazily built rows, one shrinking poll, and anything
/// worth reading floated to the top.
///
/// PROTOCOL: the review is advice, not a verdict on a creator, and `unknown`
/// means too little was published recently to judge. The wording here holds to
/// both; nothing on this screen claims certainty.
///
/// Pops `true` when a channel was removed, so the kid page can refresh.
class ChannelReviewsScreen extends StatefulWidget {
  const ChannelReviewsScreen({super.key, required this.kid});

  final Kid kid;

  @override
  State<ChannelReviewsScreen> createState() => _ChannelReviewsScreenState();
}

class _ChannelReviewsScreenState extends State<ChannelReviewsScreen> {
  ChannelReviewList? _list;
  ReviewFilter _filter = ReviewFilter.all;
  Object? _loadError;
  String? _pollError;
  bool _polling = false;
  bool _gone = false;
  bool _changed = false;

  /// Channels whose review has moved toward concern since the parent approved
  /// them. Shown above the list; never acted on without the parent.
  List<ChannelDrift> _drifted = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // The poll loop outlives a widget that is popped mid-flight, so it checks
    // this before every setState.
    _gone = true;
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _list = null;
      _loadError = null;
      _pollError = null;
    });
    try {
      final channels = await context.read<AppState>().gateway.channels(
        widget.kid.id,
      );
      if (_gone) return;
      setState(() => _list = ChannelReviewList(channels: channels));
      unawaited(_poll());
      unawaited(_checkDrift(channels));
    } catch (e) {
      if (!_gone) setState(() => _loadError = e);
    }
  }

  /// Ask for whatever is still missing, merge, wait, repeat.
  ///
  /// The request shrinks every round because [ChannelReviewList.outstanding]
  /// drops everything that has come back: 153 ids on the first call, then only
  /// what is left. The delay is steady while results keep arriving and backs
  /// off geometrically when they stop, so a stuck gateway is never hammered.
  Future<void> _poll() async {
    final list = _list;
    if (list == null || _polling) return;
    // Held across the loop: the screen can be popped mid-poll, and the
    // gateway is a plain object, not something that needs a live context.
    final gateway = context.read<AppState>().gateway;
    _polling = true;
    try {
      while (!_gone && !list.stopped) {
        try {
          final batch = await gateway.channelReviews(list.outstanding);
          if (_gone) return;
          setState(() => list.apply(batch));
        } catch (e) {
          if (!_gone) setState(() => _pollError = '$e');
          return;
        }
        if (list.stopped) break;
        await Future<void>.delayed(list.nextDelay);
      }
    } finally {
      _polling = false;
    }
  }

  /// Which of these channels are not what they were when they were approved.
  ///
  /// Runs alongside the review poll rather than after it: a drift is about
  /// channels the parent approved long ago, and it should not wait behind 153
  /// first-time reviews. A failure here is silent on purpose — the reviews
  /// are the screen's job, and a second error line over them would cost more
  /// than it tells anyone.
  Future<void> _checkDrift(List<Channel> channels) async {
    if (channels.isEmpty) return;
    try {
      final check = await context.read<AppState>().gateway.checkDrift([
        for (final c in channels) c.id,
      ]);
      if (_gone) return;
      // Only the ones that got worse. A channel that improved is not an
      // interruption (PROTOCOL).
      setState(() => _drifted = check.worse);
    } catch (_) {
      // Left as it was: no drift shown is the honest state when the check
      // did not come back.
    }
  }

  void _dismissDrift(ChannelDrift drift) =>
      setState(() => _drifted = [..._drifted]..remove(drift));

  void _checkAgain() {
    setState(() {
      _pollError = null;
      _list?.resume();
    });
    unawaited(_poll());
  }

  Future<void> _openReview(ReviewRow row) async {
    final removed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ChannelReviewDetailScreen(
          kid: widget.kid,
          channel: row.channel,
          review: row.review,
        ),
      ),
    );
    if ((removed ?? false) && mounted) await _remove(row.channel);
  }

  /// Remove now, and offer it back for as long as the snackbar is up. The
  /// review itself is cached per channel, so an undo does not re-review.
  Future<void> _remove(Channel channel) async {
    final list = _list;
    if (list == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final gateway = context.read<AppState>().gateway;
    try {
      await gateway.removeChannel(widget.kid.id, channel.id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not remove: $e')));
      return;
    }
    if (_gone) return;
    final removal = list.remove(channel.id);
    setState(() => _changed = true);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          '${channel.title} removed from ${widget.kid.nickname}.',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        action: SnackBarAction(
          label: 'Undo',
          textColor: HgColors.mango,
          onPressed: () => unawaited(_undo(removal)),
        ),
      ),
    );
  }

  Future<void> _undo(ChannelRemoval removal) async {
    final list = _list;
    if (list == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Undo is the ordinary import of one channel: the same approval path,
      // not a special case the gateway has to know about.
      await context.read<AppState>().gateway.importChannels(widget.kid.id, [
        removal.channel.id,
      ]);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not put it back: $e')),
      );
      return;
    }
    if (_gone) return;
    setState(() => list.undo(removal));
    unawaited(_poll());
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: ParentScaffold(
        subtitle: 'For ${widget.kid.nickname}',
        title: 'What these channels show',
        body: switch (list) {
          _ when _loadError != null => LoadError(_loadError!, onRetry: _load),
          null => const Center(
            child: CircularProgressIndicator(color: HgColors.mango),
          ),
          _ when list.total == 0 => _empty(),
          _ => _body(list),
        },
      ),
    );
  }

  Widget _empty() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          const GilliMini(size: 96),
          Text(
            'No channels yet',
            textAlign: TextAlign.center,
            style: HgText.display(size: 24, color: HgColors.ink),
          ),
          Text(
            'Import ${widget.kid.nickname}\'s subscriptions and this list '
            'fills in with what each channel publishes.',
            textAlign: TextAlign.center,
            style: HgText.body(size: 15, color: HgColors.brown),
          ),
        ],
      ),
    ),
  );

  Widget _body(ChannelReviewList list) {
    final rows = list.rows(_filter);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Progress(
          list: list,
          error: _pollError,
          onCheckAgain: _pollError != null || list.gaveUp ? _checkAgain : null,
        ),
        _FilterRow(
          filter: _filter,
          list: list,
          onChanged: (f) => setState(() => _filter = f),
        ),
        Expanded(
          // Lazily built: at 153 rows only the visible dozen is ever laid out.
          child: ListView.builder(
            // Named so its scroll offset cannot be restored into some other
            // screen's list: Flutter keys scroll positions by tree shape, and
            // two similar ListViews in one Navigator otherwise collide.
            key: PageStorageKey<String>('reviews_${widget.kid.id}'),
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            itemCount: rows.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) return _header(list, rows.length);
              final row = rows[i - 1];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _ReviewTile(row: row, onTap: () => _openReview(row)),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Drift first, then the note about what these reviews are.
  ///
  /// A drift is the one thing on this screen a parent could not have found by
  /// scrolling: the channel already passed once, so it is sitting quietly in
  /// a list of 153 looking exactly like the rest.
  Widget _header(ChannelReviewList list, int shown) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final drift in _drifted)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _DriftCard(
            drift: drift,
            kidName: widget.kid.nickname,
            onRemove: () {
              final row = list
                  .rows()
                  .where((r) => r.channel.id == drift.channelId)
                  .firstOrNull;
              _dismissDrift(drift);
              unawaited(
                _remove(
                  row?.channel ??
                      Channel(
                        id: drift.channelId,
                        title: drift.title,
                        thumbUrl: '',
                        approved: true,
                      ),
                ),
              );
            },
            onKeep: () => _dismissDrift(drift),
          ),
        ),
      _adviceNote(shown),
    ],
  );

  /// Scrolls away with the list rather than sitting over it: at 153 rows the
  /// screen belongs to the channels.
  Widget _adviceNote(int shown) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      _filter == ReviewFilter.all
          ? 'Gilli reads each channel\'s recent uploads and says what it '
                'publishes. It is advice, not a verdict on anyone: you decide '
                'what stays.'
          : '$shown ${shown == 1 ? 'channel' : 'channels'} in this view.',
      style: HgText.body(size: 14, color: HgColors.brown),
    ),
  );
}

/// A channel that is not what it was when this parent approved it.
///
/// PROTOCOL "Channel drift". Three things this card has to keep doing:
///
///  - **Say what changed, not what the channel is.** The parent already read
///    the review once and approved it; the only news is the difference, so
///    `what_changed` leads and the two verdicts sit under it as evidence.
///  - **Show the uploads it is based on.** `sample_titles` are the new videos
///    that moved the review, so the parent can check the claim rather than
///    take it.
///  - **Decide nothing.** HeyGilli never removes a channel on its own. Both
///    buttons here are the parent's, and "Keep it" is a real answer that
///    simply puts the card away.
class _DriftCard extends StatelessWidget {
  const _DriftCard({
    required this.drift,
    required this.kidName,
    required this.onRemove,
    required this.onKeep,
  });

  final ChannelDrift drift;
  final String kidName;
  final VoidCallback onRemove;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final move = drift.verdictMove;
    return PCard(
      color: const Color(0xFFFDF1E7),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Row(
            spacing: 10,
            children: [
              const Icon(Icons.trending_down_rounded, color: HgColors.coral),
              Expanded(
                child: Text(
                  'This is not what it was',
                  style: HgText.label(color: HgColors.coral),
                ),
              ),
            ],
          ),
          Text(
            drift.title,
            style: HgText.display(size: 22, color: HgColors.ink),
          ),
          if (drift.whatChanged.isNotEmpty)
            Text(
              drift.whatChanged,
              style: HgText.body(size: 15, color: HgColors.ink),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (move.isNotEmpty)
                _DriftChip(label: move)
              else
                const _DriftChip(label: 'Same verdict, something new in it'),
              for (final f in drift.newFlags)
                _DriftChip(label: 'New: ${f.label}'),
            ],
          ),
          for (final f in drift.newFlags)
            if (f.note.isNotEmpty)
              Text(f.note, style: HgText.body(size: 14, color: HgColors.brown)),
          if (drift.sampleTitles.isNotEmpty) ...[
            Text('THE UPLOADS THAT CHANGED IT', style: HgText.label()),
            for (final t in drift.sampleTitles)
              Text('- $t', style: HgText.body(size: 14, color: HgColors.brown)),
          ],
          Text(
            // Said out loud because a parent who sees a warning card may
            // reasonably assume something was already done about it.
            'Nothing has changed for $kidName. This channel is still '
            'approved, and it stays approved until you say otherwise.',
            style: HgText.body(size: 13, color: HgColors.muted),
          ),
          Row(
            spacing: 10,
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    onPressed: onRemove,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: HgColors.coral,
                      side: const BorderSide(color: HgColors.coral, width: 2),
                      shape: const StadiumBorder(),
                    ),
                    child: Text(
                      'Remove it',
                      style: HgText.body(size: 15, color: HgColors.coral),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: onKeep,
                    child: Text(
                      'Keep it',
                      style: HgText.body(size: 15, color: HgColors.white),
                    ),
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

class _DriftChip extends StatelessWidget {
  const _DriftChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: HgColors.white,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: HgText.body(size: 13, color: HgColors.brown)),
    );
  }
}

/// "Reviewed 40 of 153", with a thin bar. Honest about what has not come back.
class _Progress extends StatelessWidget {
  const _Progress({required this.list, this.error, this.onCheckAgain});

  final ChannelReviewList list;
  final String? error;
  final VoidCallback? onCheckAgain;

  @override
  Widget build(BuildContext context) {
    final done = list.reviewedCount;
    final total = list.total;
    final finished = list.complete;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Row(
            spacing: 12,
            children: [
              Expanded(
                child: Text(
                  finished ? 'Reviewed all $total' : 'Reviewed $done of $total',
                  style: HgText.body(size: 15, color: HgColors.brown),
                ),
              ),
              if (onCheckAgain != null)
                SizedBox(
                  height: 48,
                  child: TextButton(
                    onPressed: onCheckAgain,
                    style: TextButton.styleFrom(
                      foregroundColor: HgColors.brown,
                    ),
                    child: Text(
                      'Check again',
                      style: HgText.body(size: 15, color: HgColors.brown),
                    ),
                  ),
                ),
            ],
          ),
          if (!finished)
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : done / total,
                minHeight: 6,
                backgroundColor: HgColors.line,
                color: HgColors.mango,
              ),
            ),
          if (error != null)
            Text(
              'The reviews stopped coming: $error',
              style: HgText.body(size: 13, color: HgColors.coral),
            )
          else if (list.gaveUp && !finished)
            Text(
              'Still working through the rest. Check again in a minute.',
              style: HgText.body(size: 13, color: HgColors.muted),
            ),
        ],
      ),
    );
  }
}

/// All / Needs a look / Good, with counts.
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.filter,
    required this.list,
    required this.onChanged,
  });

  final ReviewFilter filter;
  final ChannelReviewList list;
  final ValueChanged<ReviewFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Row(
        spacing: 8,
        children: [
          for (final f in ReviewFilter.values)
            Expanded(
              child: Material(
                color: f == filter ? HgColors.mango : HgColors.white,
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => onChanged(f),
                  child: SizedBox(
                    height: 48,
                    child: Center(
                      child: Text(
                        '${f.label} ${list.countFor(f)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HgText.body(
                          size: 14,
                          weight: FontWeight.w800,
                          color: f == filter ? HgColors.ink : HgColors.brown,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One row: the channel, a labelled verdict chip, and the one-line summary.
class _ReviewTile extends StatelessWidget {
  const _ReviewTile({required this.row, required this.onTap});

  final ReviewRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final review = row.review;
    return PCard(
      padding: const EdgeInsets.all(12),
      onTap: onTap,
      child: Row(
        spacing: 12,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChannelThumb(title: row.channel.title, url: row.channel.thumbUrl),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Text(
                  row.channel.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HgText.body(size: 16, color: HgColors.ink),
                ),
                VerdictChip(state: row.state, verdict: review?.verdict),
                Text(
                  switch (row.state) {
                    ReviewRowState.reviewed => review!.summary,
                    ReviewRowState.pending => 'Reading recent uploads.',
                    ReviewRowState.unavailable =>
                      'No review came back for this one.',
                  },
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HgText.body(
                    size: 14,
                    weight: FontWeight.w600,
                    color: row.state == ReviewRowState.reviewed
                        ? HgColors.brown
                        : HgColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Verdict as colour *and* words. Never colour alone: a chip that only differs
/// by hue is unreadable to a colour-blind parent and invisible in a
/// screenshot printed in grey.
class VerdictChip extends StatelessWidget {
  const VerdictChip({
    super.key,
    required this.state,
    this.verdict,
    this.big = false,
  });

  final ReviewRowState state;
  final ReviewVerdict? verdict;
  final bool big;

  /// Text and background are picked as a pair so every chip clears 4.5:1.
  static (Color bg, Color fg, String label) styleFor(
    ReviewRowState state,
    ReviewVerdict? verdict,
  ) => switch (state) {
    ReviewRowState.pending => (
      const Color(0xFFF3EEE6),
      const Color(0xFF6B5A48),
      'Checking',
    ),
    ReviewRowState.unavailable => (
      const Color(0xFFF3EEE6),
      const Color(0xFF6B5A48),
      'No review',
    ),
    ReviewRowState.reviewed => switch (verdict ?? ReviewVerdict.unknown) {
      ReviewVerdict.good => (
        const Color(0xFFE7F1E2),
        HgColors.green,
        ReviewVerdict.good.label,
      ),
      ReviewVerdict.mixed => (
        const Color(0xFFFBEBD1),
        const Color(0xFF8A5A00),
        ReviewVerdict.mixed.label,
      ),
      ReviewVerdict.concern => (
        const Color(0xFFFBE3DB),
        const Color(0xFFB03A16),
        ReviewVerdict.concern.label,
      ),
      ReviewVerdict.unknown => (
        HgColors.line,
        const Color(0xFF6B5A48),
        ReviewVerdict.unknown.label,
      ),
    },
  };

  @override
  Widget build(BuildContext context) {
    final (bg, fg, label) = styleFor(state, verdict);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: big ? 14 : 10,
        vertical: big ? 7 : 4,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: HgText.body(
          size: big ? 15 : 13,
          weight: FontWeight.w800,
          color: fg,
        ),
      ),
    );
  }
}

/// Square channel picture with a lettered stand-in, shared by the list and the
/// full review.
class ChannelThumb extends StatelessWidget {
  const ChannelThumb({
    super.key,
    required this.title,
    required this.url,
    this.size = 48,
  });

  final String title;
  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: size,
        height: size,
        child: url.isEmpty
            ? _letter()
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _letter(),
              ),
      ),
    );
  }

  Widget _letter() {
    final t = title.trim();
    return ColoredBox(
      color: HgColors.line,
      child: Center(
        child: Text(
          t.isEmpty ? '?' : t[0].toUpperCase(),
          style: HgText.display(size: size * 0.45, color: HgColors.brown),
        ),
      ),
    );
  }
}

/// The full review for one channel: what it publishes, what the reviewer
/// noticed, the ages it suits, and the uploads it was all read from.
///
/// Pops `true` when the parent asked to remove the channel; the list screen
/// does the removing so the undo lives in one place.
class ChannelReviewDetailScreen extends StatefulWidget {
  const ChannelReviewDetailScreen({
    super.key,
    required this.kid,
    required this.channel,
    this.review,
  });

  final Kid kid;
  final Channel channel;
  final ChannelReview? review;

  @override
  State<ChannelReviewDetailScreen> createState() =>
      _ChannelReviewDetailScreenState();
}

class _ChannelReviewDetailScreenState extends State<ChannelReviewDetailScreen> {
  late ChannelReview? _review = widget.review;
  bool _busy = false;
  String? _error;

  /// Opened before the poll reached this channel, or the parent asked for a
  /// fresh read.
  Future<void> _fetch({bool refresh = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final review = await context.read<AppState>().gateway.channelReview(
        widget.channel.id,
        refresh: refresh,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _review = review;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'No review yet for this channel.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final review = _review;
    return ParentScaffold(
      subtitle: 'For ${widget.kid.nickname}',
      title: widget.channel.title,
      body: ListView(
        key: PageStorageKey<String>('review_${widget.channel.id}'),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Row(
            spacing: 14,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ChannelThumb(
                title: widget.channel.title,
                url: widget.channel.thumbUrl,
                size: 64,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    VerdictChip(
                      state: review == null
                          ? ReviewRowState.pending
                          : ReviewRowState.reviewed,
                      verdict: review?.verdict,
                      big: true,
                    ),
                    Text(
                      review?.verdict.blurb ??
                          'This one has not been reviewed yet.',
                      style: HgText.body(size: 14, color: HgColors.brown),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (review == null) ...[
            if (_busy)
              const Center(
                child: CircularProgressIndicator(color: HgColors.mango),
              )
            else
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _fetch,
                  child: const Text('Review this channel now'),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: HgText.body(size: 14, color: HgColors.coral),
              ),
            ],
          ] else ...[
            PCard(
              child: Text(
                review.summary,
                style: HgText.body(
                  size: 16,
                  weight: FontWeight.w600,
                  color: HgColors.ink,
                ),
              ),
            ),
            if (review.flags.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('WHAT IT NOTICED', style: HgText.label()),
              const SizedBox(height: 8),
              for (final flag in review.flags) ...[
                PCard(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      Text(
                        flag.label,
                        style: HgText.body(size: 15, color: HgColors.ink),
                      ),
                      if (flag.note.isNotEmpty)
                        Text(
                          flag.note,
                          style: HgText.body(
                            size: 14,
                            weight: FontWeight.w600,
                            color: HgColors.brown,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ],
            const SizedBox(height: 12),
            Text('SUITS', style: HgText.label()),
            const SizedBox(height: 6),
            Text(
              review.goodFor.isEmpty
                  ? 'The review did not put an age on this one.'
                  : '${review.goodForLabel}'
                        '${review.suits(widget.kid.band) ? '' : '  |  '
                                  '${widget.kid.nickname} is in ${widget.kid.band.label}'}',
              style: HgText.body(size: 15, color: HgColors.brown),
            ),
            const SizedBox(height: 20),
            Text('READ FROM THESE UPLOADS', style: HgText.label()),
            const SizedBox(height: 8),
            if (review.sampleTitles.isEmpty)
              Text(
                'No recent uploads were listed.',
                style: HgText.body(size: 15, color: HgColors.muted),
              )
            else
              for (final title in review.sampleTitles)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    spacing: 10,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 3),
                        child: Icon(
                          Icons.play_circle_outline_rounded,
                          size: 18,
                          color: HgColors.brown,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          title,
                          style: HgText.body(
                            size: 15,
                            weight: FontWeight.w600,
                            color: HgColors.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: 18),
            // The honesty line. It is the whole reason this screen shows its
            // sources: a parent can check the advice instead of trusting it.
            Text(
              'Read from recent uploads by ${review.model.isEmpty ? 'the review model' : review.model}'
              '${_when(review.reviewedAt)}. This is advice about what a '
              'channel has been publishing, not a judgement on the people who '
              'make it. You decide what stays.',
              style: HgText.body(size: 13, color: HgColors.brown),
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            height: 52,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
              label: Text(
                'Remove from ${widget.kid.nickname}',
                style: HgText.body(size: 16, color: const Color(0xFFB03A16)),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFB03A16),
                backgroundColor: HgColors.white,
                side: const BorderSide(color: Color(0xFFF0C9BC), width: 2),
                shape: const StadiumBorder(),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Removing takes it off ${widget.kid.nickname} straight away. You '
            'can undo it, or add the channel back later.',
            style: HgText.body(size: 13, color: HgColors.muted),
          ),
        ],
      ),
    );
  }

  /// " on 6 September" from an ISO timestamp; empty when there is none, so the
  /// sentence still reads.
  static String _when(String iso) {
    final at = DateTime.tryParse(iso);
    if (at == null) return '';
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final local = at.toLocal();
    return ' on ${local.day} ${months[local.month - 1]}';
  }
}
