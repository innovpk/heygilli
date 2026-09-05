import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

/// End-of-day card. Two shapes (SPEC 6.5): a vocabulary log for pre-readers,
/// a comprehension report for 7+. Mirrors design/PhoneDigest*.dc.html.
class DigestScreen extends StatefulWidget {
  const DigestScreen({super.key, required this.kid});
  final Kid kid;

  @override
  State<DigestScreen> createState() => _DigestScreenState();
}

class _DigestScreenState extends State<DigestScreen> {
  late Future<Digest> _digest = _load();

  void _reload() => setState(() {
    _digest = _load();
  });

  Future<Digest> _load() =>
      context.read<AppState>().gateway.digest(widget.kid.id, _isoToday());

  Future<void> _runNow() async {
    final gateway = context.read<AppState>().gateway;
    setState(() {
      _digest = gateway.runDigest(widget.kid.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ParentScaffold(
      subtitle: 'Today  |  ${_weekday(DateTime.now())}',
      title: widget.kid.nickname,
      actions: [
        IconButton(
          onPressed: _runNow,
          tooltip: 'Run the Digest agent now',
          icon: const Icon(Icons.refresh_rounded, color: HgColors.ink),
        ),
        const GilliMini(size: 48),
      ],
      body: FutureBuilder<Digest>(
        future: _digest,
        builder: (context, snap) {
          if (snap.hasError) {
            return LoadError(snap.error!, onRetry: _reload);
          }
          final d = snap.data;
          if (d == null) {
            return const Center(
              child: CircularProgressIndicator(color: HgColors.mango),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              _StatsRow(digest: d),
              const SizedBox(height: 16),
              if (d.isPreReader)
                _PreReaderBody(digest: d, kid: widget.kid)
              else
                _OlderBody(digest: d),
            ],
          );
        },
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.digest});
  final Digest digest;

  @override
  Widget build(BuildContext context) {
    final d = digest;
    return Row(
      spacing: 10,
      children: [
        _Stat(value: '${d.minutes}', label: 'minutes'),
        _Stat(value: '${d.videos}', label: 'videos'),
        if (d.isPreReader)
          _Stat(value: '${d.asked}', label: 'questions')
        else
          _Stat(
            value: '${d.answered}',
            suffix: '/${d.asked}',
            label: 'answered',
          ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.suffix});
  final String value;
  final String? suffix;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: PCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                text: value,
                style: HgText.display(size: 26, color: HgColors.ink),
                children: [
                  if (suffix != null)
                    TextSpan(
                      text: suffix,
                      style: HgText.display(size: 16, color: HgColors.brown),
                    ),
                ],
              ),
            ),
            Text(label.toUpperCase(), style: HgText.label()),
          ],
        ),
      ),
    );
  }
}

/// Words said (mango chips), heard but not said yet (outlined), try today.
class _PreReaderBody extends StatelessWidget {
  const _PreReaderBody({required this.digest, required this.kid});
  final Digest digest;
  final Kid kid;

  @override
  Widget build(BuildContext context) {
    final d = digest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        _Section(
          label: 'Words ${kid.nickname} said',
          child: _Chips(
            words: d.wordsSaid,
            filled: true,
            empty: 'No words yet today.',
          ),
        ),
        _Section(
          label: 'Heard, not said yet',
          child: _Chips(
            words: d.wordsHeard,
            filled: false,
            empty: 'Nothing pending.',
          ),
        ),
        if (d.dinnerPrompt.isNotEmpty)
          _DarkCard(label: 'Try today', text: d.dinnerPrompt),
      ],
    );
  }
}

/// Understood, shaky, ask at dinner.
class _OlderBody extends StatelessWidget {
  const _OlderBody({required this.digest});
  final Digest digest;

  @override
  Widget build(BuildContext context) {
    final d = digest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        _Section(
          label: 'Understood',
          labelColor: HgColors.green,
          child: _Lines(d.understood, empty: 'Nothing scored yet today.'),
        ),
        _Section(
          label: 'Shaky',
          labelColor: const Color(0xFFC9401C),
          child: _Lines(d.shaky, empty: 'Nothing shaky. Nice.'),
        ),
        if (d.dinnerPrompt.isNotEmpty)
          _DarkCard(label: 'Ask at dinner', text: '"${d.dinnerPrompt}"'),
      ],
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
  final Color labelColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text(label.toUpperCase(), style: HgText.label(color: labelColor)),
          child,
        ],
      ),
    );
  }
}

class _Chips extends StatelessWidget {
  const _Chips({
    required this.words,
    required this.filled,
    required this.empty,
  });
  final List<String> words;
  final bool filled;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (words.isEmpty) {
      return Text(empty, style: HgText.body(color: HgColors.muted));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final w in words)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: filled ? HgColors.mango : null,
              border: filled
                  ? null
                  : Border.all(color: const Color(0xFFC9B7A0), width: 2),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              w,
              style: HgText.body(
                size: 17,
                weight: FontWeight.w800,
                color: filled ? HgColors.ink : const Color(0xFF6B5A48),
              ),
            ),
          ),
      ],
    );
  }
}

class _Lines extends StatelessWidget {
  const _Lines(this.lines, {required this.empty});
  final List<String> lines;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return Text(empty, style: HgText.body(color: HgColors.muted));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        for (final l in lines)
          Text(l, style: HgText.body(size: 18, color: HgColors.ink)),
      ],
    );
  }
}

class _DarkCard extends StatelessWidget {
  const _DarkCard({required this.label, required this.text});
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return PCard(
      color: HgColors.teal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(label.toUpperCase(), style: HgText.label(color: HgColors.mango)),
          Text(
            text,
            style: HgText.display(
              size: 22,
              color: HgColors.cream,
              weight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

String _isoToday() => DateTime.now().toIso8601String().substring(0, 10);

String _weekday(DateTime d) => const [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
][d.weekday - 1];
