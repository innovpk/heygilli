import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/admin.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';

/// The service's own overview: who has tried HeyGilli, and how far they got.
///
/// Reachable from the rail only when the gateway says this household signed in
/// with an admin's Google account. The gateway checks again on every request,
/// so a link that somehow showed would still get nothing.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  late Future<AdminOverview> _data = _load();

  /// Likely tests are hidden until asked for: they are most of the rows, and
  /// the question is almost always "how many real families".
  bool _showTests = false;

  Future<AdminOverview> _load() =>
      context.read<AppState>().gateway.adminOverview();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AdminOverview>(
      future: _data,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                Text(
                  'Could not load the overview.',
                  style: HgText.body(size: 16, color: HgColors.ink),
                ),
                TextButton(
                  onPressed: () => setState(() => _data = _load()),
                  child: const Text('Try again'),
                ),
              ],
            ),
          );
        }
        final o = snap.data;
        if (o == null) return const Center(child: CircularProgressIndicator());
        final rows = [
          for (final h in o.households)
            if (_showTests || !h.likelyTest) h,
        ];
        return RefreshIndicator(
          onRefresh: () async {
            final next = _load();
            setState(() => _data = next);
            await next;
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _Stat(
                    'Real families',
                    o.total('real'),
                    'not you, not a likely test',
                  ),
                  _Stat(
                    'Real, and watched',
                    o.total('real_watched'),
                    'at least one video with Gilli',
                  ),
                  _Stat(
                    'Households',
                    o.total('households'),
                    'everyone, tests included',
                  ),
                  _Stat('With Google', o.total('google'), 'signed in with it'),
                  _Stat(
                    'Sessions',
                    o.total('sessions'),
                    'videos watched with Gilli',
                  ),
                  _Stat(
                    'Likely tests',
                    o.total('likely_tests'),
                    'a guess, from the names',
                  ),
                ],
              ),
              if (o.perDay.isNotEmpty) ...[
                const SizedBox(height: 28),
                Text('Sessions per day', style: HgText.display(size: 20)),
                const SizedBox(height: 10),
                _PerDay(o.perDay),
              ],
              const SizedBox(height: 28),
              const _FeedbackSection(),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: Text('Households', style: HgText.display(size: 20)),
                  ),
                  Text(
                    'Show likely tests',
                    style: HgText.body(size: 14, color: HgColors.brown),
                  ),
                  Switch(
                    key: const Key('admin-show-tests'),
                    value: _showTests,
                    onChanged: (v) => setState(() => _showTests = v),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (final h in rows) _HouseholdRow(h),
            ],
          ),
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.hint);

  final String label;
  final int value;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 180,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: HgColors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          Text('$value', style: HgText.display(size: 32, color: HgColors.ink)),
          Text(label, style: HgText.body(size: 15, color: HgColors.ink)),
          Text(hint, style: HgText.body(size: 12, color: HgColors.muted)),
        ],
      ),
    );
  }
}

/// One bar a day, oldest first.
class _PerDay extends StatelessWidget {
  const _PerDay(this.days);

  final List<({String date, int sessions})> days;

  @override
  Widget build(BuildContext context) {
    final most = days.fold<int>(1, (m, d) => d.sessions > m ? d.sessions : m);
    return SizedBox(
      height: 150,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final d in days)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                spacing: 4,
                children: [
                  Text(
                    '${d.sessions}',
                    style: HgText.body(size: 12, color: HgColors.ink),
                  ),
                  Container(
                    width: 28,
                    height: 90 * d.sessions / most,
                    decoration: BoxDecoration(
                      color: HgColors.mango,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  Text(
                    d.date.length >= 10 ? d.date.substring(5, 10) : d.date,
                    style: HgText.body(size: 11, color: HgColors.muted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HouseholdRow extends StatelessWidget {
  const _HouseholdRow(this.h);

  final AdminHousehold h;

  static String _when(String? iso) => iso == null
      ? '—'
      : iso.replaceFirst('T', ' ').padRight(16).substring(0, 16);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: HgColors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          Row(
            spacing: 8,
            children: [
              Expanded(
                child: Text(
                  h.kids.isEmpty ? 'No child added' : h.kids.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HgText.body(size: 16, color: HgColors.ink),
                ),
              ),
              if (h.you) const _Tag('You'),
              if (h.google) const _Tag('Google'),
              if (h.likelyTest) const _Tag('Likely test'),
            ],
          ),
          Text(
            'First seen ${_when(h.firstSeen)} · last active ${_when(h.lastActive)}'
            ' · ${h.sessions} ${h.sessions == 1 ? 'session' : 'sessions'}'
            ' · ${h.minutesWatched} min',
            style: HgText.body(size: 13, color: HgColors.brown),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: HgColors.cream,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: HgText.body(size: 12, color: HgColors.ink)),
    );
  }
}

/// What parents sent from "Send feedback", newest first, with a tick for the
/// ones acted on.
class _FeedbackSection extends StatefulWidget {
  const _FeedbackSection();

  @override
  State<_FeedbackSection> createState() => _FeedbackSectionState();
}

class _FeedbackSectionState extends State<_FeedbackSection> {
  List<FeedbackItem>? _items;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await context.read<AppState>().gateway.adminFeedback();
      if (mounted) {
        setState(() {
          _items = items;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _set(FeedbackItem f, bool done) => setState(
    () => _items = [
      for (final i in _items!)
        i.id == f.id && i.household == f.household ? i.copyWith(done: done) : i,
    ],
  );

  /// Ticked straight away, and put back if the gateway says no.
  Future<void> _toggle(FeedbackItem f, bool done) async {
    _set(f, done);
    try {
      await context.read<AppState>().gateway.setFeedbackDone(
        f.household,
        f.id,
        done,
      );
    } catch (_) {
      if (mounted) _set(f, !done);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final open = items?.where((f) => !f.done).length ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Text(
          items == null ? 'Feedback' : 'Feedback · $open open',
          style: HgText.display(size: 20),
        ),
        if (_failed)
          Text(
            'Could not load feedback.',
            style: HgText.body(size: 14, color: HgColors.brown),
          )
        else if (items == null)
          const LinearProgressIndicator()
        else if (items.isEmpty)
          Text(
            'Nothing yet. It appears here when a parent uses "Send feedback".',
            style: HgText.body(size: 14, color: HgColors.brown),
          )
        else ...[
          for (final f in items)
            _FeedbackRow(f, onDone: (done) => _toggle(f, done)),
        ],
      ],
    );
  }
}

class _FeedbackRow extends StatelessWidget {
  const _FeedbackRow(this.f, {required this.onDone});

  final FeedbackItem f;
  final ValueChanged<bool> onDone;

  @override
  Widget build(BuildContext context) {
    final from = [
      _HouseholdRow._when(f.createdAt.isEmpty ? null : f.createdAt),
      f.household.length > 8 ? f.household.substring(0, 8) : f.household,
      if (f.where.isNotEmpty) 'from the ${f.where}',
      if (f.contact.isNotEmpty) 'reply to ${f.contact}',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 12),
      decoration: BoxDecoration(
        color: HgColors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            key: Key('feedback-done-${f.id}'),
            value: f.done,
            onChanged: (v) => onDone(v ?? false),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(
                    f.text,
                    style: HgText.body(
                      size: 15,
                      color: f.done ? HgColors.muted : HgColors.ink,
                    ),
                  ),
                  Text(
                    from,
                    style: HgText.body(size: 12, color: HgColors.brown),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
