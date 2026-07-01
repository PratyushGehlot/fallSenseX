import 'package:flutter/material.dart';

/// Shared light design system for the app: rounded white cards on a light
/// grey background with a blue accent, modeled on the premium reference UI
/// in App_UI_Premium/ (FallSense branding, blue gradient hero cards).
class AppColors {
  static const Color background = Color(0xFFF6F8FB);
  static const Color card = Colors.white;
  static const Color accent = Color(0xFF2F6FE4);
  static const Color accentDark = Color(0xFF1E4FB8);
  static const Color accentLight = Color(0xFFEAF1FF);
  static const Color textPrimary = Color(0xFF12172A);
  static const Color textSecondary = Color(0xFF8A93A6);

  static const Color statusOnline = Color(0xFF34C759);
  static const Color statusOffline = Color(0xFF9CA3AF);
  static const Color statusFall = Color(0xFFFF3B30);
  static const Color statusWarning = Color(0xFFFF9F0A);
  static const Color statusPresence = Color(0xFF2F6FE4);

  static const LinearGradient heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2F6FE4), Color(0xFF4F8EF7)],
  );
}

ThemeData buildAppTheme() {
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.accent,
      secondary: AppColors.accent,
      surface: AppColors.card,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AppColors.textPrimary,
        fontSize: 24,
        fontWeight: FontWeight.bold,
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.accent),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.card,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.card,
      selectedItemColor: AppColors.accent,
      unselectedItemColor: AppColors.textSecondary,
      showUnselectedLabels: true,
      type: BottomNavigationBarType.fixed,
    ),
    dividerTheme: const DividerThemeData(color: Color(0xFFE5E5EA), thickness: 1),
  );
}
