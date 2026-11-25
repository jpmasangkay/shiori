import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dynamic theme-aware design tokens backed by [ThemeController.instance].
/// Supports AMOLED Black, Dark Slate, Paper Light, Follow System, and all
/// 6 [ShioriAccent] color palettes seamlessly across every screen and sheet.
class AppColors {
  AppColors._();

  static const amoledBg = Color(0xFF000000);
  static const slateBg = Color(0xFF101116);
  static const lightBg = Color(0xFFF7F7FA);

  static const amoledSurface = Color(0xFF0A0A0A);
  static const slateSurface = Color(0xFF171922);
  static const lightSurface = Color(0xFFFFFFFF);

  static const amoledSurfaceHigh = Color(0xFF141414);
  static const slateSurfaceHigh = Color(0xFF212432);
  static const lightSurfaceHigh = Color(0xFFEBEBF0);

  static const darkText = Color(0xFFEDEDEF);
  static const lightText = Color(0xFF15161B);
  static const darkMuted = Color(0xFF9A9CA6); // WCAG AA (~7.5:1 on #000000)
  static const lightMuted = Color(0xFF5A5D6A); // WCAG AA (~6.4:1 on #FFFFFF)
  static const darkRead = Color(0xFF70737D);
  static const lightRead = Color(0xFF8C909E);

  static const amoledOutline = Color(0xFF222226);
  static const slateOutline = Color(0xFF2A2D3D);
  static const lightOutline = Color(0xFFD9DBE4);
  static const black = Color(0xFF000000);

  static Color get bg => ThemeController.instance.currentBg;
  static Color get surface => ThemeController.instance.currentSurface;
  static Color get surfaceHigh => ThemeController.instance.currentSurfaceHigh;
  static Color get text => ThemeController.instance.currentText;
  static Color get muted => ThemeController.instance.currentMuted;
  static Color get read => ThemeController.instance.currentRead;
  static Color get primary => ThemeController.instance.currentPrimary;
  static Color get onPrimary => ThemeController.instance.currentOnPrimary;
  static Color get active => ThemeController.instance.currentActive;
  static Color get outline => ThemeController.instance.currentOutline;
  static bool get isLight => ThemeController.instance.effectiveIsLight;
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
  periwinkle(
    'periwinkle',
    'Periwinkle',
    Color(0xFFADC6FF),
    Color(0xFF002E69),
    Color(0xFF2554B8),
  ),
  violet(
    'violet',
    'Violet',
    Color(0xFFC4B5FD),
    Color(0xFF2E1065),
    Color(0xFF6D28D9),
  ),
  emerald(
    'emerald',
    'Emerald',
    Color(0xFF6EE7B7),
    Color(0xFF022C22),
    Color(0xFF047857),
  ),
  rose(
    'rose',
    'Sakura Rose',
    Color(0xFFFDA4AF),
    Color(0xFF4C0519),
    Color(0xFFBE123C),
  ),
  amber(
    'amber',
    'Warm Amber',
    Color(0xFFFCD34D),
    Color(0xFF451A03),
    Color(0xFFB45309),
  ),
  teal(
    'teal',
    'Ocean Teal',
    Color(0xFF5EEAD4),
    Color(0xFF042F2E),
    Color(0xFF0F766E),
  );

  const ShioriAccent(
    this.key,
    this.label,
    this.primary,
    this.onPrimary,
    this.lightPrimary,
  );
  final String key;
  final String label;
  final Color primary;
  final Color onPrimary;
  final Color lightPrimary;

  static ShioriAccent fromKey(String? key) {
    for (final a in values) {
      if (a.key == key) return a;
    }
    return ShioriAccent.periwinkle;
  }
}

class _AppTextBundle {
  _AppTextBundle({
    required Color text,
    required Color muted,
    required Color primary,
  })  : title = GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: text,
        ),
        sheetTitle = GoogleFonts.inter(
          fontSize: 16.5,
          fontWeight: FontWeight.w700,
          color: text,
        ),
        sectionHeader = GoogleFonts.inter(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: muted,
        ),
        cardTitle = GoogleFonts.inter(
          fontSize: 14.5,
          fontWeight: FontWeight.w600,
          color: text,
        ),
        body = GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          color: text,
        ),
        bodyMedium = GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        bodySemiBold = GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: text,
        ),
        chip = GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        caption = GoogleFonts.inter(
          fontSize: 11.5,
          fontWeight: FontWeight.w400,
          color: muted,
        ),
        badge = GoogleFonts.inter(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          color: primary,
        ),
        mono = GoogleFonts.robotoMono(
          fontSize: 11.5,
          color: text,
        ),
        navLabelSelected = GoogleFonts.inter(
          fontSize: 12.2,
          fontWeight: FontWeight.w700,
          color: text,
        ),
        navLabelUnselected = GoogleFonts.inter(
          fontSize: 12.2,
          fontWeight: FontWeight.w500,
          color: muted,
        );

  final TextStyle title;
  final TextStyle sheetTitle;
  final TextStyle sectionHeader;
  final TextStyle cardTitle;
  final TextStyle body;
  final TextStyle bodyMedium;
  final TextStyle bodySemiBold;
  final TextStyle chip;
  final TextStyle caption;
  final TextStyle badge;
  final TextStyle mono;
  final TextStyle navLabelSelected;
  final TextStyle navLabelUnselected;
}

/// Consistent application-wide type scale, cached per active theme & accent
/// so light/dark/accent switches recolor typography immediately without
/// per-frame GoogleFonts lookup overhead.
class AppText {
  AppText._();

  static String? _cacheKey;
  static _AppTextBundle? _cached;

  static _AppTextBundle get _bundle {
    final ctrl = ThemeController.instance;
    final key = '${ctrl.effectiveIsLight}|${ctrl.accent.key}';
    if (_cached == null || _cacheKey != key) {
      _cacheKey = key;
      _cached = _AppTextBundle(
        text: ctrl.currentText,
        muted: ctrl.currentMuted,
        primary: ctrl.currentPrimary,
      );
    }
    return _cached!;
  }

  static void invalidateCache() {
    _cacheKey = null;
    _cached = null;
  }

  /// Screen / AppBar title (20sp, w600).
  static TextStyle get title => _bundle.title;

  /// Modal / sheet / dialog title (16.5sp, w700).
  static TextStyle get sheetTitle => _bundle.sheetTitle;

  /// Section header (11.5sp, w700, letter-spaced).
  static TextStyle get sectionHeader => _bundle.sectionHeader;

  /// Card title / prominent list item title (14.5sp, w600).
  static TextStyle get cardTitle => _bundle.cardTitle;

  /// Standard body text (13sp, w400).
  static TextStyle get body => _bundle.body;

  /// Medium body / list title text (13sp, w500).
  static TextStyle get bodyMedium => _bundle.bodyMedium;

  /// Semi-bold body / button text (13sp, w600).
  static TextStyle get bodySemiBold => _bundle.bodySemiBold;

  /// Chip / tab / compact cover label (12sp, w500).
  static TextStyle get chip => _bundle.chip;

  /// Caption / subtitle / secondary metadata (11.5sp, w400).
  static TextStyle get caption => _bundle.caption;

  /// Badge / pill / micro status label (9.5sp, w700).
  static TextStyle get badge => _bundle.badge;

  /// Monospace text for technical identifiers & backups (11.5sp).
  static TextStyle get mono => _bundle.mono;

  /// Navigation bar label styles (12.2sp).
  static TextStyle get navLabelSelected => _bundle.navLabelSelected;
  static TextStyle get navLabelUnselected => _bundle.navLabelUnselected;
}

class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const _keyThemeMode = 'shiori_theme_mode_v1';
  static const _keyAccent = 'shiori_theme_accent_v1';

  ShioriThemeMode _mode = ShioriThemeMode.amoled;
  ShioriAccent _accent = ShioriAccent.periwinkle;
  Brightness _platformBrightness = Brightness.dark;

  ShioriThemeMode get mode => _mode;
  ShioriAccent get accent => _accent;
  Brightness get platformBrightness => _platformBrightness;

  bool get isAmoled => _mode == ShioriThemeMode.amoled;
  bool get isLight => _mode == ShioriThemeMode.light;
  bool get effectiveIsLight =>
      _mode == ShioriThemeMode.light ||
      (_mode == ShioriThemeMode.system &&
          _platformBrightness == Brightness.light);
  bool get effectiveIsSlate => _mode == ShioriThemeMode.dark;

  ThemeMode get materialThemeMode => switch (_mode) {
        ShioriThemeMode.light => ThemeMode.light,
        ShioriThemeMode.system => ThemeMode.system,
        ShioriThemeMode.amoled || ShioriThemeMode.dark => ThemeMode.dark,
      };

  Color get currentBg => effectiveIsLight
      ? AppColors.lightBg
      : (effectiveIsSlate ? AppColors.slateBg : AppColors.amoledBg);

  Color get currentSurface => effectiveIsLight
      ? AppColors.lightSurface
      : (effectiveIsSlate ? AppColors.slateSurface : AppColors.amoledSurface);

  Color get currentSurfaceHigh => effectiveIsLight
      ? AppColors.lightSurfaceHigh
      : (effectiveIsSlate
          ? AppColors.slateSurfaceHigh
          : AppColors.amoledSurfaceHigh);

  Color get currentText =>
      effectiveIsLight ? AppColors.lightText : AppColors.darkText;

  Color get currentMuted =>
      effectiveIsLight ? AppColors.lightMuted : AppColors.darkMuted;

  Color get currentRead =>
      effectiveIsLight ? AppColors.lightRead : AppColors.darkRead;

  Color get currentPrimary =>
      effectiveIsLight ? _accent.lightPrimary : _accent.primary;

  Color get currentOnPrimary =>
      effectiveIsLight ? Colors.white : _accent.onPrimary;

  Color get currentActive => effectiveIsLight
      ? _accent.lightPrimary.withValues(alpha: 0.14)
      : _accent.primary.withValues(alpha: 0.18);

  Color get currentOutline => effectiveIsLight
      ? AppColors.lightOutline
      : (effectiveIsSlate ? AppColors.slateOutline : AppColors.amoledOutline);

  Future<void> init() async {
    try {
      _platformBrightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      _mode = ShioriThemeMode.fromKey(prefs.getString(_keyThemeMode));
      _accent = ShioriAccent.fromKey(prefs.getString(_keyAccent));
    } catch (_) {}
    _invalidateCaches();
    _updateSystemUI();
    notifyListeners();
  }

  void updatePlatformBrightness(Brightness brightness) {
    if (_platformBrightness == brightness) return;
    _platformBrightness = brightness;
    if (_mode == ShioriThemeMode.system) {
      _invalidateCaches();
      _updateSystemUI();
      notifyListeners();
    }
  }

  Future<void> setThemeMode(ShioriThemeMode newMode) async {
    if (_mode == newMode) return;
    _mode = newMode;
    _invalidateCaches();
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
    _invalidateCaches();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyAccent, newAccent.key);
    } catch (_) {}
  }

  void _invalidateCaches() {
    _cachedTheme = null;
    _cachedLightTheme = null;
    AppText.invalidateCache();
  }

  void _updateSystemUI() {
    final light = effectiveIsLight;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: light ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: currentBg,
        systemNavigationBarIconBrightness:
            light ? Brightness.dark : Brightness.light,
      ),
    );
  }
}

ThemeData? _cachedTheme;
ThemeData? _cachedLightTheme;

ThemeData buildTheme({bool forceLight = false}) {
  final ctrl = ThemeController.instance;
  final accent = ctrl.accent;
  final useLight = forceLight || ctrl.effectiveIsLight;

  if (useLight) {
    if (_cachedLightTheme != null) return _cachedLightTheme!;
    final primary = accent.lightPrimary;
    const onPrimary = Colors.white;
    final active = primary.withValues(alpha: 0.14);
    const bg = AppColors.lightBg;
    const surface = AppColors.lightSurface;
    const surfaceHigh = AppColors.lightSurfaceHigh;
    const text = AppColors.lightText;
    const muted = AppColors.lightMuted;
    const outline = AppColors.lightOutline;

    final base = ThemeData(
      brightness: Brightness.light,
      useMaterial3: true,
      scaffoldBackgroundColor: bg,
      canvasColor: surface,
      cardColor: surface,
      colorScheme: ColorScheme.light(
        primary: primary,
        onPrimary: onPrimary,
        surface: bg,
        onSurface: text,
        outline: outline,
        surfaceContainer: surface,
        surfaceContainerHigh: surfaceHigh,
      ),
    );
    final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: text,
      displayColor: text,
    );
    final builtLight = base.copyWith(
      textTheme: textTheme,
      splashFactory: InkRipple.splashFactory,
      dividerColor: outline,
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: text,
        elevation: 0,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: text,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        modalBackgroundColor: surface,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 16.5,
          fontWeight: FontWeight.w700,
          color: text,
        ),
        contentTextStyle: GoogleFonts.inter(fontSize: 13, color: muted),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF1F2230),
        contentTextStyle: GoogleFonts.inter(fontSize: 13, color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        textStyle: GoogleFonts.inter(fontSize: 13, color: text),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: outline),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: surface,
        selectedColor: active,
        side: const BorderSide(color: outline),
        labelStyle: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: text,
        ),
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
        indicatorColor: active,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 26,
            color: selected ? primary : muted,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return GoogleFonts.inter(
            fontSize: 12.2,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? text : muted,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surface,
        indicatorColor: active,
        selectedIconTheme: IconThemeData(color: primary, size: 24),
        unselectedIconTheme: const IconThemeData(color: muted, size: 24),
        selectedLabelTextStyle: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: primary,
        ),
        unselectedLabelTextStyle: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: muted,
        ),
      ),
    );
    _cachedLightTheme = builtLight;
    return builtLight;
  }

  final existing = _cachedTheme;
  if (existing != null) return existing;

  final isSlate = ctrl.effectiveIsSlate;
  final bg = isSlate ? AppColors.slateBg : AppColors.amoledBg;
  final surface = isSlate ? AppColors.slateSurface : AppColors.amoledSurface;
  final surfaceHigh =
      isSlate ? AppColors.slateSurfaceHigh : AppColors.amoledSurfaceHigh;
  final outline = isSlate ? AppColors.slateOutline : AppColors.amoledOutline;
  final active = accent.primary.withValues(alpha: 0.18);

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
      onSurface: AppColors.darkText,
      outline: outline,
      surfaceContainer: surface,
      surfaceContainerHigh: surfaceHigh,
    ),
  );

  final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
    bodyColor: AppColors.darkText,
    displayColor: AppColors.darkText,
  );

  final built = base.copyWith(
    textTheme: textTheme,
    splashFactory: InkRipple.splashFactory,
    dividerColor: outline,
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.darkText,
      elevation: 0,
      titleTextStyle: GoogleFonts.inter(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: AppColors.darkText,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      modalBackgroundColor: surface,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: GoogleFonts.inter(
        fontSize: 16.5,
        fontWeight: FontWeight.w700,
        color: AppColors.darkText,
      ),
      contentTextStyle: GoogleFonts.inter(
        fontSize: 13,
        color: AppColors.darkMuted,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: surfaceHigh,
      contentTextStyle: GoogleFonts.inter(
        fontSize: 13,
        color: AppColors.darkText,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: outline),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      textStyle: GoogleFonts.inter(fontSize: 13, color: AppColors.darkText),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: outline),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: surface,
      selectedColor: active,
      side: BorderSide(color: outline),
      labelStyle: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: AppColors.darkText,
      ),
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
      indicatorColor: active,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 26,
          color: selected ? accent.primary : AppColors.darkMuted,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return GoogleFonts.inter(
          fontSize: 12.2,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? AppColors.darkText : AppColors.darkMuted,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: surface,
      indicatorColor: active,
      selectedIconTheme: IconThemeData(color: accent.primary, size: 24),
      unselectedIconTheme: const IconThemeData(
        color: AppColors.darkMuted,
        size: 24,
      ),
      selectedLabelTextStyle: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: accent.primary,
      ),
      unselectedLabelTextStyle: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: AppColors.darkMuted,
      ),
    ),
  );
  _cachedTheme = built;
  return built;
}
