import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DisplayMode { compactGrid, comfortableGrid, coverOnlyGrid, list }

extension DisplayModeLabel on DisplayMode {
  String get label => switch (this) {
        DisplayMode.compactGrid => 'Compact Grid',
        DisplayMode.comfortableGrid => 'Comfortable Grid',
        DisplayMode.coverOnlyGrid => 'Cover-only Grid',
        DisplayMode.list => 'List',
      };
}

/// Expanded library sort options (#19)
enum LibrarySort { dateAdded, alphabetical, lastRead, lastUpdated, unreadCount }

extension LibrarySortLabel on LibrarySort {
  String get label => switch (this) {
        LibrarySort.dateAdded => 'Date added',
        LibrarySort.alphabetical => 'Alphabetically',
        LibrarySort.lastRead => 'Last read',
        LibrarySort.lastUpdated => 'Last updated',
        LibrarySort.unreadCount => 'Unread count',
      };
}

/// Library display preferences, edited from the bottom sheet or direct sort button (#19)
class DisplaySettings extends ChangeNotifier {
  static final DisplaySettings instance = displaySettings;

  static const _keyMode = 'library_display_mode';
  static const _keyColumns = 'library_display_columns';
  static const _keyCategoryTabs = 'library_display_category_tabs';
  static const _keySort = 'library_display_sort';

  DisplayMode mode = DisplayMode.compactGrid;
  int columns = 3;
  bool categoryTabs = true;
  LibrarySort sort = LibrarySort.dateAdded;

  LibrarySort get librarySort => sort;
  set librarySort(LibrarySort val) => update(() => sort = val);

  SharedPreferences? _prefs;

  DisplaySettings() {
    _loadFromPrefs();
  }

  Future<void> init() async {
    await _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final modeStr = _prefs?.getString(_keyMode);
      if (modeStr != null) {
        mode = DisplayMode.values.cast<DisplayMode?>().firstWhere(
              (m) => m?.name == modeStr,
              orElse: () => null,
            ) ?? mode;
      }
      final cols = _prefs?.getInt(_keyColumns);
      if (cols != null && cols >= 2 && cols <= 5) {
        columns = cols;
      }
      final tabs = _prefs?.getBool(_keyCategoryTabs);
      if (tabs != null) {
        categoryTabs = tabs;
      }
      final sortStr = _prefs?.getString(_keySort);
      if (sortStr != null) {
        sort = LibrarySort.values.cast<LibrarySort?>().firstWhere(
              (s) => s?.name == sortStr,
              orElse: () => null,
            ) ?? sort;
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveToPrefs() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      await _prefs?.setString(_keyMode, mode.name);
      await _prefs?.setInt(_keyColumns, columns);
      await _prefs?.setBool(_keyCategoryTabs, categoryTabs);
      await _prefs?.setString(_keySort, sort.name);
    } catch (_) {}
  }

  Future<void> save() => _saveToPrefs();

  Future<void> update(void Function() change) async {
    change();
    notifyListeners();
    await _saveToPrefs();
  }
}

final displaySettings = DisplaySettings();
