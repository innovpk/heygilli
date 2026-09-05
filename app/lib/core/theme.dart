import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// HeyGilli visual language, mirrored from design/generate.py.
///
/// Deep teal background because a bright TV in a dim living room is harsh on
/// a 4-year-old's eyes; cream cards; mango as the single accent so focus and
/// "tap me" always look the same.
abstract final class HgColors {
  static const teal = Color(0xFF0F2A33);
  static const tealDeep = Color(0xFF0A1C22);
  static const cream = Color(0xFFFBF3E6);
  static const mango = Color(0xFFF5A524);
  static const coral = Color(0xFFE4572E);
  static const sky = Color(0xFF8FD3EE);
  static const ink = Color(0xFF1E1A17);
  static const brown = Color(0xFF8A6A4A);
  static const green = Color(0xFF3F7A2F);
  static const white = Color(0xFFFFFFFF);
  static const muted = Color(0xFF9A8F82);
  static const line = Color(0xFFEADFCE);
}

/// Text styles. Baloo 2 for display (round, friendly), Nunito for body,
/// Noto Nastaliq Urdu for Urdu. google_fonts fetches on first use and caches;
/// if the device is offline the platform fallback is used.
abstract final class HgText {
  static TextStyle display({
    double size = 32,
    Color color = HgColors.cream,
    FontWeight weight = FontWeight.w800,
  }) => GoogleFonts.baloo2(
    fontSize: size,
    fontWeight: weight,
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
      onPrimary: HgColors.ink,
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
        foregroundColor: HgColors.ink,
        textStyle: HgText.body(size: 16, color: HgColors.ink),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: const StadiumBorder(),
      ),
    ),
    // Parent tab bar sits on white, so labels and icons are ink, not cream.
    navigationBarTheme: NavigationBarThemeData(
      labelTextStyle: WidgetStatePropertyAll(
        HgText.body(size: 12, color: HgColors.ink, weight: FontWeight.w800),
      ),
      iconTheme: const WidgetStatePropertyAll(
        IconThemeData(color: HgColors.ink),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: HgColors.white,
      selectedColor: HgColors.mango,
      labelStyle: HgText.body(size: 15, color: HgColors.ink),
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
