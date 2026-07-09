import 'package:flutter/material.dart';

/// Skyline's Material 3 theme. Seed color and typography are placeholders
/// for Phase 1 — final brand palette lands alongside UI work in Phase 6+.
abstract final class AppTheme {
  static const Color _seedColor = Color(0xFF3762E8);

  static ThemeData light() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.light,
        ),
      );

  static ThemeData dark() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.dark,
        ),
      );
}
