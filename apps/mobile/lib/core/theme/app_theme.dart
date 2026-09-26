import 'package:flutter/material.dart';

import 'tokens.dart';

/// Skyline's Material 3 theme, built from the explicit tokens in
/// docs/architecture/design.md (never from a seed colour).
abstract final class AppTheme {
  static ThemeData light() => from(SkylineTokens.light, Brightness.light);
  static ThemeData dark() => from(SkylineTokens.dark, Brightness.dark);

  /// Any tokens, including the person's own colours (board 44).
  static ThemeData from(SkylineTokens t, Brightness b) {
    final scheme = ColorScheme(
      brightness: b,
      primary: t.accentFill,
      onPrimary: t.onAccent,
      secondary: t.accentText,
      onSecondary: t.onAccent,
      error: t.danger,
      onError: Colors.white,
      surface: t.ground,
      onSurface: t.textPrimary,
      surfaceContainer: t.surface,
      surfaceContainerHigh: t.surfaceRaised,
      outline: t.border,
      onSurfaceVariant: t.textSecondary,
    );
    final text = Typography.material2021().black.apply(
          fontFamily: SkyFonts.body,
          bodyColor: t.textPrimary,
          displayColor: t.textPrimary,
        );
    OutlineInputBorder border(Color c) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c),
        );
    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor: t.ground,
      fontFamily: SkyFonts.body,
      textTheme: text,
      extensions: [t],
      dividerColor: t.border,
      appBarTheme: AppBarTheme(
        backgroundColor: t.ground,
        foregroundColor: t.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: SkyFonts.body,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: t.textPrimary,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.surface,
        border: border(t.border),
        enabledBorder: border(t.border),
        focusedBorder: border(t.accentText),
        errorBorder: border(t.danger),
        hintStyle: TextStyle(color: t.textSecondary),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.accentFill,
          foregroundColor: t.onAccent,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(
            fontFamily: SkyFonts.body,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.textPrimary,
          minimumSize: const Size.fromHeight(50),
          side: BorderSide(color: t.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.surfaceRaised,
        contentTextStyle: TextStyle(color: t.textPrimary),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
