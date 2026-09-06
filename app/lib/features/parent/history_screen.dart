import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';
import 'progress_charts.dart';

/// What a child has actually been watching, from a Takeout export the parent
/// ticked history on (PROTOCOL "Watch history: opt-in, aggregate, discarded").
///
/// This screen exists for one number. `unsubscribed_share` is the difference
/// between a child watching the channels they chose and a child being fed by
/// the recommender, and a parent cannot see it anywhere else — YouTube does
/// not show it and the subscription list does not imply it.
///
/// Everything here is counts and channel names. There is no video title on
/// this screen because there is none in the product: the server counts the
/// file and discards it, titles included. The screen says so where a parent
/// would otherwise wonder, and offers the delete in the same place.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.kid});

  final Kid kid;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<HistoryInsight?> _future = _load();
  bool _deleting = false;
  String? _error;

  Future<HistoryInsight?> _load() =>
      context.read<AppState>().gateway.history(widget.kid.id);

  void _reload() => setState(() {
    _future = _load();
  });

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: HgColors.white,
        title: Text(
          'Delete this?',
          style: HgText.display(size: 22, color: HgColors.ink),
        ),
        content: Text(
          'The counts go for good. Getting them back means exporting from '
          'Takeout again and ticking the box again.',
          style: HgText.body(size: 15, color: HgColors.brown),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Keep it',
              style: HgText.body(size: 15, color: HgColors.brown),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Delete',
              style: HgText.body(size: 15, color: HgColors.coral),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      await context.read<AppState>().gateway.deleteHistory(widget.kid.id);
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _future = Future.value(null);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _deleting = false;
          _error = 'Could not delete: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ParentScaffold(
      title: 'What they actually watched',
      subtitle: widget.kid.nickname.toUpperCase(),
      body: FutureBuilder<HistoryInsight?>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return LoadError(snap.error!, onRetry: _reload);
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(color: HgColors.mango),
            );
          }
          final insight = snap.data;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              if (insight == null)
                _NeverOptedIn(name: widget.kid.nickname)
              else
                ..._insight(insight),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: HgText.body(size: 14, color: HgColors.coral),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  List<Widget> _insight(HistoryInsight insight) {
    final name = widget.kid.nickname;
    return [
      _Headline(insight: insight, name: name),
      const SizedBox(height: 12),
      _Counted(insight: insight),
      if (insight.topChannels.isNotEmpty) ...[
        const SizedBox(height: 12),
        _TopChannels(insight: insight),
      ],
      if (insight.hasHours) ...[
        const SizedBox(height: 12),
        _WhenCard(insight: insight),
      ],
      if (insight.summary.isNotEmpty) ...[
        const SizedBox(height: 12),
        PCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 6,
            children: [
              Text('WHAT THE NUMBERS SHOW', style: HgText.label()),
              Text(
                insight.summary,
                style: HgText.body(size: 15, color: HgColors.ink),
              ),
              Text(
                // The summary is written from the aggregate and nothing else.
                // Said plainly, because a parent reading a paragraph about
                // their child deserves to know what it could be based on.
                'Written from the counts above. It says nothing about what '
                '$name is like, because nothing here could tell it that.',
                style: HgText.body(size: 13, color: HgColors.muted),
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 12),
      _WhatWasKept(deleting: _deleting, onDelete: _deleting ? null : _delete),
    ];
  }
}

/// The default state, and the one most households will be in.
class _NeverOptedIn extends StatelessWidget {
  const _NeverOptedIn({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(
            'Nothing here',
            style: HgText.display(size: 22, color: HgColors.ink),
          ),
          Text(
            "HeyGilli has not read $name's watch history, because it does not "
            'unless you ask it to. A Takeout import reads the channel lists '
            'and leaves the history on your phone.',
            style: HgText.body(size: 15, color: HgColors.brown),
          ),
          Text(
            'If you want it, tick "Also count what they actually watched" the '
            'next time you import an export. It counts the file and then '
            'deletes it, video titles included.',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
        ],
      ),
    );
  }
}

/// `unsubscribed_share`, which is the reason this screen exists.
class _Headline extends StatelessWidget {
  const _Headline({required this.insight, required this.name});

  final HistoryInsight insight;
  final String name;

  @override
  Widget build(BuildContext context) {
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${insight.unsubscribedPercent}%',
            style: HgText.display(size: 64, color: HgColors.ink),
          ),
          const SizedBox(height: 4),
          Text(
            'of what was watched came from channels $name does not follow',
            style: HgText.display(size: 22, color: HgColors.ink),
          ),
          const SizedBox(height: 10),
          Text(
            'The other ${insight.subscribedPercent}% came from channels they '
            'subscribed to. The higher the top number, the more of their '
            "watching was chosen by YouTube's recommendations rather than by "
            'anyone in this house.',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
          const SizedBox(height: 8),
          Text(
            // Information, not an instruction. What to do about it is the
            // parent's, as everything else here is.
            'It is a number, not a verdict. Plenty of it may be fine.',
            style: HgText.body(size: 13, color: HgColors.muted),
          ),
        ],
      ),
    );
  }
}

class _Counted extends StatelessWidget {
  const _Counted({required this.insight});

  final HistoryInsight insight;

  @override
  Widget build(BuildContext context) {
    final span = [
      insight.firstWatched,
      insight.lastWatched,
    ].where((d) => d.isNotEmpty).join(' to ');
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          Text('COUNTED', style: HgText.label()),
          Text(
            '${_thousands(insight.videos)} '
            '${insight.videos == 1 ? 'video' : 'videos'}',
            style: HgText.display(size: 28, color: HgColors.ink),
          ),
          if (span.isNotEmpty)
            Text(span, style: HgText.body(size: 14, color: HgColors.brown)),
        ],
      ),
    );
  }
}

class _TopChannels extends StatelessWidget {
  const _TopChannels({required this.insight});

  final HistoryInsight insight;

  @override
  Widget build(BuildContext context) {
    final unfollowed = insight.topChannels.where((c) => !c.subscribed).length;
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text('MOST WATCHED CHANNELS', style: HgText.label()),
          HorizontalBars(
            rows: [
              for (final c in insight.topChannels)
                BarRow(
                  label: c.title,
                  value: c.videos.toDouble(),
                  valueLabel: c.subscribed
                      ? '${c.videos}'
                      : '${c.videos} · not followed',
                  semantics:
                      '${c.title}, ${c.videos} videos, '
                      '${c.subscribed ? 'followed' : 'not followed'}',
                ),
            ],
          ),
          if (unfollowed > 0)
            Text(
              '$unfollowed of these ${unfollowed == 1 ? 'is' : 'are'} not in '
              'the subscription list. Adding one is a channel you approve, on '
              'the kid page; nothing here changes what is allowed.',
              style: HgText.body(size: 13, color: HgColors.muted),
            ),
        ],
      ),
    );
  }
}

class _WhenCard extends StatelessWidget {
  const _WhenCard({required this.insight});

  final HistoryInsight insight;

  @override
  Widget build(BuildContext context) {
    final busiest = insight.busiestHour;
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text('WHEN THE WATCHING HAPPENS', style: HgText.label()),
          DayColumnChart(
            data: [
              for (var h = 0; h < insight.byHour.length; h++)
                ColumnDatum(
                  value: insight.byHour[h].toDouble(),
                  valueLabel: '${insight.byHour[h]}',
                  caption: '${_hour(h)} - ${insight.byHour[h]} videos',
                  semantics: '${_hour(h)}, ${insight.byHour[h]} videos',
                  tick: h % 6 == 0 ? _hour(h) : null,
                ),
            ],
            hint: busiest == null
                ? null
                : 'Busiest at ${_hour(busiest)}. Tap a bar for its hour.',
          ),
          Text(
            // The export's own clock, not the phone's: a family that moved or
            // travelled would otherwise read the wrong hours as fact.
            'Hours are the ones in the export, in its own time zone.',
            style: HgText.body(size: 13, color: HgColors.muted),
          ),
        ],
      ),
    );
  }
}

/// The terms, restated after the fact, next to the way out of them.
class _WhatWasKept extends StatelessWidget {
  const _WhatWasKept({required this.deleting, required this.onDelete});

  final bool deleting;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return PCard(
      color: const Color(0xFFF2F7EE),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Row(
            spacing: 12,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lock_outline_rounded, color: HgColors.green),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: [
                    Text(
                      'What was kept',
                      style: HgText.body(size: 16, color: HgColors.ink),
                    ),
                    Text(
                      'The counts on this page, and nothing else. The history '
                      'file was read once, counted and deleted, and every '
                      'video title in it went with it. No video title was '
                      'stored or sent to a model; only channel names were.',
                      style: HgText.body(size: 14, color: HgColors.brown),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(
            height: 48,
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onDelete,
              icon: deleting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_outline_rounded, size: 20),
              style: OutlinedButton.styleFrom(
                foregroundColor: HgColors.coral,
                side: const BorderSide(color: HgColors.line, width: 2),
                shape: const StadiumBorder(),
              ),
              label: Text(
                'Delete these counts',
                style: HgText.body(size: 15, color: HgColors.coral),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "1,284". Thousands separated by hand: a four-figure count read as one
/// unbroken run of digits is the kind of number a parent misreads.
String _thousands(int n) {
  final digits = '$n';
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// 0-23 as a parent reads a clock.
String _hour(int h) {
  if (h == 0) return '12am';
  if (h == 12) return '12pm';
  return h < 12 ? '${h}am' : '${h - 12}pm';
}
