import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/icon_library.dart';
import '../../core/protocol.dart';
import '../../core/theme.dart';

/// Three cream cards for a pick-it question. One tap answers; there is no
/// confirm step (SPEC 9.2). The tapped card wobbles, then the parent widget
/// locks input while Gilli replies.
///
/// Labels are never drawn for band 4_6; for 7+ the English (or Urdu) word is
/// shown under the icon.
class PickCards extends StatefulWidget {
  const PickCards({
    super.key,
    required this.options,
    required this.icons,
    required this.onPick,
    this.showLabels = false,
    this.urdu = false,
    this.enabled = true,
    this.cardSize = 150,
  });

  final List<PickOption> options;
  final IconLibrary icons;
  final void Function(int index) onPick;
  final bool showLabels;
  final bool urdu;
  final bool enabled;
  final double cardSize;

  @override
  State<PickCards> createState() => _PickCardsState();
}

class _PickCardsState extends State<PickCards> {
  int? _picked;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: widget.cardSize * 0.14,
      children: List.generate(widget.options.length.clamp(0, 3), (i) {
        final option = widget.options[i];
        final entry = widget.icons.byId(option.iconId);
        final label = widget.urdu ? (entry?.ur ?? option.label) : option.label;
        return _WobbleCard(
          wobbling: _picked == i,
          size: widget.cardSize,
          dimmed: _picked != null && _picked != i,
          onTap: widget.enabled && _picked == null
              ? () {
                  setState(() => _picked = i);
                  widget.onPick(i);
                }
              : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 8,
            children: [
              SvgPicture.asset(
                widget.icons.assetFor(option.iconId),
                width: widget.cardSize * (widget.showLabels ? 0.56 : 0.68),
                height: widget.cardSize * (widget.showLabels ? 0.56 : 0.68),
              ),
              if (widget.showLabels)
                Text(
                  label,
                  textDirection: widget.urdu
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  style: widget.urdu
                      ? HgText.urdu(size: 18, color: HgColors.ink)
                      : HgText.display(size: 20, color: HgColors.ink),
                ),
            ],
          ),
        );
      }),
    );
  }
}

class _WobbleCard extends StatelessWidget {
  const _WobbleCard({
    required this.child,
    required this.wobbling,
    required this.dimmed,
    required this.size,
    required this.onTap,
  });

  final Widget child;
  final bool wobbling;
  final bool dimmed;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      width: size,
      height: size,
      // Tap target is the whole card: >= 120 dp on every layout we ship.
      constraints: const BoxConstraints(minWidth: 120, minHeight: 120),
      decoration: BoxDecoration(
        color: HgColors.white,
        borderRadius: BorderRadius.circular(size * 0.18),
        border: wobbling
            ? Border.all(color: HgColors.mango, width: 6)
            : null,
        boxShadow: const [
          BoxShadow(color: Color(0x1F0F2A33), offset: Offset(0, 8)),
        ],
      ),
      child: child,
    );

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 250),
      opacity: dimmed ? 0.45 : 1,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: TweenAnimationBuilder<double>(
          key: ValueKey(wobbling),
          tween: Tween(begin: 0, end: wobbling ? 1 : 0),
          duration: const Duration(milliseconds: 550),
          builder: (context, t, child) => Transform.rotate(
            angle: 0.09 * math.sin(t * math.pi * 4) * (1 - t * 0.6),
            child: Transform.scale(
              scale: 1 + 0.07 * math.sin(t * math.pi),
              child: child,
            ),
          ),
          child: card,
        ),
      ),
    );
  }
}
