import 'package:flutter/foundation.dart';

/// Cover art assets. The design cycles through 9 photos; we cycle through the
/// bundled covers in the same way.
const _covers = [
  'assets/covers/c0.jpg',
  'assets/covers/c1.jpg',
  'assets/covers/c2.jpg',
  'assets/covers/c3.jpg',
];

String coverAsset(int i) => _covers[i % _covers.length];

const titles = [
  'The Breaker: Eternal Force',
  'Omniscient Reader',
  'Return of the Mount Hua Sect',
  'The S-Classes That I Raised',
  'Nano Machine',
  'Legend of the Northern Blade',
  'Mercenary Enrollment',
  'Eleceed',
  'The World After the Fall',
];

String titleAt(int i) => titles[i % titles.length];

const libraryTabs = [
  'Reading 14',
  'Manhwa 42',
  'Manga 28',
  'Manhua 9',
  'Completed',
];

class UpdateEntry {
  const UpdateEntry(this.cover, this.title, this.subtitle);
  final int cover;
  final String title;
  final String subtitle;
}

const updateRows = [
  UpdateEntry(2, 'Solo Leveling: Ragnarok', 'Chapter 92 · Flame Comics'),
  UpdateEntry(4, 'Nano Machine', 'Chapter 248 · Asura Scans'),
  UpdateEntry(0, 'The Breaker: Eternal Force', 'Chapter 184 · Reaper Scans'),
  UpdateEntry(6, 'Mercenary Enrollment', 'Chapter 211 · Luminous Scans'),
  UpdateEntry(1, 'Omniscient Reader', 'Chapter 231 · Flame Comics'),
  UpdateEntry(7, 'Eleceed', 'Chapter 324 · Void Scans'),
  UpdateEntry(5, 'Legend of the Northern Blade', 'Chapter 202 · Leviatan'),
];

enum DownloadState { download, progress, check }

class ChapterEntry {
  const ChapterEntry({
    required this.num,
    required this.title,
    required this.meta,
    this.read = false,
    this.state = DownloadState.download,
  });

  final int num;
  final String title;
  final String meta;
  final bool read;
  final DownloadState state;
}

const _filler = [
  'Echoes of the Past',
  'The Hidden Valley',
  'Blade in the Mist',
  'A Debt Repaid',
  'Shadow of the Sect',
  'The Long Road',
  'Iron Will',
  'Silent Moon',
];

/// 184 chapters: the first five match the design exactly, the rest are
/// generated so the list scrolls like the real app.
List<ChapterEntry> buildChapters() {
  const head = [
    ChapterEntry(num: 184, title: 'The Final Gate', meta: 'Today · 32 pages'),
    ChapterEntry(
      num: 183,
      title: 'Unbroken Resolve',
      meta: 'Yesterday · 28 pages',
      state: DownloadState.progress,
    ),
    ChapterEntry(
      num: 182,
      title: 'The Visitor',
      meta: 'Oct 14 · 31 pages',
      read: true,
      state: DownloadState.check,
    ),
    ChapterEntry(
      num: 181,
      title: 'A Quiet Warning',
      meta: 'Oct 10 · 26 pages',
      read: true,
      state: DownloadState.check,
    ),
    ChapterEntry(
      num: 180,
      title: 'Path of the Dragon',
      meta: 'Oct 6 · 34 pages',
      read: true,
    ),
  ];
  final rest = List.generate(179, (i) {
    final n = 179 - i;
    return ChapterEntry(
      num: n,
      title: _filler[n % _filler.length],
      meta: 'Sep ${(n % 28) + 1} · ${24 + n % 11} pages',
      read: true,
    );
  });
  return [...head, ...rest];
}

enum DisplayMode { compactGrid, comfortableGrid, coverOnlyGrid, list }

extension DisplayModeLabel on DisplayMode {
  String get label => switch (this) {
        DisplayMode.compactGrid => 'Compact Grid',
        DisplayMode.comfortableGrid => 'Comfortable Grid',
        DisplayMode.coverOnlyGrid => 'Cover-only Grid',
        DisplayMode.list => 'List',
      };
}

/// Library display preferences, edited from the bottom sheet.
class DisplaySettings extends ChangeNotifier {
  DisplayMode mode = DisplayMode.compactGrid;
  int columns = 3;
  bool unreadCount = true;
  bool downloaded = true;
  bool localBadge = false;
  bool categoryTabs = true;

  void update(void Function() change) {
    change();
    notifyListeners();
  }
}

final displaySettings = DisplaySettings();
