import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// Pure-black AMOLED design tokens.
class AppColors {
  AppColors._();

  static const bg = Color(0xFF000000);
  static const amoledBg = Color(0xFF000000);
  static const surface = Color(0xFF0A0A0A);
  static const amoledSurface = Color(0xFF0A0A0A);
  static const surfaceHigh = Color(0xFF141414);
  static const amoledSurfaceHigh = Color(0xFF141414);
  static const text = Color(0xFFEDEDEF);
  static const muted = Color(0xFF9A9CA6); // WCAG AA (~7.5:1 on #000000)
  static const read = Color(0xFF70737D);
  static const primary = Color(0xFFADC6FF);
  static const onPrimary = Color(0xFF002E69);
  static const active = Color(0xFF102A45);
  static const outline = Color(0xFF222226);
  static const black = Color(0xFF000000);
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

  bool get isAmoled => true;

  Color get currentBg => AppColors.bg;
  Color get currentSurface => AppColors.surface;
  Color get currentSurfaceHigh => AppColors.surfaceHigh;

  Future<void> init() async {
    _updateSystemUI();
  }

  void _updateSystemUI() {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppColors.bg,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }
}

ThemeData? _cachedTheme;

ThemeData buildTheme() {
  final existing = _cachedTheme;
  if (existing != null) return existing;

  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.bg,
    canvasColor: AppColors.surface,
    cardColor: AppColors.surface,
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

  final built = base.copyWith(
    textTheme: textTheme,
    splashFactory: InkRipple.splashFactory,
    dividerColor: AppColors.outline,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.text,
      elevation: 0,
      titleTextStyle: AppText.title,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      modalBackgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: AppText.sheetTitle,
      contentTextStyle: AppText.body.copyWith(color: AppColors.muted),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: AppText.body,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppColors.outline),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      textStyle: AppText.body,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.outline),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: AppColors.surface,
      selectedColor: AppColors.active,
      side: const BorderSide(color: AppColors.outline),
      labelStyle: AppText.chip,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: ZoomPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: ZoomPageTransitionsBuilder(),
        TargetPlatform.linux: ZoomPageTransitionsBuilder(),
      },
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 74,
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: AppColors.active,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 26,
          color: selected ? AppColors.primary : AppColors.muted,
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
