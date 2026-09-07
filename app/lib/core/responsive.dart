import 'package:flutter/material.dart';

import 'theme.dart';

/// Layout helpers for the two shapes this app is really used in: a tablet held
/// in two hands, and a browser window on a laptop.
///
/// The app was written for the first and shipped to both. Everything below is
/// about the second — not stretching a phone screen, which is what a `maxWidth`
/// on its own does, but using the width for something.

/// A modal that is a sheet on a phone and a dialog on a desktop.
///
/// `showModalBottomSheet` anchors to the bottom edge, which is where a thumb
/// is on a phone and nowhere near the eye on a 1000px-tall window: the add-kid
/// form arrived at the very bottom of the screen with the page it interrupted
/// still filling the space above it. Same content, put where the person is
/// looking.
Future<T?> showHgModal<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double maxWidth = 520,
  Color background = HgColors.cream,
}) {
  final wide = MediaQuery.sizeOf(context).width >= HgLayout.wideBreakpoint;
  if (!wide) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: builder,
    );
  }
  return showDialog<T>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: background,
      insetPadding: const EdgeInsets.all(40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          // A dialog taller than the window is a dialog with its buttons off
          // the bottom, which is how a form becomes unfinishable.
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: SingleChildScrollView(child: builder(context)),
      ),
    ),
  );
}

/// Cards side by side once there is room, stacked when there is not.
///
/// A settings page is a pile of independent cards, and on a wide window a
/// single column of them is mostly empty cream with a scrollbar: the parent
/// scrolls past Time limits to reach Break time, on a screen with room for
/// both. They are laid out in the order given, filling the shorter column
/// first, so nothing depends on the two sides being the same height.
class HgCardColumns extends StatelessWidget {
  const HgCardColumns({
    super.key,
    required this.children,
    this.spacing = 16,
    this.breakpoint = HgLayout.wideBreakpoint,
  });

  final List<Widget> children;
  final double spacing;

  /// Two columns need room for two readable ones, not just for two.
  final double breakpoint;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (box.maxWidth < breakpoint || children.length < 2) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) SizedBox(height: spacing),
              children[i],
            ],
          ],
        );
      }
      final left = <Widget>[];
      final right = <Widget>[];
      for (var i = 0; i < children.length; i++) {
        (i.isEven ? left : right).add(children[i]);
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _stack(left)),
          SizedBox(width: spacing),
          Expanded(child: _stack(right)),
        ],
      );
    },
  );

  Widget _stack(List<Widget> items) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) SizedBox(height: spacing),
        items[i],
      ],
    ],
  );
}
