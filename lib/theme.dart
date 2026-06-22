import 'package:flutter/material.dart';

class SnowServColors {
  static const navy = Color(0xFF0D1B2A);
  static const navyMid = Color(0xFF1A3A5C);
  static const iceBlue = Color(0xFF1565C0);
  static const iceBluLight = Color(0xFF4A90D9);
  static const frost = Color(0xFFF0F6FF);
  static const glacier = Color(0xFFB8D4F0);
  static const snow = Colors.white;
}

ThemeData buildSnowServTheme() {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: SnowServColors.iceBlue,
      brightness: Brightness.light,
    ).copyWith(
      primary: SnowServColors.iceBlue,
      surface: Colors.white,
    ),
    scaffoldBackgroundColor: SnowServColors.frost,
    appBarTheme: const AppBarTheme(
      backgroundColor: SnowServColors.navy,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
      iconTheme: IconThemeData(color: Colors.white),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: SnowServColors.iceBlue,
        foregroundColor: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(vertical: 16),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: SnowServColors.iceBlue,
        side: const BorderSide(color: SnowServColors.iceBlue),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 3,
      shadowColor: SnowServColors.iceBlue.withOpacity(0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      color: Colors.white,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFF8FBFF),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: SnowServColors.glacier),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: SnowServColors.glacier),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: SnowServColors.iceBlue, width: 2),
      ),
      labelStyle: const TextStyle(color: Color(0xFF5A7A9A)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return SnowServColors.iceBlue;
          }
          return Colors.white;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.white;
          }
          return SnowServColors.iceBlue;
        }),
        side: WidgetStateProperty.all(
          const BorderSide(color: SnowServColors.glacier),
        ),
      ),
    ),
    dividerTheme: const DividerThemeData(color: SnowServColors.glacier),
    useMaterial3: true,
  );
}
