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
  static const _keySortAscending = 'library_display_sort_ascending';
  static const _keyFilterDownloaded = 'library_filter_downloaded';
  static const _keyFilterUnread = 'library_filter_unread';
  static const _keyFilterCompleted = 'library_filter_completed';
  static const _keyFilterTracked = 'library_filter_tracked';
  static const _keyShowDownloadBadges = 'library_show_download_badges';
  static const _keyShowContinueReadingButton = 'library_show_continue_reading_btn';
  static const _keyShowEmptyCategories = 'library_show_empty_categories';
  static const _keyExcludedUpdateCategories = 'library_excluded_update_categories';

  DisplayMode mode = DisplayMode.compactGrid;
  int columns = 3;
  bool categoryTabs = true;
  LibrarySort sort = LibrarySort.dateAdded;
  bool sortAscending = false;

  bool filterDownloaded = false;
  bool filterUnread = false;
  bool filterCompleted = false;
  bool filterTracked = false;
  bool showDownloadBadges = true;
  bool showContinueReadingButton = true;
  bool showEmptyCategories = false;
  Set<String> excludedUpdateCategoryIds = {};

  bool get hasActiveFilters =>
      filterDownloaded || filterUnread || filterCompleted || filterTracked;

  void clearFilters() {
    update(() {
      filterDownloaded = false;
      filterUnread = false;
      filterCompleted = false;
      filterTracked = false;
    });
  }

  /// Selects [next], or toggles ascending/descending if already selected.
  Future<void> setSort(LibrarySort next) {
    return update(() {
      if (sort == next) {
        sortAscending = !sortAscending;
      } else {
        sort = next;
        sortAscending = next == LibrarySort.alphabetical;
      }
    });
  }

  Future<void> toggleExcludedUpdateCategory(String categoryId) {
    return update(() {
      if (excludedUpdateCategoryIds.contains(categoryId)) {
        excludedUpdateCategoryIds.remove(categoryId);
      } else {
        excludedUpdateCategoryIds.add(categoryId);
      }
    });
  }

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
      sortAscending = _prefs?.getBool(_keySortAscending) ??
          (sort == LibrarySort.alphabetical);
      filterDownloaded = _prefs?.getBool(_keyFilterDownloaded) ?? false;
      filterUnread = _prefs?.getBool(_keyFilterUnread) ?? false;
      filterCompleted = _prefs?.getBool(_keyFilterCompleted) ?? false;
      filterTracked = _prefs?.getBool(_keyFilterTracked) ?? false;
      showDownloadBadges = _prefs?.getBool(_keyShowDownloadBadges) ?? true;
      showContinueReadingButton =
          _prefs?.getBool(_keyShowContinueReadingButton) ?? true;
      showEmptyCategories = _prefs?.getBool(_keyShowEmptyCategories) ?? false;
      excludedUpdateCategoryIds =
          (_prefs?.getStringList(_keyExcludedUpdateCategories) ?? const [])
              .toSet();
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
      await _prefs?.setBool(_keySortAscending, sortAscending);
      await _prefs?.setBool(_keyFilterDownloaded, filterDownloaded);
      await _prefs?.setBool(_keyFilterUnread, filterUnread);
      await _prefs?.setBool(_keyFilterCompleted, filterCompleted);
      await _prefs?.setBool(_keyFilterTracked, filterTracked);
      await _prefs?.setBool(_keyShowDownloadBadges, showDownloadBadges);
      await _prefs?.setBool(
        _keyShowContinueReadingButton,
        showContinueReadingButton,
      );
      await _prefs?.setBool(_keyShowEmptyCategories, showEmptyCategories);
      await _prefs?.setStringList(
        _keyExcludedUpdateCategories,
        excludedUpdateCategoryIds.toList(),
      );
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
