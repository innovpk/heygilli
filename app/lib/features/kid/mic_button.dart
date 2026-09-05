import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Big single mic button (SPEC 9.2 tablet: "big single mic button").
///
/// Push-to-talk: press starts listening, release finishes. A plain tap also
/// works (toggle) because 4-year-olds cannot hold a button for a sentence.
class MicButton extends StatelessWidget {
  const MicButton({
    super.key,
    required this.listening,
    required this.onPressStart,
    required this.onPressEnd,
    this.size = 120,
    this.enabled = true,
  });

  final bool listening;
  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;
  final double size;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: listening ? 'Listening' : 'Hold to talk',
      child: GestureDetector(
        onTapDown: enabled && !listening ? (_) => onPressStart() : null,
        onTapUp: enabled && listening ? (_) => onPressEnd() : null,
        onTapCancel: enabled && listening ? onPressEnd : null,
        onLongPressEnd: enabled && listening ? (_) => onPressEnd() : null,
        child: ListenRing(size: size, active: listening, enabled: enabled),
      ),
    );
  }
}

/// Mango mic ring, pulsing while active. Mirrors `listen_ring()` in the
/// design mockups.
class ListenRing extends StatefulWidget {
  const ListenRing({
    super.key,
    required this.size,
    required this.active,
    this.enabled = true,
  });

  final double size;
  final bool active;
  final bool enabled;

  @override
  State<ListenRing> createState() => _ListenRingState();
}

class _ListenRingState extends State<ListenRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant ListenRing old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _sync();
  }

  void _sync() {
    if (widget.active) {
      _c.repeat(reverse: true);
    } else {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final base = widget.enabled ? HgColors.mango : HgColors.muted;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => SizedBox(
        width: s,
        height: s,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: s * (0.82 + 0.18 * _c.value),
              height: s * (0.82 + 0.18 * _c.value),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: base.withValues(alpha: 0.28),
              ),
            ),
            Container(
              width: s * (0.66 + 0.1 * _c.value),
              height: s * (0.66 + 0.1 * _c.value),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: base.withValues(alpha: 0.5),
              ),
            ),
            Container(
              width: s * 0.52,
              height: s * 0.52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: base,
                boxShadow: const [
                  BoxShadow(color: Color(0x2E0F2A33), offset: Offset(0, 6)),
                ],
              ),
              child: Icon(
                widget.active ? Icons.mic : Icons.mic_none,
                size: s * 0.26,
                color: HgColors.teal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
