import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pure-black AMOLED default design tokens.
class AppColors {
  AppColors._();

  static const bg = Color(0xFF000000);
  static const amoledBg = Color(0xFF000000);
  static const slateBg = Color(0xFF101116);
  static const lightBg = Color(0xFFF7F7FA);

  static const surface = Color(0xFF0A0A0A);
  static const amoledSurface = Color(0xFF0A0A0A);
  static const slateSurface = Color(0xFF171922);
  static const lightSurface = Color(0xFFFFFFFF);

  static const surfaceHigh = Color(0xFF141414);
  static const amoledSurfaceHigh = Color(0xFF141414);
  static const slateSurfaceHigh = Color(0xFF212432);
  static const lightSurfaceHigh = Color(0xFFEBEBF0);

  static const text = Color(0xFFEDEDEF);
  static const lightText = Color(0xFF15161B);
  static const muted = Color(0xFF9A9CA6); // WCAG AA (~7.5:1 on #000000)
  static const lightMuted = Color(0xFF5A5D6A);
  static const read = Color(0xFF70737D);
  static const primary = Color(0xFFADC6FF);
  static const onPrimary = Color(0xFF002E69);
  static const active = Color(0xFF102A45);
  static const outline = Color(0xFF222226);
  static const lightOutline = Color(0xFFD9DBE4);
  static const black = Color(0xFF000000);
}

enum ShioriThemeMode {
  amoled('amoled', 'AMOLED Black'),
  dark('dark', 'Dark Slate'),
  light('light', 'Paper Light'),
  system('system', 'Follow System');

  const ShioriThemeMode(this.key, this.label);
  final String key;
  final String label;

  static ShioriThemeMode fromKey(String? key) {
    for (final m in values) {
      if (m.key == key) return m;
    }
    return ShioriThemeMode.amoled;
  }
}

enum ShioriAccent {
  periwinkle('periwinkle', 'Periwinkle', Color(0xFFADC6FF), Color(0xFF002E69)),
  violet('violet', 'Violet', Color(0xFFC4B5FD), Color(0xFF2E1065)),
  emerald('emerald', 'Emerald', Color(0xFF6EE7B7), Color(0xFF022C22)),
  rose('rose', 'Sakura Rose', Color(0xFFFDA4AF), Color(0xFF4C0519)),
  amber('amber', 'Warm Amber', Color(0xFFFCD34D), Color(0xFF451A03)),
  teal('teal', 'Ocean Teal', Color(0xFF5EEAD4), Color(0xFF042F2E));

  const ShioriAccent(this.key, this.label, this.primary, this.onPrimary);
  final String key;
  final String label;
  final Color primary;
  final Color onPrimary;

  static ShioriAccent fromKey(String? key) {
    for (final a in values) {
      if (a.key == key) return a;
    }
    return ShioriAccent.periwinkle;
  }
}

/// Consistent application-wide type scale (cached to avoid per-frame GoogleFonts lookups).
class AppText {
  AppText._();

  /// Screen / AppBar title (20sp, w600).
  static final TextStyle title = GoogleFonts.inter(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: AppColors.text,
  );

  /// Modal / sheet / dialog title (16.5sp, w700).
  static final TextStyle sheetTitle = GoogleFonts.inter(
    fontSize: 16.5,
    fontWeight: FontWeight.w700,
    color: AppColors.text,
  );

  /// Section header (11.5sp, w700, letter-spaced).
  static final TextStyle sectionHeader = GoogleFonts.inter(
    fontSize: 11.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.0,
    color: AppColors.muted,
  );

  /// Card title / prominent list item title (14.5sp, w600).
  static final TextStyle cardTitle = GoogleFonts.inter(
    fontSize: 14.5,
    fontWeight: FontWeight.w600,
    color: AppColors.text,
  );

  /// Standard body text (13sp, w400).
  static final TextStyle body = GoogleFonts.inter(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    color: AppColors.text,
  );

  /// Medium body / list title text (13sp, w500).
  static final TextStyle bodyMedium = GoogleFonts.inter(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: AppColors.text,
  );

  /// Semi-bold body / button text (13sp, w600).
  static final TextStyle bodySemiBold = GoogleFonts.inter(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: AppColors.text,
  );

  /// Chip / tab / compact cover label (12sp, w500).
  static final TextStyle chip = GoogleFonts.inter(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: AppColors.text,
  );

  /// Caption / subtitle / secondary metadata (11.5sp, w400).
  static final TextStyle caption = GoogleFonts.inter(
    fontSize: 11.5,
    fontWeight: FontWeight.w400,
    color: AppColors.muted,
  );

  /// Badge / pill / micro status label (9.5sp, w700).
  static final TextStyle badge = GoogleFonts.inter(
    fontSize: 9.5,
    fontWeight: FontWeight.w700,
    color: AppColors.primary,
  );

  /// Monospace text for technical identifiers & backups (11.5sp).
  static final TextStyle mono = GoogleFonts.robotoMono(
    fontSize: 11.5,
    color: AppColors.text,
  );

  /// Navigation bar label styles (12.2sp).
  static final TextStyle navLabelSelected = GoogleFonts.inter(
    fontSize: 12.2,
    fontWeight: FontWeight.w700,
    color: AppColors.text,
  );

  static final TextStyle navLabelUnselected = GoogleFonts.inter(
    fontSize: 12.2,
    fontWeight: FontWeight.w500,
    color: AppColors.muted,
  );
}

class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const _keyThemeMode = 'shiori_theme_mode_v1';
  static const _keyAccent = 'shiori_theme_accent_v1';

  ShioriThemeMode _mode = ShioriThemeMode.amoled;
  ShioriAccent _accent = ShioriAccent.periwinkle;

  ShioriThemeMode get mode => _mode;
  ShioriAccent get accent => _accent;
  bool get isAmoled => _mode == ShioriThemeMode.amoled;
  bool get isLight => _mode == ShioriThemeMode.light;

  ThemeMode get materialThemeMode => switch (_mode) {
    ShioriThemeMode.light => ThemeMode.light,
    ShioriThemeMode.system => ThemeMode.system,
    ShioriThemeMode.amoled || ShioriThemeMode.dark => ThemeMode.dark,
  };

  Color get currentBg => switch (_mode) {
    ShioriThemeMode.light => AppColors.lightBg,
    ShioriThemeMode.dark => AppColors.slateBg,
    _ => AppColors.bg,
  };

  Color get currentSurface => switch (_mode) {
    ShioriThemeMode.light => AppColors.lightSurface,
    ShioriThemeMode.dark => AppColors.slateSurface,
    _ => AppColors.surface,
  };

  Color get currentSurfaceHigh => switch (_mode) {
    ShioriThemeMode.light => AppColors.lightSurfaceHigh,
    ShioriThemeMode.dark => AppColors.slateSurfaceHigh,
    _ => AppColors.surfaceHigh,
  };

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _mode = ShioriThemeMode.fromKey(prefs.getString(_keyThemeMode));
      _accent = ShioriAccent.fromKey(prefs.getString(_keyAccent));
    } catch (_) {}
    _updateSystemUI();
    notifyListeners();
  }

  Future<void> setThemeMode(ShioriThemeMode newMode) async {
    if (_mode == newMode) return;
    _mode = newMode;
    _cachedTheme = null;
    _cachedLightTheme = null;
    _updateSystemUI();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyThemeMode, newMode.key);
    } catch (_) {}
  }

  Future<void> setAccent(ShioriAccent newAccent) async {
    if (_accent == newAccent) return;
    _accent = newAccent;
    _cachedTheme = null;
    _cachedLightTheme = null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyAccent, newAccent.key);
    } catch (_) {}
  }

  void _updateSystemUI() {
    final light = _mode == ShioriThemeMode.light;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: light ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: currentBg,
        systemNavigationBarIconBrightness: light ? Brightness.dark : Brightness.light,
      ),
    );
  }
}

ThemeData? _cachedTheme;
ThemeData? _cachedLightTheme;

ThemeData buildTheme({bool forceLight = false}) {
  final ctrl = ThemeController.instance;
  final accent = ctrl.accent;

  if (forceLight || ctrl.mode == ShioriThemeMode.light) {
    if (_cachedLightTheme != null) return _cachedLightTheme!;
    final base = ThemeData(
      brightness: Brightness.light,
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.lightBg,
      canvasColor: AppColors.lightSurface,
      cardColor: AppColors.lightSurface,
      colorScheme: ColorScheme.light(
        primary: accent.onPrimary,
        onPrimary: Colors.white,
        surface: AppColors.lightBg,
        onSurface: AppColors.lightText,
        outline: AppColors.lightOutline,
        surfaceContainer: AppColors.lightSurface,
        surfaceContainerHigh: AppColors.lightSurfaceHigh,
      ),
    );
    final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: AppColors.lightText,
      displayColor: AppColors.lightText,
    );
    final builtLight = base.copyWith(
      textTheme: textTheme,
      dividerColor: AppColors.lightOutline,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.lightBg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: AppColors.lightText,
        elevation: 0,
        titleTextStyle: AppText.title.copyWith(color: AppColors.lightText),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 74,
        backgroundColor: AppColors.lightSurface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: accent.primary.withValues(alpha: 0.35),
      ),
    );
    _cachedLightTheme = builtLight;
    return builtLight;
  }

  final existing = _cachedTheme;
  if (existing != null) return existing;

  final bg = ctrl.mode == ShioriThemeMode.dark ? AppColors.slateBg : AppColors.bg;
  final surface = ctrl.mode == ShioriThemeMode.dark ? AppColors.slateSurface : AppColors.surface;
  final surfaceHigh = ctrl.mode == ShioriThemeMode.dark
      ? AppColors.slateSurfaceHigh
      : AppColors.surfaceHigh;

  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: bg,
    canvasColor: surface,
    cardColor: surface,
    colorScheme: ColorScheme.dark(
      primary: accent.primary,
      onPrimary: accent.onPrimary,
      surface: bg,
      onSurface: AppColors.text,
      outline: AppColors.outline,
      surfaceContainer: surface,
      surfaceContainerHigh: surfaceHigh,
    ),
  );

  final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
    bodyColor: AppColors.text,
    displayColor: AppColors.text,
  );

  final built = base.copyWith(
    textTheme: textTheme,
    splashFactory: InkRipple.splashFactory,
    dividerColor: AppColors.outline,
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.text,
      elevation: 0,
      titleTextStyle: AppText.title,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      modalBackgroundColor: surface,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: AppText.sheetTitle,
      contentTextStyle: AppText.body.copyWith(color: AppColors.muted),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: surfaceHigh,
      contentTextStyle: AppText.body,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppColors.outline),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      textStyle: AppText.body,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.outline),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: surface,
      selectedColor: AppColors.active,
      side: const BorderSide(color: AppColors.outline),
      labelStyle: AppText.chip,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: ZoomPageTransitionsBuilder(),
        TargetPlatform.windows: ZoomPageTransitionsBuilder(),
        TargetPlatform.linux: ZoomPageTransitionsBuilder(),
      },
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 74,
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: AppColors.active,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 26,
          color: selected ? accent.primary : AppColors.muted,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return selected
            ? AppText.navLabelSelected
            : AppText.navLabelUnselected;
      }),
    ),
  );
  _cachedTheme = built;
  return built;
}
