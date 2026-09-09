import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/analytics.dart';
import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';
import 'progress_charts.dart';

/// What a parent wants in ten seconds: is my child engaging, what are they
/// learning, and is there one thing worth doing today.
///
/// The agent's note sits at the top because it is the only part that tells the
/// parent what to *do*; the numbers underneath are there to back it up. No
/// streaks and no screen-time scolding: minutes are reported, never judged.
class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key, required this.kid, this.embedded = false});

  final Kid kid;

  /// True when this is the Progress tab of a child's page rather than a screen
  /// of its own. The tab already sits inside a ParentScaffold with the child's
  /// name at the top of it, and a second scaffold would draw that header, the
  /// rail and the back arrow all over again inside the first one.
  final bool embedded;

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  static const _ranges = [7, 14, 30];
  int _days = 14;
  late Future<Analytics> _future = _load();

  /// The Takeout import, when there has been one. Null both when there has not
  /// and when the gateway cannot answer, and the section simply does not
  /// appear — there is nothing honest to say about watching that happened
  /// before this app, without the export that measured it.
  late final Future<HistoryInsight?> _history = context
      .read<AppState>()
      .gateway
      .history(widget.kid.id)
      .catchError((_) => null);

  /// Which shaky concepts a later session has quietly come back to. Loaded
  /// separately because it does not move with the day range: a revisit is
  /// about a concept, not about a window.
  late Future<List<RevisitConcept>> _revisits = _loadRevisits();

  /// The words Gilli has offered in this child's other language. Empty for a
  /// household with one language, which is most of them.
  late Future<List<WordSeed>> _words = _loadWords();

  Future<Analytics> _load() =>
      context.read<AppState>().gateway.analytics(widget.kid.id, days: _days);

  Future<List<RevisitConcept>> _loadRevisits() =>
      context.read<AppState>().gateway.revisits(widget.kid.id);

  Future<List<WordSeed>> _loadWords() =>
      context.read<AppState>().gateway.words(widget.kid.id);

  void _reload() => setState(() {
    _future = _load();
    _revisits = _loadRevisits();
    _words = _loadWords();
  });

  void _setDays(int days) {
    if (days == _days) return;
    setState(() {
      _days = days;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RangeRow(days: _days, onChanged: _setDays),
        Expanded(
          child: FutureBuilder<Analytics>(
            future: _future,
            builder: (context, snap) {
              if (snap.hasError) {
                return LoadError(snap.error!, onRetry: _reload);
              }
              final a = snap.data;
              if (a == null) {
                return const Center(
                  child: CircularProgressIndicator(color: HgColors.mango),
                );
              }
              return FutureBuilder<List<RevisitConcept>>(
                future: _revisits,
                builder: (context, revisits) => FutureBuilder<List<WordSeed>>(
                  future: _words,
                  builder: (context, words) => FutureBuilder<HistoryInsight?>(
                    future: _history,
                    builder: (context, history) => _Body(
                      analytics: a,
                      kid: widget.kid,
                      // An empty list until it arrives, and an empty list
                      // if it never does: the rest of the screen is worth
                      // more than a spinner over it.
                      revisits: revisits.data ?? const [],
                      words: words.data ?? const [],
                      history: history.data,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
    if (widget.embedded) return body;
    return ParentScaffold(
      subtitle: 'Progress',
      title: widget.kid.nickname,
      actions: const [GilliMini(size: 48)],
      body: body,
    );
  }
}

/// 7 / 14 / 30 days, in one row above the content.
class _RangeRow extends StatelessWidget {
  const _RangeRow({required this.days, required this.onChanged});

  final int days;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Row(
        spacing: 10,
        children: [
          for (final d in _ProgressScreenState._ranges)
            Expanded(
              child: Material(
                color: d == days ? HgColors.mango : HgColors.white,
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => onChanged(d),
                  child: SizedBox(
                    height: 48,
                    child: Center(
                      child: Text(
                        '$d days',
                        style: HgText.body(
                          size: 16,
                          weight: FontWeight.w800,
                          color: d == days ? HgColors.ink : HgColors.brown,
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

class _Body extends StatelessWidget {
  const _Body({
    required this.analytics,
    required this.kid,
    this.revisits = const [],
    this.words = const [],
    this.history,
  });

  final Analytics analytics;
  final Kid kid;
  final List<RevisitConcept> revisits;
  final List<WordSeed> words;
  final HistoryInsight? history;

  bool get _preReader => kid.band == AgeBand.b4to6;

  /// What watching looked like before this app, from the parent's own export.
  ///
  /// The "before" number is measured: `unsubscribedShare` is the share of the
  /// imported history that came from channels the child does not follow. The
  /// "since" number is zero by construction rather than by measurement —
  /// nothing reaches a child from a channel the parent has not approved, and
  /// search, when it is on at all, only searches inside those.
  ///
  /// Nothing at all without an import. There is no honest thing to say about
  /// watching that happened before this app without the export that measured
  /// it, and a card with an invented percentage in it would be worse than no
  /// card in a product whose whole claim is that it does not guess.
  Widget? _watchedBefore() {
    final h = history;
    if (h == null || h.videos == 0) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: _Section(
        label: 'What they actually watched',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text(
              'From the ${h.videos} '
              '${h.videos == 1 ? "video" : "videos"} in the export you '
              'brought across. Only the totals were kept — the '
              'video-by-video list was read on your device and discarded.',
              style: HgText.body(size: 14, color: HgColors.brown),
            ),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Before HeyGilli: ',
                    style: HgText.body(
                      size: 15,
                      color: HgColors.ink,
                      weight: FontWeight.w800,
                    ),
                  ),
                  TextSpan(
                    text:
                        '${h.unsubscribedPercent}% of watching came from '
                        'channels not on the list.',
                    style: HgText.body(size: 15, color: HgColors.ink),
                  ),
                ],
              ),
            ),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Since: ',
                    style: HgText.body(
                      size: 15,
                      color: HgColors.green,
                      weight: FontWeight.w800,
                    ),
                  ),
                  TextSpan(
                    text:
                        '0%. Nothing reaches ${kid.nickname} from a channel '
                        'you have not approved.',
                    style: HgText.body(size: 15, color: HgColors.ink),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = analytics;
    final nothingYet = a.totals.sessions == 0;
    final hasWords =
        a.vocabulary.said.isNotEmpty || a.vocabulary.emerging.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        _Note(note: a.note),
        const SizedBox(height: 16),
        if (nothingYet)
          _Empty(days: a.days)
        else ...[
          _StatRow(analytics: a, preReader: _preReader),
          const SizedBox(height: 16),
          _Section(
            label: 'Minutes a day',
            child: DayColumnChart(
              data: _columns(a.daily),
              hint: 'Tap a bar for that day',
            ),
          ),
          ?_watchedBefore(),
          if (a.channels.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Section(
              label: 'Where the time went',
              child: HorizontalBars(
                rows: [
                  for (final c in a.channels)
                    BarRow(
                      label: c.title,
                      valueLabel: '${c.minutes} min',
                      value: c.minutes.toDouble(),
                      semantics:
                          '${c.title}, ${c.minutes} minutes, '
                          '${c.videos} ${c.videos == 1 ? 'video' : 'videos'}',
                    ),
                ],
              ),
            ),
          ],
          if (hasWords) ...[
            const SizedBox(height: 16),
            _Section(
              label: 'Words ${kid.nickname} said',
              child: WordChips(
                words: [for (final w in a.vocabulary.said) w.word],
                filled: true,
                empty: 'No words back yet.',
              ),
            ),
            if (a.vocabulary.emerging.isNotEmpty) ...[
              const SizedBox(height: 12),
              _Section(
                label: 'Heard, not said yet',
                child: WordChips(
                  words: [for (final w in a.vocabulary.emerging) w.word],
                  filled: false,
                  empty: '',
                ),
              ),
            ],
          ],
          if (a.needsAnotherLook.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Section(
              label: 'Worth another look',
              labelColor: HgColors.coral,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 10,
                children: [
                  for (final s in a.needsAnotherLook)
                    _ConceptLine(
                      concept: s.concept,
                      detail:
                          'Shaky on ${s.timesShaky} days, '
                          'last ${_shortDate(s.lastSeen)}',
                    ),
                ],
              ),
            ),
          ],
          if (words.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Section(
              label: 'Urdu words Gilli has offered',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 12,
                children: [
                  for (final w in words) _SeededWordLine(seed: w),
                  const SizedBox(height: 2),
                  Text(
                    // Both halves of the rule, because both are unusual
                    // enough that a parent would otherwise wonder.
                    'One new word a session at most, and only for something '
                    '${kid.nickname} has already got right in English. Gilli '
                    'says these itself: there is no Urdu voice in the cloud '
                    'service, so on a phone with no Urdu voice installed the '
                    'question is asked in English with no word offered.',
                    style: HgText.body(size: 13, color: HgColors.brown),
                  ),
                ],
              ),
            ),
          ],
          if (revisits.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Section(
              label: 'Coming back to these',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 10,
                children: [
                  for (final r in revisits)
                    _ConceptLine(
                      concept: r.concept,
                      detail: r.waiting
                          ? 'Shaky on ${r.timesShaky} days. Not been back to '
                                'it yet'
                          : 'Asked again ${r.askedAgain} '
                                '${r.askedAgain == 1 ? 'time' : 'times'} since',
                    ),
                  const SizedBox(height: 2),
                  Text(
                    // The whole point of the feature from the parent's side,
                    // and the one thing they cannot see for themselves: what
                    // this looks like from where their child is sitting.
                    'When one of these comes round again it is asked as an '
                    'ordinary question about whatever ${kid.nickname} is '
                    'watching that day, never as "remember when you got this '
                    'wrong". At most one a session, never the first question, '
                    "and nothing on ${kid.nickname}'s screen says it is a "
                    'repeat.',
                    style: HgText.body(size: 13, color: HgColors.brown),
                  ),
                ],
              ),
            ),
          ],
          if (!_preReader && a.concepts.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Section(
              label: 'What came up',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 10,
                children: [
                  for (final c in a.concepts.take(6))
                    _ConceptLine(concept: c.concept, detail: _conceptDetail(c)),
                ],
              ),
            ),
          ],
        ],
      ],
    );
  }

  List<ColumnDatum> _columns(List<AnalyticsDay> daily) {
    final n = daily.length;
    // Three ticks at most: the ends and the middle. More than that collides on
    // a phone once the window is 30 days.
    final ticks = {0, n ~/ 2, n - 1};
    return [
      for (var i = 0; i < n; i++)
        ColumnDatum(
          value: daily[i].minutes.toDouble(),
          valueLabel: '${daily[i].minutes} min',
          caption: '${_longDate(daily[i].date)}, ${_minutes(daily[i].minutes)}',
          semantics:
              '${_longDate(daily[i].date)}, ${_minutes(daily[i].minutes)}',
          tick: ticks.contains(i) ? _shortDate(daily[i].date) : null,
        ),
    ];
  }

  String _conceptDetail(ConceptStat c) {
    final bits = <String>[];
    if (c.understood > 0) bits.add('${c.understood} understood');
    if (c.shaky > 0) bits.add('${c.shaky} shaky');
    if (bits.isEmpty) bits.add('asked ${c.asked}x');
    return bits.join(', ');
  }
}

String _minutes(int m) => m == 1 ? '1 minute' : '$m minutes';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "2/9" for an axis tick.
String _shortDate(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? '' : '${d.day}/${d.month}';
}

/// "Tue 2 Sep" for a caption a parent reads.
String _longDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
}

/// The agent's note. `quiet` means nothing needs the parent today, so it is
/// deliberately small and grey rather than a card shouting for attention.
class _Note extends StatelessWidget {
  const _Note({required this.note});

  final AnalyticsNote note;

  @override
  Widget build(BuildContext context) {
    if (note.kind == 'quiet') {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Text(
          note.text,
          style: HgText.body(size: 16, color: HgColors.muted),
        ),
      );
    }
    final label = switch (note.kind) {
      'praise' => 'Going well',
      'watch' => 'Worth a look',
      _ => 'One thing to try',
    };
    return PCard(
      color: HgColors.teal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(label.toUpperCase(), style: HgText.label(color: HgColors.mango)),
          Text(
            note.text,
            style: HgText.display(
              size: 20,
              weight: FontWeight.w600,
              color: HgColors.cream,
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.days});

  final int days;

  @override
  Widget build(BuildContext context) {
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(
            'Nothing in the last $days days',
            style: HgText.display(size: 22, color: HgColors.ink),
          ),
          Text(
            'This fills up on its own once a video is watched with Gilli. '
            'Minutes, the words that come back, and what needs another look.',
            style: HgText.body(size: 16, color: HgColors.brown),
          ),
        ],
      ),
    );
  }
}

/// Three headline numbers. The third one depends on the band, because a
/// pre-reader's progress is vocabulary and an older kid's is comprehension.
class _StatRow extends StatelessWidget {
  const _StatRow({required this.analytics, required this.preReader});

  final Analytics analytics;
  final bool preReader;

  @override
  Widget build(BuildContext context) {
    final t = analytics.totals;
    final understood = analytics.concepts.fold<int>(
      0,
      (sum, c) => sum + c.understood,
    );
    return Row(
      spacing: 10,
      children: [
        _Stat(value: '${t.minutes}', label: 'minutes'),
        _Stat(
          value: t.asked == 0 ? '-' : '${t.answered}/${t.asked}',
          label: 'answered',
        ),
        if (preReader)
          _Stat(
            value: '${analytics.vocabulary.newThisWeek}',
            label: 'new words',
          )
        else
          _Stat(value: '$understood', label: 'understood'),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: PCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 2,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: HgText.display(size: 26, color: HgColors.ink),
              ),
            ),
            // A long single word ("UNDERSTOOD") must shrink, never break
            // across two lines mid-word.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                label.toUpperCase(),
                maxLines: 1,
                softWrap: false,
                style: HgText.label(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.label,
    required this.child,
    this.labelColor = HgColors.brown,
  });

  final String label;
  final Widget child;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text(label.toUpperCase(), style: HgText.label(color: labelColor)),
          child,
        ],
      ),
    );
  }
}

/// One seeded word: the term itself, what it means, and whether it has come
/// back yet. "Said it back" is the only thing here that counts as learning,
/// so it is the part in plain words rather than a number.
class _SeededWordLine extends StatelessWidget {
  const _SeededWordLine({required this.seed});

  final WordSeed seed;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Text(
          seed.term,
          textDirection: seed.language == 'ur'
              ? TextDirection.rtl
              : TextDirection.ltr,
          style: seed.language == 'ur'
              ? HgText.urdu(size: 22, color: HgColors.ink)
              : HgText.display(size: 20, color: HgColors.ink),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                seed.gloss,
                style: HgText.body(size: 16, color: HgColors.ink),
              ),
              Text(
                seed.emerging
                    ? 'Heard ${seed.timesHeard} '
                          '${seed.timesHeard == 1 ? 'time' : 'times'}, not '
                          'said back yet'
                    : 'Said it back ${seed.timesSaid} '
                          '${seed.timesSaid == 1 ? 'time' : 'times'}',
                style: HgText.body(size: 14, color: HgColors.brown),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConceptLine extends StatelessWidget {
  const _ConceptLine({required this.concept, required this.detail});

  final String concept;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(concept, style: HgText.body(size: 18, color: HgColors.ink)),
        Text(detail, style: HgText.body(size: 14, color: HgColors.brown)),
      ],
    );
  }
}
