import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens ported from the Figma Make `index.css` `:root` block.
class AppColors {
  AppColors._();

  static const bg = Color(0xFF111318);
  static const surface = Color(0xFF1D2026);
  static const surfaceHigh = Color(0xFF282A2F);
  static const text = Color(0xFFE2E2E9);
  static const muted = Color(0xFF8E9099);
  static const read = Color(0xFF6C707A);
  static const primary = Color(0xFFADC6FF);
  static const onPrimary = Color(0xFF002E69);
  static const active = Color(0xFF004A77);
  static const outline = Color(0xFF44474F);
  static const black = Color(0xFF060709);
}

ThemeData buildTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.primary,
      onPrimary: AppColors.onPrimary,
      surface: AppColors.bg,
      onSurface: AppColors.text,
      outline: AppColors.outline,
      surfaceContainer: AppColors.surface,
      surfaceContainerHigh: AppColors.surfaceHigh,
    ),
  );

  final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
    bodyColor: AppColors.text,
    displayColor: AppColors.text,
  );

  return base.copyWith(
    textTheme: textTheme,
    splashFactory: InkRipple.splashFactory,
    navigationBarTheme: NavigationBarThemeData(
      height: 80,
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: AppColors.active,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 20,
          color: selected ? AppColors.primary : AppColors.muted,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return GoogleFonts.inter(
          fontSize: 10,
          color: selected ? AppColors.text : AppColors.muted,
        );
      }),
    ),
    dividerColor: AppColors.surface,
  );
}
