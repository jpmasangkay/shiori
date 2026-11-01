import 'package:flutter/foundation.dart';

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

  DisplayMode mode = DisplayMode.compactGrid;
  int columns = 3;
  bool categoryTabs = true;
  LibrarySort sort = LibrarySort.dateAdded;

  LibrarySort get librarySort => sort;
  set librarySort(LibrarySort val) => update(() => sort = val);

  void update(void Function() change) {
    change();
    notifyListeners();
  }
}

final displaySettings = DisplaySettings();
