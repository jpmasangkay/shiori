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

enum LibrarySort { dateAdded, alphabetical }

extension LibrarySortLabel on LibrarySort {
  String get label => switch (this) {
        LibrarySort.dateAdded => 'Date added',
        LibrarySort.alphabetical => 'Alphabetically',
      };
}

/// Library display preferences, edited from the bottom sheet.
class DisplaySettings extends ChangeNotifier {
  DisplayMode mode = DisplayMode.compactGrid;
  int columns = 3;
  bool categoryTabs = true;
  LibrarySort sort = LibrarySort.dateAdded;

  void update(void Function() change) {
    change();
    notifyListeners();
  }
}

final displaySettings = DisplaySettings();
