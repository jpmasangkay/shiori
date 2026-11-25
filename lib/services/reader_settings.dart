import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReaderBackground {
  black('black', 'AMOLED Black', Color(0xFF000000)),
  darkGray('gray', 'Dark Gray', Color(0xFF1A1B1E)),
  white('white', 'Paper White', Color(0xFFF5F5F5)),
  sepia('sepia', 'Warm Sepia', Color(0xFFF4ECD8));

  const ReaderBackground(this.key, this.label, this.color);
  final String key;
  final String label;
  final Color color;

  static ReaderBackground fromKey(String? key) {
    for (final bg in values) {
      if (bg.key == key) return bg;
    }
    return ReaderBackground.black;
  }
}

enum ReaderOrientation {
  free('free', 'Free'),
  portrait('portrait', 'Portrait'),
  landscape('landscape', 'Landscape');

  const ReaderOrientation(this.key, this.label);
  final String key;
  final String label;

  static ReaderOrientation fromKey(String? key) {
    for (final o in values) {
      if (o.key == key) return o;
    }
    return ReaderOrientation.free;
  }
}

class ReaderSettings extends ChangeNotifier {
  ReaderSettings._();
  static final ReaderSettings instance = ReaderSettings._();

  static const _keyDefaultDirection = 'reader_default_direction';
  static const _keyFitMode = 'reader_fit_mode';
  static const _keyEnableTapZones = 'reader_enable_tap_zones';
  static const _keyInvertTapZones = 'reader_invert_tap_zones';
  static const _keyWebtoonTapScroll = 'reader_webtoon_tap_scroll';
  static const _keySkipDuplicateChapters = 'reader_skip_duplicate_chapters';
  static const _keyOrientation = 'reader_orientation';
  static const _keyBrightness = 'reader_brightness';
  static const _keyTint = 'reader_tint';
  static const _keyDataSaver = 'reader_data_saver';
  static const _keyImmersiveFullscreen = 'reader_immersive_fullscreen';
  static const _keyAutoScrollSpeed = 'reader_auto_scroll_speed';
  static const _keyKeepScreenOn = 'reader_keep_screen_on';
  static const _keyVolumeKeyNav = 'reader_volume_key_nav';
  static const _keyInvertVolumeKeys = 'reader_invert_volume_keys';
  static const _keyShowStatusBar = 'reader_show_status_bar';
  static const _keyBackground = 'reader_background';
  static const _keyCropBorders = 'reader_crop_borders';
  static const _keyDualPageSpread = 'reader_dual_page_spread';
  static const _keySplitWidePages = 'reader_split_wide_pages';
  static const _keyWebtoonSidePadding = 'reader_webtoon_side_padding';
  static const _keyGrayscale = 'reader_grayscale';
  static const _keyInvertColors = 'reader_invert_colors';

  String defaultDirection = 'automatic';
  BoxFit fitMode = BoxFit.fitWidth;
  bool enableTapZones = true;
  bool invertTapZones = false;
  bool webtoonTapScroll = false;
  bool skipDuplicateChapters = true;
  ReaderOrientation orientation = ReaderOrientation.free;
  double brightness = 1.0;
  double tint = 0.0;
  bool dataSaver = false;
  bool immersiveFullscreen = true;
  double autoScrollSpeed = 1.0;
  bool keepScreenOn = true;
  bool volumeKeyNavigation = false;
  bool invertVolumeKeys = false;
  bool showReadingStatusBar = true;
  ReaderBackground background = ReaderBackground.black;
  bool cropBorders = false;
  bool dualPageSpread = true;
  bool splitWidePages = false;
  double webtoonSidePadding = 0.0; // 0.0 to 0.25 fraction per side
  bool grayscaleFilter = false;
  bool invertColors = false;

  SharedPreferences? _prefs;

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      defaultDirection = _prefs?.getString(_keyDefaultDirection) ?? 'automatic';
      final fitStr = _prefs?.getString(_keyFitMode);
      if (fitStr == 'contain') {
        fitMode = BoxFit.contain;
      } else {
        fitMode = BoxFit.fitWidth;
      }
      enableTapZones = _prefs?.getBool(_keyEnableTapZones) ?? true;
      invertTapZones = _prefs?.getBool(_keyInvertTapZones) ?? false;
      webtoonTapScroll = _prefs?.getBool(_keyWebtoonTapScroll) ?? false;
      skipDuplicateChapters = _prefs?.getBool(_keySkipDuplicateChapters) ?? true;
      orientation = ReaderOrientation.fromKey(_prefs?.getString(_keyOrientation));
      brightness = (_prefs?.getDouble(_keyBrightness) ?? 1.0).clamp(0.1, 1.0);
      tint = (_prefs?.getDouble(_keyTint) ?? 0.0).clamp(0.0, 1.0);
      dataSaver = _prefs?.getBool(_keyDataSaver) ?? false;
      immersiveFullscreen = _prefs?.getBool(_keyImmersiveFullscreen) ?? true;
      autoScrollSpeed = (_prefs?.getDouble(_keyAutoScrollSpeed) ?? 1.0).clamp(0.25, 4.0);
      keepScreenOn = _prefs?.getBool(_keyKeepScreenOn) ?? true;
      volumeKeyNavigation = _prefs?.getBool(_keyVolumeKeyNav) ?? false;
      invertVolumeKeys = _prefs?.getBool(_keyInvertVolumeKeys) ?? false;
      showReadingStatusBar = _prefs?.getBool(_keyShowStatusBar) ?? true;
      background = ReaderBackground.fromKey(_prefs?.getString(_keyBackground));
      cropBorders = _prefs?.getBool(_keyCropBorders) ?? false;
      dualPageSpread = _prefs?.getBool(_keyDualPageSpread) ?? true;
      splitWidePages = _prefs?.getBool(_keySplitWidePages) ?? false;
      webtoonSidePadding = (_prefs?.getDouble(_keyWebtoonSidePadding) ?? 0.0).clamp(0.0, 0.25);
      grayscaleFilter = _prefs?.getBool(_keyGrayscale) ?? false;
      invertColors = _prefs?.getBool(_keyInvertColors) ?? false;
      notifyListeners();
    } catch (_) {}
  }

  /// Returns the per-manga direction override if present; otherwise falls back to [defaultDirection].
  String getReadingDirectionForManga(String mangaId) {
    if (mangaId.isNotEmpty) {
      final perManga = _prefs?.getString('reader_direction_$mangaId');
      if (perManga != null && perManga.isNotEmpty) return perManga;
    }
    return defaultDirection;
  }

  bool hasPerMangaDirectionOverride(String mangaId) {
    if (mangaId.isEmpty) return false;
    final perManga = _prefs?.getString('reader_direction_$mangaId');
    return perManga != null && perManga.isNotEmpty;
  }

  /// Sets the global default reading direction (does not overwrite per-manga overrides).
  Future<void> setDefaultReadingDirection(String direction) async {
    defaultDirection = direction;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setString(_keyDefaultDirection, direction);
    } catch (_) {}
  }

  /// Sets a per-manga reading direction override without clobbering [defaultDirection].
  /// Pass an empty [mangaId] only when updating the global default.
  Future<void> setReadingDirection(String mangaId, String direction) async {
    if (mangaId.isEmpty) {
      await setDefaultReadingDirection(direction);
      return;
    }
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setString('reader_direction_$mangaId', direction);
    } catch (_) {}
  }

  Future<void> clearReadingDirectionOverride(String mangaId) async {
    if (mangaId.isEmpty) return;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.remove('reader_direction_$mangaId');
    } catch (_) {}
  }

  Future<void> setFitMode(BoxFit mode) async {
    fitMode = mode;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setString(_keyFitMode, mode == BoxFit.contain ? 'contain' : 'fitWidth');
    } catch (_) {}
  }

  Future<void> setEnableTapZones(bool val) async {
    enableTapZones = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyEnableTapZones, val);
    } catch (_) {}
  }

  Future<void> setInvertTapZones(bool val) async {
    invertTapZones = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyInvertTapZones, val);
    } catch (_) {}
  }

  Future<void> setBrightness(double val) async {
    brightness = val.clamp(0.1, 1.0);
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setDouble(_keyBrightness, brightness);
    } catch (_) {}
  }

  Future<void> setTint(double val) async {
    tint = val.clamp(0.0, 1.0);
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setDouble(_keyTint, tint);
    } catch (_) {}
  }

  Future<void> setDataSaver(bool val) async {
    dataSaver = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyDataSaver, val);
    } catch (_) {}
  }

  Future<void> setImmersiveFullscreen(bool val) async {
    immersiveFullscreen = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyImmersiveFullscreen, val);
    } catch (_) {}
  }

  Future<void> setAutoScrollSpeed(double val) async {
    autoScrollSpeed = val.clamp(0.25, 4.0);
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setDouble(_keyAutoScrollSpeed, autoScrollSpeed);
    } catch (_) {}
  }

  Future<void> setKeepScreenOn(bool val) async {
    keepScreenOn = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyKeepScreenOn, val);
    } catch (_) {}
  }

  Future<void> setVolumeKeyNavigation(bool val) async {
    volumeKeyNavigation = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyVolumeKeyNav, val);
    } catch (_) {}
  }

  Future<void> setInvertVolumeKeys(bool val) async {
    invertVolumeKeys = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyInvertVolumeKeys, val);
    } catch (_) {}
  }

  Future<void> setShowReadingStatusBar(bool val) async {
    showReadingStatusBar = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyShowStatusBar, val);
    } catch (_) {}
  }

  Future<void> setBackground(ReaderBackground bg) async {
    background = bg;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setString(_keyBackground, bg.key);
    } catch (_) {}
  }

  Future<void> setCropBorders(bool val) async {
    cropBorders = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyCropBorders, val);
    } catch (_) {}
  }

  Future<void> setDualPageSpread(bool val) async {
    dualPageSpread = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyDualPageSpread, val);
    } catch (_) {}
  }

  Future<void> setSplitWidePages(bool val) async {
    splitWidePages = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keySplitWidePages, val);
    } catch (_) {}
  }

  Future<void> setWebtoonSidePadding(double val) async {
    webtoonSidePadding = val.clamp(0.0, 0.25);
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setDouble(_keyWebtoonSidePadding, webtoonSidePadding);
    } catch (_) {}
  }

  Future<void> setGrayscaleFilter(bool val) async {
    grayscaleFilter = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyGrayscale, val);
    } catch (_) {}
  }

  Future<void> setInvertColors(bool val) async {
    invertColors = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyInvertColors, val);
    } catch (_) {}
  }

  Future<void> setWebtoonTapScroll(bool val) async {
    webtoonTapScroll = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyWebtoonTapScroll, val);
    } catch (_) {}
  }

  Future<void> setSkipDuplicateChapters(bool val) async {
    skipDuplicateChapters = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keySkipDuplicateChapters, val);
    } catch (_) {}
  }

  Future<void> setOrientation(ReaderOrientation value) async {
    orientation = value;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setString(_keyOrientation, value.key);
    } catch (_) {}
  }
}
