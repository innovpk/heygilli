import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// HeyGilli visual language — duck-egg, pine and rust.
///
/// Shared with the landing page (app/web/about.html), which defines the same
/// six colours as CSS custom properties under the names in brackets. A value
/// that changes in one has to change in the other, or the app a parent opens
/// stops looking like the page that sold it to them.
///
/// Still a dark ground on the kid side, for the reason it always was: a bright
/// screen in a dim living room is harsh on a four-year-old's eyes. The ground
/// is now pine rather than teal, and it is the same colour as the type on the
/// parent side — one ink, used as text on light and as a surface on dark.
///
/// The names are the old ones. They stopped describing their hues the day this
/// palette landed ([mango] is rust, [cream] is duck-egg), and renaming 593 call
/// sites to find out whether the reskin worked was not the trade. They are
/// roles now, and the role each one plays is written on it.
abstract final class HgColors {
  /// `--ink`. Kid-mode ground, dark cards, and every dark block on the parent
  /// side. Also [ink]: the same colour reads as type on a light surface.
  static const teal = Color(0xFF1E3A34);

  /// A step below [teal], for a well sunk into a dark surface.
  static const tealDeep = Color(0xFF162C27);

  /// `--bg`. Duck-egg: the parent page ground, and the type on [teal].
  static const cream = Color(0xFFDCEEEA);

  /// `--accent`. Rust. The single "this is the thing to press" colour, and the
  /// one that marks a video waiting on a parent. Carries [white] type, never
  /// [ink] — ink on rust is 2.6:1 and unreadable at any size.
  static const mango = Color(0xFFB8452A);

  /// `--accent-tint`. Rust is 2.2:1 on pine, so it cannot be used on a dark
  /// surface at all. This is the step that can: headings on dark blocks, and
  /// an error where the ground is [teal].
  static const accentTint = Color(0xFFF0A48C);

  /// Error, on a light surface. Deliberately the accent hue rather than a
  /// fifth colour: in this palette an error is rust text and a call to action
  /// is a rust fill with a hard shadow, and the form is what tells them apart.
  /// On a dark surface use [accentTint] instead.
  static const coral = Color(0xFFB8452A);

  /// Quiet information on the kid side — "Break time", a hint under a
  /// question. Cool and desaturated so it can never be mistaken for the accent
  /// or for an error, both of which are warm.
  static const sky = Color(0xFF9CC9BE);

  /// `--ink`. Type on a light surface. Same value as [teal].
  static const ink = Color(0xFF1E3A34);

  /// Secondary type on light: [ink] at 65%, flattened onto [cream] so it can
  /// stay const.
  static const brown = Color(0xFF607974);

  /// `--fits`. Approved, understood, live. Pine-green, so it belongs to the
  /// ground rather than arriving from a traffic light.
  static const green = Color(0xFF2F7D5B);

  /// `--paper`. Cards on the parent side. Not pure white: white on duck-egg is
  /// a hole in the page, and paper is the same paper the bedtime note is on.
  static const white = Color(0xFFF4FAF8);

  /// Third-rank type on light: [ink] at 50% over [cream].
  static const muted = Color(0xFF7D948F);

  /// Hairlines and dividers: [ink] at 15% over [white].
  static const line = Color(0xFFD4DDDB);

  /// Chart marks on a [white] card. A darker step of [mango], because a bar is
  /// read on its own against the card, with no type on it to do the work.
  static const mangoDeep = Color(0xFF8F3520);
}

/// Text styles. Itim for display (a single hand-drawn weight), Nunito for
/// body, Noto Nastaliq Urdu for Urdu. google_fonts fetches on first use and
/// caches; if the device is offline the platform fallback is used.
abstract final class HgText {
  /// Itim ships one weight. `weight` is kept on the signature because ~40 call
  /// sites pass it and a hand-drawn face has nothing to bolden into, so asking
  /// for w800 here is not an error — it simply has no heavier cut to give.
  static TextStyle display({
    double size = 32,
    Color color = HgColors.cream,
    FontWeight weight = FontWeight.w400,
  }) => GoogleFonts.itim(
    fontSize: size,
    fontWeight: FontWeight.w400,
    color: color,
    height: 1.1,
  );

  static TextStyle body({
    double size = 16,
    Color color = HgColors.cream,
    FontWeight weight = FontWeight.w700,
  }) => GoogleFonts.nunito(fontSize: size, fontWeight: weight, color: color);

  /// Urdu is right-to-left and Nastaliq needs generous line height.
  static TextStyle urdu({double size = 24, Color color = HgColors.mango}) =>
      GoogleFonts.notoNastaliqUrdu(
        fontSize: size,
        fontWeight: FontWeight.w500,
        color: color,
        height: 2.0,
      );

  /// Small uppercase label used on parent cards.
  static TextStyle label({Color color = HgColors.brown}) => GoogleFonts.nunito(
    fontSize: 12,
    fontWeight: FontWeight.w800,
    letterSpacing: 1.2,
    color: color,
  );
}

/// Dark theme for kid screens; the parent side paints its own cream surface.
ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: HgColors.mango,
      // White, not ink: ink on rust is 2.6:1. Every filled accent surface in
      // this palette carries light type.
      onPrimary: HgColors.white,
      secondary: HgColors.sky,
      onSecondary: HgColors.ink,
      surface: HgColors.teal,
      onSurface: HgColors.cream,
      error: HgColors.coral,
    ),
    scaffoldBackgroundColor: HgColors.teal,
  );
  return base.copyWith(
    textTheme: GoogleFonts.nunitoTextTheme(base.textTheme),
    appBarTheme: AppBarTheme(
      backgroundColor: HgColors.teal,
      foregroundColor: HgColors.cream,
      elevation: 0,
      titleTextStyle: HgText.display(size: 24),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: HgColors.mango,
        foregroundColor: HgColors.white,
        disabledBackgroundColor: HgColors.line,
        disabledForegroundColor: HgColors.brown,
        textStyle: HgText.body(size: 16, color: HgColors.white),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: const StadiumBorder(),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: HgColors.ink,
        disabledForegroundColor: HgColors.brown,
        side: const BorderSide(color: HgColors.line, width: 1.5),
        textStyle: HgText.body(size: 14, color: HgColors.ink),
        shape: const StadiumBorder(),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        foregroundColor: HgColors.ink,
        selectedForegroundColor: HgColors.ink,
        selectedBackgroundColor: const Color(0xFFB6D8D0),
        backgroundColor: Colors.transparent,
        side: const BorderSide(color: HgColors.line, width: 1.5),
        textStyle: HgText.body(
          size: 14,
          color: HgColors.ink,
          weight: FontWeight.w700,
        ),
      ),
    ),
    // The parent tab bar sits on paper. The selected destination takes an ink
    // pill with a duck-egg icon on it — the same shape and the same pair as
    // the segmented control on a child's page, rather than a washed-out tint
    // of the accent, which on paper read as a smudge.
    navigationBarTheme: NavigationBarThemeData(
      indicatorColor: HgColors.ink,
      labelTextStyle: WidgetStatePropertyAll(
        HgText.body(size: 12, color: HgColors.ink, weight: FontWeight.w800),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? HgColors.cream
              : HgColors.ink,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: HgColors.white,
      selectedColor: HgColors.mango,
      labelStyle: HgText.body(size: 15, color: HgColors.ink),
      // The label on a selected chip: the fill is rust underneath it, so it
      // cannot keep the ink of the unselected state.
      secondaryLabelStyle: HgText.body(size: 15, color: HgColors.white),
      side: BorderSide.none,
      shape: const StadiumBorder(),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: HgColors.teal,
      contentTextStyle: HgText.body(size: 14),
      behavior: SnackBarBehavior.floating,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: HgColors.white,
      hintStyle: HgText.body(color: HgColors.muted, weight: FontWeight.w600),
      labelStyle: HgText.body(color: HgColors.brown, weight: FontWeight.w700),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    ),
  );
}

/// Below this, every parent-facing screen is the phone layout it was
/// designed as. Above it, wide enough that a single narrow column reads as a
/// phone app abandoned in the middle of a browser tab rather than as a page.
/// One constant so the sign-in, intro, and parent-home screens agree on when
/// "wide" starts, rather than each guessing its own number.
abstract final class HgLayout {
  static const wideBreakpoint = 900.0;
}
