import 'package:flutter/material.dart';

// ── Ocean Blue Palette ────────────────────────────────────────────────────────
class AppColors {
  // Brand blues
  static const blue50  = Color(0xFFEFF6FF);
  static const blue100 = Color(0xFFDBEAFE);
  static const blue200 = Color(0xFFBFDBFE);
  static const blue300 = Color(0xFF93C5FD);
  static const blue400 = Color(0xFF60A5FA);
  static const blue500 = Color(0xFF3B82F6); // Primary
  static const blue600 = Color(0xFF2563EB);
  static const blue700 = Color(0xFF1D4ED8);
  static const blue800 = Color(0xFF1E40AF);
  static const blue900 = Color(0xFF1E3A8A); // Deep navy

  // Accents
  static const cyan    = Color(0xFF06B6D4);
  static const indigo  = Color(0xFF6366F1);
  static const green   = Color(0xFF22C55E);
  static const amber   = Color(0xFFF59E0B);
  static const red     = Color(0xFFEF4444);

  // Dark surfaces
  static const surface      = Color(0xFF080F1E);
  static const surfaceLight = Color(0xFF0F1A2E);
  static const surfaceCard  = Color(0xFF0D1730);
  static const surfaceElev  = Color(0xFF152240);

  // Gradient stops
  static const gradStart = Color(0xFF1E3A8A);
  static const gradMid   = Color(0xFF6366F1);
  static const gradEnd   = Color(0xFF06B6D4);
}

// ── Dark Theme ────────────────────────────────────────────────────────────────
ThemeData buildDarkTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary:          AppColors.blue500,
      onPrimary:        Colors.white,
      primaryContainer: AppColors.blue800,
      secondary:        AppColors.cyan,
      onSecondary:      Colors.white,
      surface:          AppColors.surfaceCard,
      onSurface:        Color(0xFFE2E8F0),
      error:            AppColors.red,
      onError:          Colors.white,
    ),
    scaffoldBackgroundColor: AppColors.surface,
    cardColor: AppColors.surfaceCard,
    cardTheme: CardTheme(
      color: AppColors.surfaceCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0x19FFFFFF)),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.surfaceLight,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: Colors.white,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceElev,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0x19FFFFFF)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0x19FFFFFF)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.blue500, width: 2),
      ),
      labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
      hintStyle: const TextStyle(color: Color(0xFF64748B)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.blue500,
        foregroundColor: Colors.white,
        minimumSize: const Size(double.infinity, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.blue400),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surfaceElev,
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      behavior: SnackBarBehavior.floating,
    ),
    textTheme: const TextTheme(
      displayLarge: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      titleLarge:   TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      titleMedium:  TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      bodyLarge:    TextStyle(color: Color(0xFFE2E8F0)),
      bodyMedium:   TextStyle(color: Color(0xFFCBD5E1)),
      bodySmall:    TextStyle(color: Color(0xFF94A3B8)),
      labelSmall:   TextStyle(color: Color(0xFF64748B)),
    ),
  );
}
