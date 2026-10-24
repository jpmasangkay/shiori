import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Design tokens ported from the Figma Make `index.css` `:root` block.
class AppColors {
  AppColors._();

  static const bg = Color(0xFF111318);
  static const amoledBg = Color(0xFF000000);
  static const surface = Color(0xFF1D2026);
  static const amoledSurface = Color(0xFF0D0E12);
  static const surfaceHigh = Color(0xFF282A2F);
  static const amoledSurfaceHigh = Color(0xFF16181F);
  static const text = Color(0xFFE2E2E9);
  static const muted = Color(0xFF8E9099);
  static const read = Color(0xFF6C707A);
  static const primary = Color(0xFFADC6FF);
  static const onPrimary = Color(0xFF002E69);
  static const active = Color(0xFF004A77);
  static const outline = Color(0xFF44474F);
  static const black = Color(0xFF060709);
}

class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const String _keyAmoled = 'amoled_black_enabled';
  bool _amoled = false;

  bool get isAmoled => _amoled;

  Color get currentBg => _amoled ? AppColors.amoledBg : AppColors.bg;
  Color get currentSurface => _amoled ? AppColors.amoledSurface : AppColors.surface;
  Color get currentSurfaceHigh => _amoled ? AppColors.amoledSurfaceHigh : AppColors.surfaceHigh;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _amoled = prefs.getBool(_keyAmoled) ?? false;
      _updateSystemUI();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setAmoled(bool enabled) async {
    _amoled = enabled;
    _updateSystemUI();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAmoled, enabled);
    notifyListeners();
  }

  void _updateSystemUI() {
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: _amoled ? Colors.black : AppColors.surface,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }
}

ThemeData buildTheme({bool amoled = false}) {
  final bgColor = amoled ? AppColors.amoledBg : AppColors.bg;
  final surfaceColor = amoled ? AppColors.amoledSurface : AppColors.surface;
  final surfaceHighColor = amoled ? AppColors.amoledSurfaceHigh : AppColors.surfaceHigh;

  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: bgColor,
    colorScheme: ColorScheme.dark(
      primary: AppColors.primary,
      onPrimary: AppColors.onPrimary,
      surface: bgColor,
      onSurface: AppColors.text,
      outline: AppColors.outline,
      surfaceContainer: surfaceColor,
      surfaceContainerHigh: surfaceHighColor,
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
      backgroundColor: surfaceColor,
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
    dividerColor: surfaceColor,
  );
}
