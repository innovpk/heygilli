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
  const ProgressScreen({super.key, required this.kid});

  final Kid kid;

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  static const _ranges = [7, 14, 30];
  int _days = 14;
  late Future<Analytics> _future = _load();

  Future<Analytics> _load() =>
      context.read<AppState>().gateway.analytics(widget.kid.id, days: _days);

  void _reload() => setState(() => _future = _load());

  void _setDays(int days) {
    if (days == _days) return;
    setState(() {
      _days = days;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ParentScaffold(
      subtitle: 'Progress',
      title: widget.kid.nickname,
      actions: const [GilliMini(size: 48)],
      body: Column(
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
                return _Body(analytics: a, kid: widget.kid);
              },
            ),
          ),
        ],
      ),
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
  const _Body({required this.analytics, required this.kid});

  final Analytics analytics;
  final Kid kid;

  bool get _preReader => kid.band == AgeBand.b4to6;

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
