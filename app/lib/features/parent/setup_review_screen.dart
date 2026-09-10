import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'add_question_sheet.dart';
import 'ask_about_video_sheet.dart';
import 'hidden_screen.dart';
import 'parent_widgets.dart';

/// What the child will actually see, before they see it.
///
/// Approving channels approves *channels*: every upload from them is then read
/// against the household's answers, and the Curator comes out with three kinds
/// of answer. Only one of those — the ones it could not settle — used to reach
/// the parent, in the inbox, which is a different part of the app visited
/// later. So a parent who had just picked channels was sent away to finish
/// somewhere else, working from a list that never said what it had *not* asked
/// about, while the child's screen sat empty in the meantime.
///
/// Everything is here instead, with the reason attached, and the Curator's own
/// verdict as the starting position: a parent who agrees with all of it just
/// taps Done. The inbox goes back to being where later uploads arrive.
class SetupReviewScreen extends StatefulWidget {
  const SetupReviewScreen({super.key, required this.kid});
  final Kid kid;

  @override
  State<SetupReviewScreen> createState() => _SetupReviewScreenState();
}

/// The suggestions, which is not everything that was screened.
///
/// A video Gilli hid is the opposite of a suggestion, and putting it here with
/// its switch off asked the parent to answer a question nobody posed — worse,
/// "Allow all" then meant "allow the things we kept back too". A two-hour film
/// landed in a seven-year-old's science list this way. Hidden videos live on
/// the "Kept from" screen, which exists to be argued with, and this screen
/// points at it and says how many are there.
List<ReviewItem> _suggested(ReviewQueue queue) => [
  for (final item in queue.items)
    if (item.status != 'hide') item,
];

class _SetupReviewScreenState extends State<SetupReviewScreen> {
  /// Screening a channel's uploads is minutes of work, so the list arrives a
  /// few videos at a time. Polling rather than waiting for the whole run: a
  /// parent watching videos appear knows something is happening, which is the
  /// half of this that an empty screen got wrong.
  static const _poll = Duration(seconds: 6);

  ReviewQueue? _queue;
  Object? _error;
  Timer? _timer;
  bool _saving = false;

  /// The parent's answer per video, seeded from the Curator's verdict. Held
  /// here rather than sent per tap: whole channels are approved at a time, and
  /// a call per video would be a screen full of spinners.
  final _approved = <String, bool>{};

  /// Which tab is open: what the child will see, or what they will not.
  bool _showingShown = true;

  /// A switch flipped moves its card to the other tab, which from where the
  /// parent is looking means it vanishes. Saying where it went, with a way
  /// back, is what keeps that from reading as a card deleted by a slip.
  void _flip(ReviewItem item, bool approved) {
    setState(() => _approved[item.video.id] = approved);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        content: Text(approved ? 'Moved to Shown' : 'Moved to Hidden'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => setState(() => _approved[item.video.id] = !approved),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(_poll, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final queue = await context.read<AppState>().gateway.reviewQueue(
        widget.kid.id,
      );
      if (!mounted) return;
      setState(() {
        _queue = queue;
        _error = null;
        for (final item in _suggested(queue)) {
          // Only for videos the parent has not answered yet: a refresh must
          // never move a switch they have already set.
          _approved.putIfAbsent(item.video.id, () => item.startsApproved);
        }
      });
      if (!queue.stillScreening) _timer?.cancel();
    } catch (e) {
      if (mounted && _queue == null) setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    final queue = _queue;
    if (queue == null) return;
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AppState>().gateway.reviewDecide(
        widget.kid.id,
        approve: [
          for (final e in _approved.entries)
            if (e.value) e.key,
        ],
        hide: [
          for (final e in _approved.entries)
            if (!e.value) e.key,
        ],
      );
      navigator.pop(true);
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  void _setAll(bool approved) => setState(() {
    for (final key in _approved.keys.toList()) {
      _approved[key] = approved;
    }
  });

  @override
  Widget build(BuildContext context) {
    final queue = _queue;
    final suggested = queue == null ? const <ReviewItem>[] : _suggested(queue);
    final kept = queue == null ? 0 : queue.items.length - suggested.length;
    final yes = _approved.values.where((v) => v).length;
    return ParentScaffold(
      title: 'What ${widget.kid.nickname} will see',
      body: switch ((queue, _error)) {
        (null, final Object e?) => _Message(
          text: 'Could not load the screening: $e',
        ),
        (null, _) => const Center(
          child: CircularProgressIndicator(color: HgColors.mango),
        ),
        (final ReviewQueue q, _) when suggested.isEmpty => _Message(
          text: q.stillScreening
              ? 'Reading the first uploads from ${q.channels} '
                    '${q.channels == 1 ? 'channel' : 'channels'}. This takes a '
                    'few minutes — you can leave and come back.'
              : 'Nothing came back from these channels yet. New uploads will '
                    'appear in your inbox as they arrive.',
          spinning: q.stillScreening,
        ),
        (final ReviewQueue q, _) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
          children: [
            Text(
              'Gilli read these against your answers. Its verdict is already '
              'set for each one — change any you disagree with.',
              style: HgText.body(size: 14, color: HgColors.brown),
            ),
            if (q.stillScreening) ...[
              const SizedBox(height: 12),
              _StillScreening(screened: q.screened, expected: q.expected),
            ],
            const SizedBox(height: 12),
            // Wrap: on a 320pt phone the pair ran 36px past the edge.
            Wrap(
              spacing: 4,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => _setAll(true),
                  child: const Text('Allow all'),
                ),
                TextButton(
                  onPressed: _saving ? null : () => _setAll(false),
                  child: Text(
                    'Reject all',
                    style: HgText.body(size: 14, color: HgColors.coral),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _Tabs(
              shown: yes,
              hidden: suggested.length - yes,
              showingShown: _showingShown,
              onChanged: (v) => setState(() => _showingShown = v),
            ),
            if (!suggested.any(
              (i) =>
                  (_approved[i.video.id] ?? i.startsApproved) == _showingShown,
            ))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  _showingShown
                      ? 'Nothing is set to be shown yet.'
                      // Not "Nothing is hidden" when the screening kept some
                      // back: those are hidden too, and listed just below.
                      : kept > 0
                      ? 'Nothing here is switched off.'
                      : 'Nothing is hidden.',
                  style: HgText.body(size: 14, color: HgColors.brown),
                ),
              ),
            for (final item in suggested.where(
              (i) =>
                  (_approved[i.video.id] ?? i.startsApproved) == _showingShown,
            ))
              _ReviewCard(
                key: ValueKey(item.video.id),
                item: item,
                approved: _approved[item.video.id] ?? item.startsApproved,
                onChanged: _saving ? null : (v) => _flip(item, v),
                onAsk: () => AskAboutVideoSheet.open(
                  context,
                  kidId: widget.kid.id,
                  video: item.video,
                  channelTitle: item.channelTitle,
                ),
                onAddQuestion: () => AddQuestionSheet.show(
                  context,
                  kidId: widget.kid.id,
                  videoId: item.video.id,
                  videoTitle: item.video.title,
                ),
              ),
            if (kept > 0 && !_showingShown) ...[
              const SizedBox(height: 16),
              _KeptNote(kid: widget.kid, kept: kept),
            ],
            // The one rule on this screen that can silently not run. Nothing
            // over the ceiling is suggested, but a length is only knowable
            // through the parent's own Google grant; where it was not, the
            // ceiling skipped that video rather than judging it on a number
            // nobody has. A parent told nothing would read the ceiling as a
            // promise it cannot keep.
            if (q.unknownLength > 0 && q.maxMinutes > 0) ...[
              const SizedBox(height: 12),
              Text(
                'Nothing over ${q.maxMinutes} minutes is suggested. '
                '${q.unknownLength} of these ${q.unknownLength == 1 ? 'has' : 'have'} '
                'no length we could look up, so that check did not run on '
                '${q.unknownLength == 1 ? 'it' : 'them'}.',
                style: HgText.body(size: 13, color: HgColors.coral),
              ),
            ],
          ],
        ),
      },
      floating: queue == null || suggested.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _saving ? null : _save,
              backgroundColor: HgColors.mango,
              foregroundColor: HgColors.white,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: HgColors.white,
                      ),
                    )
                  : const Icon(Icons.check_rounded),
              label: Text(
                'Allow $yes ${yes == 1 ? 'video' : 'videos'}',
                style: HgText.body(color: HgColors.white),
              ),
            ),
    );
  }
}

class _StillScreening extends StatelessWidget {
  const _StillScreening({required this.screened, required this.expected});
  final int screened;
  final int expected;

  @override
  Widget build(BuildContext context) {
    return PCard(
      child: Row(
        spacing: 14,
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: HgColors.mango,
            ),
          ),
          Expanded(
            child: Text(
              'Still reading — $screened of about $expected done. More will '
              'appear here on their own.',
              style: HgText.body(size: 14, color: HgColors.brown),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeptNote extends StatelessWidget {
  const _KeptNote({required this.kid, required this.kept});
  final Kid kid;
  final int kept;

  @override
  Widget build(BuildContext context) {
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(
            '$kept more ${kept == 1 ? 'video was' : 'videos were'} kept back — '
            'too long, or something in ${kept == 1 ? 'it' : 'them'} Gilli keeps '
            'from every child. ${kid.nickname} will not see '
            '${kept == 1 ? 'it' : 'them'}.',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => HiddenScreen(kid: kid)),
              ),
              child: Text('See what was kept, and why'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown / Hidden, as a segmented switch. The counts are live, so a parent
/// flipping switches in one tab watches the other tab's number move.
class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.shown,
    required this.hidden,
    required this.showingShown,
    required this.onChanged,
  });

  final int shown;
  final int hidden;
  final bool showingShown;
  final ValueChanged<bool> onChanged;

  Widget _segment(String label, bool on, VoidCallback onTap) => Expanded(
    child: Semantics(
      button: true,
      selected: on,
      child: Material(
        color: on ? HgColors.ink : Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(11),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: HgText.display(
                size: 16,
                color: on ? HgColors.cream : HgColors.brown,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: HgColors.white,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        _segment('Shown ($shown)', showingShown, () => onChanged(true)),
        _segment('Hidden ($hidden)', !showingShown, () => onChanged(false)),
      ],
    ),
  );
}

enum _TagKind { asked, concern, topic, titleOnly }

/// One short tag. Concerns and "asked you" are rust, because they are why a
/// video is where it is; topics are quiet, because they only say what it is.
class _Tag extends StatelessWidget {
  const _Tag(this.text, this.kind);

  final String text;
  final _TagKind kind;

  @override
  Widget build(BuildContext context) {
    final (Color fill, Color edge, Color ink) = switch (kind) {
      _TagKind.asked => (HgColors.mango, HgColors.mango, HgColors.white),
      _TagKind.concern => (HgColors.white, HgColors.mango, HgColors.mango),
      _TagKind.topic => (HgColors.cream, HgColors.cream, HgColors.ink),
      _TagKind.titleOnly => (HgColors.white, HgColors.coral, HgColors.coral),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: edge, width: 1.5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: HgText.body(size: 12.5, color: ink, weight: FontWeight.w700),
      ),
    );
  }
}

class _ReviewCard extends StatefulWidget {
  const _ReviewCard({
    super.key,
    required this.item,
    required this.approved,
    required this.onChanged,
    required this.onAsk,
    required this.onAddQuestion,
  });

  final ReviewItem item;
  final bool approved;
  final ValueChanged<bool>? onChanged;
  final VoidCallback onAsk;

  /// A question of the parent's own for this video. The screening decides what
  /// a child may watch; this is the parent deciding what is worth talking
  /// about, which is the part they are the only expert in.
  final VoidCallback onAddQuestion;

  @override
  State<_ReviewCard> createState() => _ReviewCardState();
}

class _ReviewCardState extends State<_ReviewCard> {
  ReviewItem get item => widget.item;

  bool get _hasTags => item.topics.isNotEmpty || item.concerns.isNotEmpty;

  /// The reason sits behind "Why" once there are tags to skim instead — three
  /// lines of prose per video is what made this list hard going. A verdict from
  /// before the tags existed has nothing else to show, so it opens by default.
  late bool _open = !_hasTags;

  @override
  Widget build(BuildContext context) {
    final titleOnly = item.read == 'title only';
    final tags = <Widget>[
      if (item.status == 'ask_parent') const _Tag('Asked you', _TagKind.asked),
      for (final c in item.concerns) _Tag(c, _TagKind.concern),
      for (final t in item.topics) _Tag(t, _TagKind.topic),
      // A video read on its title alone is a different judgement from one read
      // on what is said in it, and the person deciding should be told which.
      if (titleOnly) const _Tag('Title only', _TagKind.titleOnly),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: PCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                // `thumb`, not `thumbUrl`: the server sends a URL only
                // sometimes, and `thumb` falls back to YouTube's own thumbnail
                // for the id.
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    item.video.thumb,
                    width: 92,
                    height: 62,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(width: 92),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      Text(
                        item.video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HgText.body(size: 15, color: HgColors.ink),
                      ),
                      Text(
                        item.channelTitle,
                        style: HgText.body(size: 13, color: HgColors.muted),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: widget.approved,
                  onChanged: widget.onChanged,
                  activeTrackColor: HgColors.mango,
                ),
              ],
            ),
            if (tags.isNotEmpty)
              Wrap(spacing: 6, runSpacing: 6, children: tags),
            if (_open)
              Text(
                item.reason,
                style: HgText.body(size: 14, color: HgColors.brown),
              ),
            // The screening answers the question it thought of. This is for
            // the one the parent actually has.
            Wrap(
              children: [
                if (_hasTags)
                  TextButton.icon(
                    onPressed: () => setState(() => _open = !_open),
                    icon: Icon(
                      _open
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                    ),
                    label: Text(_open ? 'Hide why' : 'Why'),
                    style: TextButton.styleFrom(
                      foregroundColor: HgColors.ink,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                TextButton.icon(
                  onPressed: widget.onAsk,
                  icon: const Icon(Icons.help_outline_rounded, size: 18),
                  label: const Text('Ask about this'),
                  style: TextButton.styleFrom(
                    foregroundColor: HgColors.ink,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
                TextButton.icon(
                  onPressed: widget.onAddQuestion,
                  icon: const Icon(Icons.add_comment_outlined, size: 18),
                  label: const Text('Add a question'),
                  style: TextButton.styleFrom(
                    foregroundColor: HgColors.ink,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.spinning = false});
  final String text;
  final bool spinning;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            if (spinning)
              const CircularProgressIndicator(color: HgColors.mango),
            Text(
              text,
              textAlign: TextAlign.center,
              style: HgText.body(size: 15, color: HgColors.brown),
            ),
          ],
        ),
      ),
    );
  }
}
