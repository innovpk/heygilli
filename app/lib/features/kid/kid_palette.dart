import 'package:flutter/widgets.dart';

import '../../core/theme.dart';

/// The kid side's colours, in the two grounds a child can choose between.
///
/// The dark ground has always been the default, and the reason has not changed:
/// a bright screen in a dim living room is harsh on a four-year-old's eyes, and
/// most watching happens after tea. But it is the wrong answer in a bright room
/// in the middle of the afternoon, where a dark screen is the one that is hard
/// to read, and until now a child had no say in it.
///
/// So the ground is a choice, and it belongs to the child rather than to the
/// parent: it is cosmetic, it changes nothing about what they may watch or for
/// how long, and putting it behind the PIN would say it was a rule.
///
/// Every colour the kid screens use comes from here rather than from [HgColors]
/// directly, which is what makes the swap total. The one exception is the
/// accent: on the dark ground rust is 2.2:1 and unusable, so dark uses the
/// lighter step and light uses rust itself.
@immutable
class KidPalette {
  const KidPalette({
    required this.dark,
    required this.ground,
    required this.onGround,
    required this.card,
    required this.chip,
    required this.tile,
    required this.accent,
    required this.quiet,
    required this.bubble,
    required this.onBubble,
  });

  /// Pine ground, duck-egg type. The default, and what every kid screen looked
  /// like before there was a choice.
  static const nightTime = KidPalette(
    dark: true,
    ground: HgColors.teal,
    onGround: HgColors.cream,
    card: Color(0x14DCEEEA),
    chip: Color(0x24DCEEEA),
    tile: Color(0x1FDCEEEA),
    accent: HgColors.accentTint,
    quiet: HgColors.sky,
    bubble: HgColors.cream,
    onBubble: HgColors.teal,
  );

  /// Duck-egg ground, pine type — the parent side's colours, handed to the
  /// child. For a bright room, where the dark ground is the unreadable one.
  static const dayTime = KidPalette(
    dark: false,
    ground: HgColors.cream,
    onGround: HgColors.ink,
    card: HgColors.white,
    chip: Color(0x141E3A34),
    tile: HgColors.white,
    accent: HgColors.mango,
    quiet: HgColors.brown,
    bubble: HgColors.teal,
    onBubble: HgColors.cream,
  );

  final bool dark;

  /// The page behind everything.
  final Color ground;

  /// Type and icons on [ground].
  final Color onGround;

  /// A raised surface — the status pill, a panel.
  final Color card;

  /// A smaller raised surface that carries a label.
  final Color chip;

  /// A video tile.
  final Color tile;

  /// Row headings, the listening dot, anything that means "here".
  final Color accent;

  /// Second-rank type: a channel name, a length, a hint under a question.
  final Color quiet;

  /// Gilli's speech bubble, and the type on it. Inverted against the ground on
  /// both, so Gilli always reads as speaking rather than as another panel.
  final Color bubble;
  final Color onBubble;

  KidPalette get flipped => dark ? dayTime : nightTime;

  static const _fallback = nightTime;

  /// The palette in scope, or the dark one when a screen is built outside a
  /// [KidTheme] — a test pumping one widget on its own, most often.
  static KidPalette of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<KidTheme>()?.palette ??
      _fallback;
}

/// Puts a [KidPalette] in scope for a subtree.
class KidTheme extends InheritedWidget {
  const KidTheme({super.key, required this.palette, required super.child});

  final KidPalette palette;

  @override
  bool updateShouldNotify(KidTheme oldWidget) => oldWidget.palette != palette;
}
