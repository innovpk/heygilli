import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/fake_gateway.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'parent_widgets.dart';

/// The parent's time settings for one kid (PROTOCOL "Time limits and break
/// periods"), saved with `PATCH /kids/{id}/limits`.
///
/// Every row says what it means in the words a parent would use, because
/// "break_after_minutes: 25" tells them nothing about what their child will
/// actually experience. Where the protocol allows 0 the stepper steps down
/// into it and the line changes to "no limit" rather than showing a zero.
///
/// What Gilli *says* during a break is not here: those are the parent's own
/// words, and they live in [BreakMessagesCard].
class TimeLimitsCard extends StatefulWidget {
  const TimeLimitsCard({super.key, required this.kid});

  final Kid kid;

  @override
  State<TimeLimitsCard> createState() => _TimeLimitsCardState();
}

class _TimeLimitsCardState extends State<TimeLimitsCard> {
  late Kid _kid = widget.kid;
  late Kid _saved = widget.kid;
  bool _saving = false;
  String? _error;

  bool get _dirty =>
      _kid.dailyMinutes != _saved.dailyMinutes ||
      _kid.breakAfterMinutes != _saved.breakAfterMinutes ||
      _kid.breakMinutes != _saved.breakMinutes ||
      _kid.maxVideoMinutes != _saved.maxVideoMinutes ||
      _kid.breakIsFirm != _saved.breakIsFirm;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final state = context.read<AppState>();
      final updated = await state.gateway.updateLimits(
        _kid.id,
        dailyMinutes: _kid.dailyMinutes,
        breakAfterMinutes: _kid.breakAfterMinutes,
        breakMinutes: _kid.breakMinutes,
        maxVideoMinutes: _kid.maxVideoMinutes,
        breakIsFirm: _kid.breakIsFirm,
      );
      await state.refreshKids();
      if (!mounted) return;
      setState(() {
        _kid = updated;
        _saved = updated;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _kid.nickname;
    return PCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Time limits',
            style: HgText.display(size: 22, color: HgColors.ink),
          ),
          const SizedBox(height: 4),
          Text(
            'Gilli keeps to these on its own. When a break is due it waits '
            'for a natural pause and stops the video, then reads out whatever '
            'you have written for break time.',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
          const SizedBox(height: 16),
          _LimitRow(
            title: 'Watching each day',
            value: _kid.dailyMinutes,
            step: 15,
            min: 15,
            max: 240,
            zeroLabel: 'No daily limit',
            explain: _kid.hasDailyLimit
                ? '$name gets ${_hours(_kid.dailyMinutes)} a day. After that '
                      'Gilli says it is all for today.'
                : 'Gilli never stops the day. You decide when it ends.',
            onChanged: (v) =>
                setState(() => _kid = _kid.copyWith(dailyMinutes: v)),
          ),
          _LimitRow(
            title: 'Break every',
            value: _kid.breakAfterMinutes,
            step: 5,
            min: 10,
            max: 60,
            zeroLabel: 'Never',
            explain: _kid.takesBreaks
                ? 'Gilli stops for a break every '
                      '${_kid.breakAfterMinutes} minutes.'
                : 'No breaks. $name watches straight through.',
            onChanged: (v) =>
                setState(() => _kid = _kid.copyWith(breakAfterMinutes: v)),
          ),
          _LimitRow(
            title: 'A break lasts',
            value: _kid.breakMinutes,
            step: 1,
            // A break of no minutes is not a break, so this one has no "off".
            min: 1,
            max: 15,
            explain: _kid.breakIsFirm
                ? 'The video comes back after ${_kid.breakMinutes} '
                      '${_kid.breakMinutes == 1 ? 'minute' : 'minutes'}, '
                      'whether or not $name says they are done.'
                : 'Up to ${_kid.breakMinutes} '
                      '${_kid.breakMinutes == 1 ? 'minute' : 'minutes'}, or '
                      'sooner if $name taps to say they are done.',
            onChanged: (v) =>
                setState(() => _kid = _kid.copyWith(breakMinutes: v)),
          ),
          _FirmRow(
            isFirm: _kid.breakIsFirm,
            name: name,
            onChanged: (v) =>
                setState(() => _kid = _kid.copyWith(breakIsFirm: v)),
          ),
          _LimitRow(
            title: 'Longest video',
            value: _kid.maxVideoMinutes,
            step: 5,
            min: 5,
            max: 60,
            zeroLabel: 'Any length',
            explain: _kid.maxVideoMinutes == 0
                ? 'Videos of any length can be offered.'
                : 'Videos longer than ${_kid.maxVideoMinutes} minutes are not '
                      'offered to $name at all.',
            onChanged: (v) =>
                setState(() => _kid = _kid.copyWith(maxVideoMinutes: v)),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: HgText.body(size: 14, color: HgColors.coral)),
          ],
          const SizedBox(height: 12),
          // With nothing to save the button reads as "Saved" rather than
          // vanishing into the card: a control that is nearly invisible looks
          // broken, not disabled.
          SizedBox(
            height: 52,
            width: double.infinity,
            child: FilledButton(
              onPressed: _dirty && !_saving ? _save : null,
              style: FilledButton.styleFrom(
                disabledBackgroundColor: HgColors.line,
                disabledForegroundColor: HgColors.brown,
              ),
              child: _saving
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: HgColors.ink,
                      ),
                    )
                  : Text(
                      _dirty ? 'Save limits' : 'Saved',
                      style: HgText.body(
                        size: 16,
                        color: _dirty ? HgColors.ink : HgColors.brown,
                      ),
                    ),
            ),
          ),
          if (context.read<AppState>().gateway case final FakeGateway fake)
            _DemoControls(kid: _kid, fake: fake),
        ],
      ),
    );
  }

  /// "1 hour 30 minutes" reads better than "90 minutes" on the daily row.
  static String _hours(int minutes) {
    if (minutes < 60) return '$minutes minutes';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    final hs = '$h ${h == 1 ? 'hour' : 'hours'}';
    return m == 0 ? hs : '$hs $m minutes';
  }
}

/// Whether the break runs its full length or the child can end it.
///
/// A real choice, presented as one: HeyGilli does not know which households
/// want a screen holding the line and which want it only to ask, and it is
/// not the app's place to decide. Neither option is marked as the right one.
class _FirmRow extends StatelessWidget {
  const _FirmRow({
    required this.isFirm,
    required this.name,
    required this.onChanged,
  });

  final bool isFirm;
  final String name;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'When $name taps "I did it"',
            style: HgText.body(size: 16, color: HgColors.ink),
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Break carries on')),
              ButtonSegment(value: false, label: Text('Video comes back')),
            ],
            selected: {isFirm},
            showSelectedIcon: false,
            onSelectionChanged: (s) => onChanged(s.first),
          ),
          const SizedBox(height: 6),
          Text(
            isFirm
                ? 'Gilli thanks $name and keeps the timer running. The screen '
                      'says so, so the tap is never a broken promise.'
                : 'Gilli takes $name at their word and starts the video again.',
            style: HgText.body(size: 14, color: HgColors.brown),
          ),
        ],
      ),
    );
  }
}

/// One setting: a title, a stepper, and a line of plain words underneath.
class _LimitRow extends StatelessWidget {
  const _LimitRow({
    required this.title,
    required this.value,
    required this.step,
    required this.min,
    required this.max,
    required this.explain,
    required this.onChanged,
    this.zeroLabel,
  });

  final String title;
  final int value;
  final int step;

  /// Smallest real value. Stepping below it lands on 0 when [zeroLabel] is
  /// given, and stops otherwise.
  final int min;
  final int max;
  final String explain;

  /// Shown in place of "0 minutes" where the protocol permits 0.
  final String? zeroLabel;
  final ValueChanged<int> onChanged;

  bool get _allowsZero => zeroLabel != null;

  int? get _down {
    if (value == 0) return null;
    if (value - step < min) return _allowsZero ? 0 : null;
    return value - step;
  }

  int? get _up {
    if (value == 0) return min;
    if (value + step > max) return null;
    return value + step;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: HgText.body(size: 16, color: HgColors.ink),
                ),
              ),
              _StepButton(
                icon: Icons.remove_rounded,
                semantic: 'Less $title',
                onPressed: _down == null ? null : () => onChanged(_down!),
              ),
              // Wide enough for the longest "no limit" wording, which is a
              // phrase rather than a number and used to collide with the
              // minus button.
              SizedBox(
                width: 116,
                child: Text(
                  value == 0 ? zeroLabel! : '$value min',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HgText.display(
                    size: value == 0 ? 16 : 18,
                    color: HgColors.ink,
                  ),
                ),
              ),
              _StepButton(
                icon: Icons.add_rounded,
                semantic: 'More $title',
                onPressed: _up == null ? null : () => onChanged(_up!),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(explain, style: HgText.body(size: 13, color: HgColors.brown)),
        ],
      ),
    );
  }
}

/// 48 dp round stepper button.
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.semantic,
    required this.onPressed,
  });

  final IconData icon;
  final String semantic;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semantic,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Material(
          color: onPressed == null ? HgColors.line : HgColors.cream,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Icon(
              icon,
              size: 24,
              color: onPressed == null ? HgColors.muted : HgColors.ink,
            ),
          ),
        ),
      ),
    );
  }
}

/// Demo-only shortcuts. A real break arrives 25 minutes into a session, which
/// is not a thing anyone can sit through in front of a judge, so demo mode
/// can put the kid screen into either blocked state on the spot.
class _DemoControls extends StatelessWidget {
  const _DemoControls({required this.kid, required this.fake});

  final Kid kid;
  final FakeGateway fake;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DEMO', style: HgText.label(color: HgColors.muted)),
          const SizedBox(height: 6),
          Text(
            'Set the state kid mode opens in.',
            style: HgText.body(size: 13, color: HgColors.brown),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _DemoChip(
                label: 'Break now',
                onTap: () => fake.startDemoBreak(kid.id),
              ),
              _DemoChip(
                label: "Day's minutes used",
                onTap: () => fake.useUpTheDay(kid.id),
              ),
              _DemoChip(
                label: 'Clear',
                onTap: () => fake.clearDemoLimits(kid.id),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DemoChip extends StatelessWidget {
  const _DemoChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: OutlinedButton(
        onPressed: () {
          onTap();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$label: open kid mode to see it')),
          );
        },
        style: OutlinedButton.styleFrom(
          foregroundColor: HgColors.brown,
          side: const BorderSide(color: HgColors.line, width: 2),
          shape: const StadiumBorder(),
        ),
        child: Text(label, style: HgText.body(size: 14, color: HgColors.brown)),
      ),
    );
  }
}
