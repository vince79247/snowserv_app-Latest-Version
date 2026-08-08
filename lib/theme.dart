import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// SnowServ design system. One source of truth for color + type so every
/// screen (iOS, Android, web) reads as one polished, professional product.
class SnowServColors {
  // Brand
  static const navy = Color(0xFF0D1B2A); // primary dark / headings
  static const navyMid = Color(0xFF1A3A5C);
  static const iceBlue = Color(0xFF1565C0); // primary action
  static const iceBluLight = Color(0xFF4A90D9);
  static const frost = Color(0xFFF0F6FF); // app background
  static const glacier = Color(0xFFB8D4F0);
  static const snow = Colors.white;

  // Ink (text)
  static const ink = Color(0xFF15242F); // primary text
  static const inkSoft = Color(0xFF5A7184); // secondary text
  static const hairline = Color(0xFFE2ECF6); // borders / dividers
  static const surfaceSoft = Color(0xFFF7FBFF); // input / subtle fills

  // Semantic
  static const success = Color(0xFF1B8F5A);
  static const warning = Color(0xFFB26A00);
  static const danger = Color(0xFFC0392B);
}

ThemeData buildSnowServTheme() {
  const r = 14.0; // base corner radius
  final scheme = ColorScheme.fromSeed(
    seedColor: SnowServColors.iceBlue,
    brightness: Brightness.light,
  ).copyWith(
    primary: SnowServColors.iceBlue,
    surface: Colors.white,
    onSurface: SnowServColors.ink,
    error: SnowServColors.danger,
  );

  // Inter everywhere, with brand ink colours and a tightened display scale.
  final baseText = GoogleFonts.interTextTheme(
    ThemeData(brightness: Brightness.light).textTheme,
  ).apply(bodyColor: SnowServColors.ink, displayColor: SnowServColors.navy);

  final textTheme = baseText.copyWith(
    headlineSmall: baseText.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700, letterSpacing: -0.5, color: SnowServColors.navy),
    titleLarge: baseText.titleLarge?.copyWith(
        fontWeight: FontWeight.w700, letterSpacing: -0.3, color: SnowServColors.navy),
    titleMedium: baseText.titleMedium?.copyWith(
        fontWeight: FontWeight.w600, color: SnowServColors.navy),
    bodyLarge: baseText.bodyLarge?.copyWith(height: 1.4),
    bodyMedium: baseText.bodyMedium?.copyWith(height: 1.45, color: SnowServColors.inkSoft),
    labelLarge: baseText.labelLarge?.copyWith(fontWeight: FontWeight.w600),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: textTheme,
    scaffoldBackgroundColor: SnowServColors.frost,
    splashFactory: InkSparkle.splashFactory,

    appBarTheme: AppBarTheme(
      backgroundColor: SnowServColors.navy,
      foregroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      titleTextStyle: GoogleFonts.inter(
        color: Colors.white,
        fontSize: 19,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      ),
      iconTheme: const IconThemeData(color: Colors.white),
    ),

    // Tabs live in the navy AppBar, where Material 3's defaults resolve to dark
    // on-surface colours and come out nearly unreadable — the FAQ's "For
    // Customers / For Providers" tabs were the visible symptom. The admin panel
    // had already worked around it with the same values inline; putting them in
    // the theme fixes every TabBar at once and stops the next one repeating it.
    tabBarTheme: TabBarThemeData(
      labelColor: Colors.white,
      unselectedLabelColor: SnowServColors.glacier,
      indicatorColor: Colors.white,
      dividerColor: Colors.transparent,
      labelStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700),
      unselectedLabelStyle:
          GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w500),
    ),

    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: SnowServColors.iceBlue,
        foregroundColor: Colors.white,
        elevation: 0,
        shadowColor: Colors.transparent,
        // Height-only min (NOT Size.fromHeight, which forces infinite width and
        // breaks buttons placed inside a Row). Full-width is opt-in per screen.
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
        textStyle: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: SnowServColors.iceBlue,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
        textStyle: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: SnowServColors.iceBlue,
        side: const BorderSide(color: SnowServColors.glacier, width: 1.5),
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 18),
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: SnowServColors.iceBlue,
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),

    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shadowColor: SnowServColors.navy.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: SnowServColors.hairline),
      ),
      margin: EdgeInsets.zero,
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: SnowServColors.surfaceSoft,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(r),
        borderSide: const BorderSide(color: SnowServColors.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(r),
        borderSide: const BorderSide(color: SnowServColors.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(r),
        borderSide: const BorderSide(color: SnowServColors.iceBlue, width: 2),
      ),
      floatingLabelStyle: const TextStyle(color: SnowServColors.iceBlue, fontWeight: FontWeight.w600),
      labelStyle: GoogleFonts.inter(color: SnowServColors.inkSoft),
      hintStyle: GoogleFonts.inter(color: SnowServColors.inkSoft.withValues(alpha: 0.7)),
      prefixIconColor: SnowServColors.inkSoft,
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStatePropertyAll(
            GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600)),
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? SnowServColors.iceBlue : Colors.white),
        foregroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? Colors.white : SnowServColors.iceBlue),
        side: const WidgetStatePropertyAll(BorderSide(color: SnowServColors.glacier)),
        shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(r))),
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: SnowServColors.frost,
      side: const BorderSide(color: SnowServColors.hairline),
      labelStyle: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500, color: SnowServColors.navy),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),

    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: SnowServColors.navy,
      contentTextStyle: GoogleFonts.inter(color: Colors.white, fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),

    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: GoogleFonts.inter(
          fontSize: 18, fontWeight: FontWeight.w700, color: SnowServColors.navy),
    ),

    dividerTheme: const DividerThemeData(color: SnowServColors.hairline, thickness: 1),
  );
}
