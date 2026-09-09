import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/analytics.dart';
import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

/// What happened today, led by the thing a parent actually came for.
///
/// This tab used to be four cards that each said "there is something behind
/// me": today's digest, progress, history, hidden. A parent who opened their
/// child and wanted the one sentence Gilli wrote had to go one screen deeper
/// to read it, every evening, and the screen they landed on was the only part
/// of the product that is genuinely theirs.
///
/// So the note is the page now, drawn as the taped-up note it is on the landing
/// page, and everything else — how long, from where, what is waiting, what the
/// rules currently say — sits around it as context rather than as doors.
class KidOverview extends StatefulWidget {
  const KidOverview({
    super.key,
    required this.kid,
    required this.onSeeProgress,
    required this.onChangeRules,
    required this.onSeeInbox,
  });

  final Kid kid;

  /// The two tabs this page points at. Passed in rather than pushed from here,
  /// because on this screen they are tabs and not routes — sending a parent
  /// onto a new page to change a break length, then leaving them to find their
  /// way back, is what the tabs were for.
  final VoidCallback onSeeProgress;
  final VoidCallback onChangeRules;
  final VoidCallback onSeeInbox;

  @override
  State<KidOverview> createState() => _KidOverviewState();
}

class _KidOverviewState extends State<KidOverview> {
  late Future<_Overview> _data = _load();

  Future<_Overview> _load() async {
    final gateway = context.read<AppState>().gateway;
    final today = DateTime.now().toIso8601String().split('T').first;
    // Three calls, in parallel: the note, the week, and what is waiting. In
    // series this screen took as long as the slowest gateway round trip times
    // three, which on a cold free-tier dyno is most of a minute.
    final results = await Future.wait([
      gateway.digest(widget.kid.id, today).then<Object?>((d) => d),
      gateway.analytics(widget.kid.id, days: 7).then<Object?>((a) => a),
      gateway.inbox().then<Object?>((i) => i),
    ]);
    final waiting = (results[2]! as List<ParentPrompt>)
        .where((p) => p.kidId == widget.kid.id)
        .toList();
    return _Overview(
      digest: results[0]! as Digest,
      analytics: results[1]! as Analytics,
      waiting: waiting,
    );
  }

  void _reload() => setState(() => _data = _load());

  @override
  Widget build(BuildContext context) => FutureBuilder<_Overview>(
    future: _data,
    builder: (context, snap) {
      if (snap.hasError) {
        return _Retry(error: '${snap.error}', onRetry: _reload);
      }
      if (!snap.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final data = snap.data!;
      return LayoutBuilder(
        builder: (context, constraints) {
          // The note wants to be read, and a note set across 1100px of window
          // is not a note. Two columns once there is room for the right one to
          // be a real column rather than a gutter.
          final twoUp = constraints.maxWidth >= 860;
          final left = [
            _TonightsNote(kid: widget.kid, digest: data.digest),
            const SizedBox(height: 16),
            _StatTiles(kid: widget.kid, data: data),
            const SizedBox(height: 16),
            _WhereTheTimeWent(
              channels: data.analytics.channels,
              onSeeProgress: widget.onSeeProgress,
            ),
          ];
          final right = [
            _WaitingForYou(
              kid: widget.kid,
              waiting: data.waiting,
              onDecided: _reload,
              onSeeAll: widget.onSeeInbox,
            ),
            const SizedBox(height: 16),
            _RulesAtAGlance(
              kid: widget.kid,
              channels: data.analytics.channels.length,
              onChange: widget.onChangeRules,
            ),
          ];
          if (!twoUp) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
              children: [...left, const SizedBox(height: 16), ...right],
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 20,
              children: [
                Expanded(flex: 12, child: Column(children: left)),
                Expanded(flex: 8, child: Column(children: right)),
              ],
            ),
          );
        },
      );
    },
  );
}

class _Overview {
  const _Overview({
    required this.digest,
    required this.analytics,
    required this.waiting,
  });

  final Digest digest;
  final Analytics analytics;
  final List<ParentPrompt> waiting;
}

/// The bedtime note, drawn as a note: paper, a strip of tape, and a degree of
/// tilt. It is the one thing in the parent app that is not a readout.
class _TonightsNote extends StatelessWidget {
  const _TonightsNote({required this.kid, required this.digest});

  final Kid kid;
  final Digest digest;

  static const _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  bool get _hasSomethingToSay =>
      digest.understood.isNotEmpty ||
      digest.shaky.isNotEmpty ||
      digest.wordsSaid.isNotEmpty ||
      digest.dinnerPrompt.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final weekday = _weekdays[DateTime.now().weekday - 1];
    return Transform.rotate(
      // Barely off true. Enough that the eye reads paper rather than a panel,
      // little enough that the text is not annoying to read.
      angle: -0.0105,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: HgColors.white,
          borderRadius: BorderRadius.circular(6),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F1E3A34),
              blurRadius: 30,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topCenter,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(30, 28, 30, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "TONIGHT'S NOTE · ${weekday.toUpperCase()}",
                    style: HgText.label(color: HgColors.mango),
                  ),
                  const SizedBox(height: 12),
                  if (_hasSomethingToSay)
                    ..._filled(context)
                  else
                    ..._empty(context),
                ],
              ),
            ),
            Positioned(
              top: -11,
              child: Transform.rotate(
                angle: -0.052,
                child: Container(
                  width: 90,
                  height: 26,
                  color: const Color(0x73B8452A),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _filled(BuildContext context) {
    final lines = <Widget>[];
    if (digest.isPreReader) {
      if (digest.wordsSaid.isNotEmpty) {
        lines.add(
          _NoteLine(
            label: 'Said today:',
            labelColour: HgColors.green,
            body: digest.wordsSaid.join(', '),
          ),
        );
      }
      if (digest.wordsHeard.isNotEmpty) {
        lines.add(
          _NoteLine(
            label: 'Heard, not said yet:',
            labelColour: HgColors.mango,
            body: digest.wordsHeard.join(', '),
          ),
        );
      }
    } else {
      if (digest.understood.isNotEmpty) {
        lines.add(
          _NoteLine(
            label: 'Understood:',
            labelColour: HgColors.green,
            body: digest.understood.join(', '),
          ),
        );
      }
      if (digest.shaky.isNotEmpty) {
        lines.add(
          _NoteLine(
            label: 'Still shaky:',
            labelColour: HgColors.mango,
            body: digest.shaky.join(', '),
          ),
        );
      }
    }
    if (digest.dinnerPrompt.trim().isNotEmpty) {
      lines.add(
        _NoteLine(
          label: 'Ask at dinner:',
          labelColour: HgColors.ink,
          body: '"${digest.dinnerPrompt.trim()}"',
        ),
      );
    }
    return [
      ...lines,
      const SizedBox(height: 10),
      Text(
        digest.isPreReader
            ? 'A word moves from heard to said by being said more than once, '
                  'so the same ones come back.'
            : 'A shaky concept comes back in a later video, never as a retest.',
        style: HgText.body(size: 13, color: HgColors.brown),
      ),
    ];
  }

  /// Not an error, and not "no data". A quiet day is a real answer, and the
  /// reason there is nothing to say is usually that nothing was long enough to
  /// pause in — which is worth telling a parent rather than leaving them to
  /// wonder whether the app is broken.
  List<Widget> _empty(BuildContext context) => [
    Text(
      'Nothing to report yet.',
      style: HgText.display(size: 26, color: HgColors.ink),
    ),
    const SizedBox(height: 8),
    Text(
      digest.videos == 0
          ? '${kid.nickname} has not watched anything today. The note fills in '
                'as the day goes.'
          : '${kid.nickname} watched ${digest.minutes} '
                '${digest.minutes == 1 ? "minute" : "minutes"} across '
                '${digest.videos} ${digest.videos == 1 ? "video" : "videos"}. '
                'No question came up in that time — Gilli waits for a natural '
                'pause, and short clips rarely have one.',
      style: HgText.body(size: 15, color: HgColors.ink),
    ),
  ];
}

class _NoteLine extends StatelessWidget {
  const _NoteLine({
    required this.label,
    required this.labelColour,
    required this.body,
  });

  final String label;
  final Color labelColour;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: HgText.body(
              size: 17,
              color: labelColour,
              weight: FontWeight.w800,
            ),
          ),
          TextSpan(
            text: body,
            style: HgText.body(size: 17, color: HgColors.ink),
          ),
        ],
      ),
    ),
  );
}

class _StatTiles extends StatelessWidget {
  const _StatTiles({required this.kid, required this.data});

  final Kid kid;
  final _Overview data;

  @override
  Widget build(BuildContext context) {
    final d = data.digest;
    return Row(
      spacing: 12,
      children: [
        Expanded(
          child: _Tile(value: '${d.minutes}', label: 'Minutes today'),
        ),
        Expanded(
          child: _Tile(value: '${d.videos}', label: 'Videos'),
        ),
        Expanded(
          child: _Tile(
            // A dash, not a nought: on a day with no questions "0 answered"
            // reads as a child who would not answer, and the truth is that
            // nothing was asked.
            value: d.asked == 0 ? '–' : '${d.answered}',
            label: 'Answered',
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
    decoration: BoxDecoration(
      color: HgColors.white,
      borderRadius: BorderRadius.circular(14),
      boxShadow: const [
        BoxShadow(
          color: Color(0x141E3A34),
          blurRadius: 18,
          offset: Offset(0, 6),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: HgText.display(size: 36, color: HgColors.ink)),
        const SizedBox(height: 2),
        Text(label, style: HgText.label(color: HgColors.brown)),
      ],
    ),
  );
}

class _WhereTheTimeWent extends StatelessWidget {
  const _WhereTheTimeWent({
    required this.channels,
    required this.onSeeProgress,
  });

  final List<ChannelMinutes> channels;
  final VoidCallback onSeeProgress;

  @override
  Widget build(BuildContext context) {
    final top = channels.where((c) => c.minutes > 0).toList()
      ..sort((a, b) => b.minutes.compareTo(a.minutes));
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Where the time went',
            style: HgText.display(size: 22, color: HgColors.ink),
          ),
          const SizedBox(height: 2),
          Text(
            'Last 7 days',
            style: HgText.body(size: 13, color: HgColors.brown),
          ),
          const SizedBox(height: 14),
          if (top.isEmpty)
            Text(
              'Nothing watched this week.',
              style: HgText.body(size: 15, color: HgColors.brown),
            )
          else
            for (final channel in top.take(5))
              _ChannelBar(channel: channel, of: top.first.minutes),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onSeeProgress,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                'See progress',
                style: HgText.body(size: 14, color: HgColors.mango),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelBar extends StatelessWidget {
  const _ChannelBar({required this.channel, required this.of});

  final ChannelMinutes channel;

  /// The busiest channel's minutes. Bars are relative to the top one rather
  /// than to the total, so a week split evenly across four channels still
  /// draws four visible bars instead of four short ones.
  final int of;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                channel.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HgText.body(size: 14, color: HgColors.ink),
              ),
            ),
            Text(
              '${channel.minutes} min',
              style: HgText.body(size: 13, color: HgColors.brown),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: of == 0 ? 0 : (channel.minutes / of).clamp(0.0, 1.0),
            minHeight: 10,
            backgroundColor: HgColors.cream,
            valueColor: const AlwaysStoppedAnimation(HgColors.mango),
          ),
        ),
      ],
    ),
  );
}

/// The one dark card on the parent side, because it is the one thing on this
/// page that is asking rather than telling.
class _WaitingForYou extends StatefulWidget {
  const _WaitingForYou({
    required this.kid,
    required this.waiting,
    required this.onDecided,
    required this.onSeeAll,
  });

  final Kid kid;
  final List<ParentPrompt> waiting;
  final VoidCallback onDecided;
  final VoidCallback onSeeAll;

  @override
  State<_WaitingForYou> createState() => _WaitingForYouState();
}

class _WaitingForYouState extends State<_WaitingForYou> {
  final _busy = <String>{};

  Future<void> _decide(ParentPrompt prompt, String decision) async {
    setState(() => _busy.add(prompt.id));
    final state = context.read<AppState>();
    try {
      await state.gateway.decide(prompt.id, decision);
      state.waitingDecided();
      if (mounted) widget.onDecided();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy.remove(prompt.id));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save that: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: HgColors.teal,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Waiting for you',
          // Rust is 2.2:1 on pine; this is the step that reads on it.
          style: HgText.display(size: 22, color: HgColors.accentTint),
        ),
        const SizedBox(height: 2),
        Text(
          widget.waiting.isEmpty
              ? 'Nothing borderline this week'
              : '${widget.waiting.length} to decide',
          style: HgText.body(size: 13, color: HgColors.sky),
        ),
        const SizedBox(height: 16),
        if (widget.waiting.isEmpty)
          Text(
            'Everything new from ${widget.kid.nickname}’s channels fit '
            'your answers.',
            style: HgText.body(size: 15, color: HgColors.cream),
          )
        else
          for (final prompt in widget.waiting.take(3))
            _WaitingItem(
              prompt: prompt,
              busy: _busy.contains(prompt.id),
              onDecide: (d) => _decide(prompt, d),
            ),
        if (widget.waiting.length > 3) ...[
          const SizedBox(height: 4),
          TextButton(
            onPressed: widget.onSeeAll,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'See all ${widget.waiting.length} in the inbox',
              style: HgText.body(size: 14, color: HgColors.accentTint),
            ),
          ),
        ],
      ],
    ),
  );
}

class _WaitingItem extends StatelessWidget {
  const _WaitingItem({
    required this.prompt,
    required this.busy,
    required this.onDecide,
  });

  final ParentPrompt prompt;
  final bool busy;
  final ValueChanged<String> onDecide;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          prompt.title.isEmpty ? prompt.channelTitle : prompt.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: HgText.body(
            size: 14,
            color: HgColors.white,
            weight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          prompt.reason,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: HgText.body(size: 13, color: HgColors.sky),
        ),
        const SizedBox(height: 10),
        if (busy)
          const SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          )
        else
          // Wrap, not Row: this card is a column on a phone and a third of the
          // window on a desktop, and "Show it"/"Not this one" side by side do
          // not fit the narrow end of that.
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: () => onDecide('approve'),
                style: FilledButton.styleFrom(
                  backgroundColor: HgColors.green,
                  foregroundColor: HgColors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  shape: const StadiumBorder(),
                ),
                child: Text(
                  'Show it',
                  style: HgText.display(size: 16, color: HgColors.white),
                ),
              ),
              OutlinedButton(
                onPressed: () => onDecide('hide'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: HgColors.cream,
                  side: const BorderSide(color: HgColors.sky),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  shape: const StadiumBorder(),
                ),
                child: Text(
                  'Not this one',
                  style: HgText.display(size: 16, color: HgColors.cream),
                ),
              ),
            ],
          ),
      ],
    ),
  );
}

class _RulesAtAGlance extends StatelessWidget {
  const _RulesAtAGlance({
    required this.kid,
    required this.channels,
    required this.onChange,
  });

  final Kid kid;
  final int channels;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) => PCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Rules in one glance',
          style: HgText.display(size: 22, color: HgColors.ink),
        ),
        const SizedBox(height: 12),
        _Row('Watching each day', '${kid.dailyMinutes} min'),
        _Row('Break every', '${kid.breakAfterMinutes} min'),
        _Row('Search', kid.searchEnabled ? 'On' : 'Off'),
        _Row('Channels approved', '$channels'),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: onChange,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Change the rules',
              style: HgText.body(size: 14, color: HgColors.mango),
            ),
          ),
        ),
      ],
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
        ),
        Text(
          value,
          style: HgText.body(
            size: 14,
            color: HgColors.ink,
            weight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class _Retry extends StatelessWidget {
  const _Retry({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          Text(
            'Could not load today',
            style: HgText.display(size: 22, color: HgColors.ink),
          ),
          Text(
            error,
            textAlign: TextAlign.center,
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}
