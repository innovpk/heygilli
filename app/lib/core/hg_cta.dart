import 'package:flutter/material.dart';

import 'theme.dart';

/// The primary action, drawn rather than rendered.
///
/// A rust fill with a hard offset shadow — no blur, no gradient — so it reads
/// as something stamped on paper next to Itim's hand-drawn letterforms. It is
/// the one shape in the app that means "this is the thing to press", and both
/// the landing page and the app handoff use it for exactly that, which is why
/// it lives here rather than being rebuilt per screen.
///
/// Pressing translates the button into its own shadow instead of shrinking the
/// shadow, so the whole thing moves the way a physical key does. Hover lifts
/// it the other way.
class HgCta extends StatefulWidget {
  const HgCta({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.size = 20,
    this.fill = HgColors.mango,
    this.foreground = HgColors.white,
    this.shadow = HgColors.ink,
    this.expand = false,
    this.busy = false,
  });

  final String label;

  /// Null disables it: the fill drops to a tint and the shadow goes, because a
  /// hard shadow on something that cannot be pressed is a lie about depth.
  final VoidCallback? onPressed;
  final IconData? icon;
  final double size;
  final Color fill;
  final Color foreground;
  final Color shadow;
  final bool expand;

  /// Shows a spinner in place of the icon and blocks the tap without changing
  /// the button's width, so a row of controls does not reflow mid-press.
  final bool busy;

  @override
  State<HgCta> createState() => _HgCtaState();
}

class _HgCtaState extends State<HgCta> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.busy;
    // Offsets are the design's: 3px at rest, 4px raised on hover, and nothing
    // at all while held, with the button itself moved down into the gap.
    final depth = !enabled
        ? 0.0
        : _down
        ? 0.0
        : _hover
        ? 4.0
        : 3.0;
    final lift = !enabled || _down
        ? Offset.zero
        : const Offset(-1, -1) * (depth - 3);

    final content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: 10,
      children: [
        if (widget.busy)
          SizedBox(
            width: widget.size,
            height: widget.size,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: widget.foreground,
            ),
          )
        else if (widget.icon != null)
          Icon(widget.icon, size: widget.size + 2, color: widget.foreground),
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: HgText.display(size: widget.size, color: widget.foreground),
          ),
        ),
      ],
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapUp: enabled ? (_) => setState(() => _down = false) : null,
          onTapCancel: enabled ? () => setState(() => _down = false) : null,
          onTap: enabled ? widget.onPressed : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(
              lift.dx + (_down ? 3 : 0),
              lift.dy + (_down ? 3 : 0),
              0,
            ),
            // 44 high at the smallest size the app uses it: a tap target a
            // child or a parent holding a toddler can actually hit.
            constraints: const BoxConstraints(minHeight: 48),
            padding: EdgeInsets.symmetric(
              horizontal: widget.size + 8,
              vertical: 13,
            ),
            decoration: BoxDecoration(
              color: enabled
                  ? widget.fill
                  : Color.lerp(widget.fill, HgColors.cream, 0.55),
              borderRadius: BorderRadius.circular(14),
              boxShadow: depth == 0
                  ? const []
                  : [
                      BoxShadow(
                        color: widget.shadow,
                        offset: Offset(depth, depth),
                      ),
                    ],
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}
