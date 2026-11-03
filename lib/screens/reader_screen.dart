import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/extension_bridge.dart';
import '../services/extension_service.dart';
import '../services/tracker_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/skeleton.dart';

enum ReaderMode {
  automatic,   // ⚡ Automatic: Detects based on comic type (Manga: RTL, Manhwa: Webtoon, Other: LTR)
  rightToLeft, // 🇯🇵 Standard Manga: Right to Left
  webtoon,     // 🇰🇷 Manhwa / Webtoon: Continuous vertical scroll
  leftToRight, // 🇨🇳 Manhua / Western: Left to Right
}

extension ReaderModeInfo on ReaderMode {
  String get label => switch (this) {
        ReaderMode.automatic => 'Automatic',
        ReaderMode.rightToLeft => 'RTL (Manga)',
        ReaderMode.webtoon => 'Webtoon',
        ReaderMode.leftToRight => 'Left-to-Right',
      };

  String get shortLabel => switch (this) {
        ReaderMode.automatic => 'Auto',
        ReaderMode.rightToLeft => 'RTL',
        ReaderMode.webtoon => 'Webtoon',
        ReaderMode.leftToRight => 'LTR',
      };

  IconData get icon => switch (this) {
        ReaderMode.automatic => Icons.auto_awesome_rounded,
        ReaderMode.rightToLeft => Icons.arrow_back_rounded,
        ReaderMode.webtoon => Icons.swap_vert_rounded,
        ReaderMode.leftToRight => Icons.arrow_forward_rounded,
      };
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    this.chapterId,
    required this.mangaId,
    required this.mangaTitle,
    this.chapterNumber,
    this.chapterTitle,
    this.coverUrl,
    this.chapters = const [],
    this.initialIndex = 0,
    this.mangaType,
    this.tags,
  });

  final String? chapterId;
  final String mangaId;
  final String mangaTitle;
  final String? chapterNumber;
  final String? chapterTitle;
  final String? coverUrl;
  final List<ChapterItem> chapters;
  final int initialIndex;
  final String? mangaType;
  final List<String>? tags;

  /// Resolves the automatic reading mode based on comic metadata:
  /// - Manga -> Right to Left (RTL paged)
  /// - Manhwa / Webtoon -> Webtoon (continuous vertical scroll)
  /// - Other / Else (e.g. Manhua, Western comic) -> Left to Right (LTR paged)
  static ReaderMode resolveAutomaticMode({
    String? type,
    String? mangaId,
    String? title,
    List<String>? tags,
  }) {
    final cleanType = type?.trim().toLowerCase() ?? '';
    final cleanId = mangaId?.trim().toLowerCase() ?? '';
    final cleanTitle = title?.trim().toLowerCase() ?? '';
    final lowerTags = tags?.map((t) => t.trim().toLowerCase()).toList() ?? const [];

    bool hasKeyword(String keyword) {
      if (cleanType == keyword || cleanType.contains(keyword)) return true;
      if (lowerTags.any((t) => t == keyword || t.contains(keyword))) return true;
      if (cleanTitle.contains('[$keyword]') || cleanTitle.contains('($keyword)')) return true;
      return false;
    }

    // 1. Manhwa / Webtoon: Korean continuous vertical scroll
    final isManhwa = hasKeyword('manhwa') ||
        hasKeyword('manwha') ||
        hasKeyword('webtoon') ||
        hasKeyword('korean') ||
        cleanId.startsWith('asura:') ||
        cleanId.startsWith('flame:');

    if (isManhwa) {
      return ReaderMode.webtoon;
    }

    // 2. Explicit other comic formats (Manhua / Chinese / Western comic / Webcomic)
    final isOtherExplicit = hasKeyword('manhua') ||
        hasKeyword('chinese') ||
        hasKeyword('comic') ||
        hasKeyword('western') ||
        hasKeyword('webcomic');

    if (isOtherExplicit) {
      return ReaderMode.leftToRight;
    }

    // 3. Manga: Japanese standard right-to-left
    final isManga = hasKeyword('manga') ||
        hasKeyword('japanese') ||
        cleanId.startsWith('pill:') ||
        cleanId.startsWith('katana:') ||
        cleanId.startsWith('mread:');

    if (isManga) {
      return ReaderMode.rightToLeft;
    }

    // 4. Default fallback: other else -> left to right
    return ReaderMode.leftToRight;
  }

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late List<ChapterItem> _chapters;
  late int _currentChapterIndex;

  // Pages cache keyed by chapter ID
  final Map<String, List<String>> _pagesCache = {};
  final Map<String, List<String>> _dataSaverCache = {};
  final Set<String> _loadingChapterIds = {};
  final Map<String, String> _chapterErrors = {};
  final Set<String> _prefetchedUrls = {};

  // Webtoon continuous feed. Always an ascending, contiguous run of chapter
  // indices so chapters can never appear out of order or be skipped.
  final List<int> _webtoonLoadedIndices = [];
  final Map<String, _PageSlot> _pageSlots = {};
  final GlobalKey _listKey = GlobalKey();
  DateTime _trackingPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  int _totalPages = 1;
  int _page = 1;
  late final ValueNotifier<int> _pageNotifier;
  final Set<String> _finishedChapterIds = {};
  Timer? _progressDebounceTimer;
  DateTime _lastTrackTime = DateTime.fromMillisecondsSinceEpoch(0);
  bool _chrome = true;
  bool _advancing = false;

  ReaderMode _selectedMode = ReaderMode.automatic;
  late ReaderMode _resolvedAutoMode;

  ReaderMode get _effectiveMode =>
      _selectedMode == ReaderMode.automatic ? _resolvedAutoMode : _selectedMode;
  ReaderMode get _mode => _effectiveMode;

  ReaderMode get selectedMode => _selectedMode;
  ReaderMode get effectiveMode => _effectiveMode;

  BoxFit _fitMode = BoxFit.fitWidth;
  bool _enableTapZones = true;
  bool _invertTapZones = false;
  double _brightness = 1.0;
  double _tint = 0.0;

  final _scrollController = ScrollController();
  late PageController _pageController;

  ChapterItem get _currentChapter {
    if (_chapters.isEmpty) {
      return ChapterItem(
        id: widget.chapterId ?? '',
        number: widget.chapterNumber,
        title: widget.chapterTitle ?? 'Chapter',
      );
    }
    final idx = _currentChapterIndex.clamp(0, _chapters.length - 1);
    return _chapters[idx];
  }

  String get _chapterLabel {
    final c = _currentChapter;
    final n = c.number;
    return (n != null && n.isNotEmpty) ? 'Chapter $n' : (c.title.isNotEmpty ? c.title : 'Chapter');
  }

  bool get _hasNextChapter => _currentChapterIndex + 1 < _chapters.length;
  bool get _hasPrevChapter => _currentChapterIndex - 1 >= 0;

  // keepPage: false stops PageStorage from restoring the previous chapter's
  // page index when the PageView is rebuilt for a different chapter.
  PageController _newPageController(int initialPage) =>
      PageController(initialPage: initialPage, keepPage: false);

  void _pauseTracking([int milliseconds = 500]) {
    _trackingPausedUntil = DateTime.now().add(Duration(milliseconds: milliseconds));
  }

  @override
  void initState() {
    super.initState();
    _pageNotifier = ValueNotifier<int>(_page);
    _pageController = _newPageController(0);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

    // 1. Initial resolution of automatic reading direction based on metadata
    final cached = ApiService.instance.libraryRepo.knownManga[widget.mangaId] ??
        ApiService.instance.libraryRepo.localLibrary[widget.mangaId];

    _resolvedAutoMode = ReaderScreen.resolveAutomaticMode(
      type: widget.mangaType ?? cached?.type,
      mangaId: widget.mangaId,
      title: widget.mangaTitle.isNotEmpty ? widget.mangaTitle : (cached?.title ?? ''),
      tags: widget.tags ?? cached?.tags,
    );

    // 2. Load preferences
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        final savedModeStr = prefs.getString('reader_direction_${widget.mangaId}');
        ReaderMode? saved;
        if (savedModeStr != null) {
          saved = ReaderMode.values.cast<ReaderMode?>().firstWhere(
                (m) => m?.name == savedModeStr,
                orElse: () => null,
              );
        }

        final oldEffective = _effectiveMode;
        setState(() {
          _enableTapZones = prefs.getBool('reader_enable_tap_zones') ?? true;
          _invertTapZones = prefs.getBool('reader_invert_tap_zones') ?? false;
          _brightness = prefs.getDouble('reader_brightness') ?? 1.0;
          _tint = prefs.getDouble('reader_tint') ?? 0.0;
          if (saved != null) {
            _selectedMode = saved;
          }
        });

        if (_effectiveMode != oldEffective) {
          final oldCtrl = _pageController;
          _pageController = _newPageController(_page - 1);
          _webtoonLoadedIndices
            ..clear()
            ..add(_currentChapterIndex);
          _pageSlots.clear();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            oldCtrl.dispose();
            if (mounted && _effectiveMode == ReaderMode.webtoon && _page > 1) {
              _scrollToWebtoonPage(_page);
            }
          });
        }
      }
    });

    // 3. Asynchronous refinement if metadata was not yet in cache
    if ((widget.mangaType == null || widget.mangaType!.isEmpty) &&
        cached == null &&
        widget.mangaId.isNotEmpty) {
      ApiService.instance.getManga(widget.mangaId).then((m) {
        if (!mounted) return;
        final updatedAuto = ReaderScreen.resolveAutomaticMode(
          type: m.type,
          mangaId: m.id,
          title: m.title,
          tags: m.tags,
        );
        if (updatedAuto != _resolvedAutoMode) {
          final oldEffective = _effectiveMode;
          setState(() {
            _resolvedAutoMode = updatedAuto;
          });
          if (_selectedMode == ReaderMode.automatic && _effectiveMode != oldEffective) {
            final oldCtrl = _pageController;
            setState(() {
              _pageController = _newPageController(_page - 1);
              _webtoonLoadedIndices
                ..clear()
                ..add(_currentChapterIndex);
              _pageSlots.clear();
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              oldCtrl.dispose();
              if (mounted && _effectiveMode == ReaderMode.webtoon && _page > 1) {
                _scrollToWebtoonPage(_page);
              }
            });
          }
        }
      }).catchError((_) {});
    }

    // Setup chapters list
    if (widget.chapters.isNotEmpty) {
      _chapters = List<ChapterItem>.from(widget.chapters);
      if (widget.chapterId != null) {
        final matchIdx = _chapters.indexWhere((c) => c.id == widget.chapterId);
        _currentChapterIndex = matchIdx >= 0 ? matchIdx : widget.initialIndex.clamp(0, _chapters.length - 1);
      } else {
        _currentChapterIndex = widget.initialIndex.clamp(0, _chapters.length - 1);
      }
    } else {
      final fallback = ChapterItem(
        id: widget.chapterId ?? '',
        number: widget.chapterNumber,
        title: widget.chapterTitle ?? '',
      );
      _chapters = [fallback];
      _currentChapterIndex = 0;
    }

    _webtoonLoadedIndices.add(_currentChapterIndex);
    _loadChapter(_currentChapterIndex);
  }

  void _setEnableTapZones(bool val) {
    setState(() => _enableTapZones = val);
    SharedPreferences.getInstance().then((prefs) => prefs.setBool('reader_enable_tap_zones', val));
  }

  void _setInvertTapZones(bool val) {
    setState(() => _invertTapZones = val);
    SharedPreferences.getInstance().then((prefs) => prefs.setBool('reader_invert_tap_zones', val));
  }

  void _setBrightness(double val) {
    setState(() => _brightness = val.clamp(0.2, 1.0));
    SharedPreferences.getInstance().then((prefs) => prefs.setDouble('reader_brightness', _brightness));
  }

  void _setTint(double val) {
    setState(() => _tint = val.clamp(0.0, 1.0));
    SharedPreferences.getInstance().then((prefs) => prefs.setDouble('reader_tint', _tint));
  }

  void _showDisplaySheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('DISPLAY & COMFORT', style: AppText.sectionHeader),
                    if (_brightness < 0.99 || _tint > 0.01)
                      TextButton(
                        onPressed: () {
                          _setBrightness(1.0);
                          _setTint(0.0);
                          setSheetState(() {});
                        },
                        child: Text('Reset', style: AppText.caption.copyWith(color: AppColors.primary)),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(Icons.brightness_medium_rounded, size: 20, color: AppColors.muted),
                    const SizedBox(width: 8),
                    Text('Brightness', style: AppText.bodyMedium),
                    const Spacer(),
                    Text('${(_brightness * 100).round()}%', style: AppText.caption),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(ctx).copyWith(
                    activeTrackColor: AppColors.primary,
                    thumbColor: AppColors.primary,
                    inactiveTrackColor: AppColors.outline,
                  ),
                  child: Slider(
                    min: 0.2,
                    max: 1.0,
                    value: _brightness,
                    onChanged: (val) {
                      _setBrightness(val);
                      setSheetState(() {});
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.wb_sunny_rounded, size: 20, color: Color(0xFFFFA726)),
                    const SizedBox(width: 8),
                    Text('Eye-Care Warm Tint', style: AppText.bodyMedium),
                    const Spacer(),
                    Text('${(_tint * 100).round()}%', style: AppText.caption),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(ctx).copyWith(
                    activeTrackColor: const Color(0xFFFFA726),
                    thumbColor: const Color(0xFFFFA726),
                    inactiveTrackColor: AppColors.outline,
                  ),
                  child: Slider(
                    min: 0.0,
                    max: 1.0,
                    value: _tint,
                    onChanged: (val) {
                      _setTint(val);
                      setSheetState(() {});
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _flushProgress();
    _scrollController.dispose();
    _pageController.dispose();
    _pageNotifier.dispose();
    super.dispose();
  }

  /// Loads a chapter's pages. A chapter that fails to load (or has no pages) is
  /// recorded in [_chapterErrors] so the reader can show a Retry tile instead
  /// of silently skipping over it.
  Future<void> _loadChapter(int idx, {bool forceRefresh = false}) async {
    if (idx < 0 || idx >= _chapters.length) return;
    final chapter = _chapters[idx];
    if (!forceRefresh && _pagesCache.containsKey(chapter.id)) return;
    if (_loadingChapterIds.contains(chapter.id)) return;

    if (chapter.id.isEmpty) {
      setState(() => _chapterErrors[chapter.id] = 'This chapter is not available.');
      return;
    }

    setState(() {
      if (forceRefresh) {
        _pagesCache.remove(chapter.id);
        _dataSaverCache.remove(chapter.id);
      }
      _chapterErrors.remove(chapter.id);
      _loadingChapterIds.add(chapter.id);
    });

    try {
      final res = await ApiService.instance.getChapterPages(
        chapter.id,
        forceRefresh: forceRefresh,
      );
      if (res.pages.isEmpty) throw Exception('No pages found for this chapter.');
      _pagesCache[chapter.id] = res.pages;
      _dataSaverCache[chapter.id] = res.dataSaver;
      _loadingChapterIds.remove(chapter.id);
      if (!mounted) return;

      setState(() {
        if (idx == _currentChapterIndex) {
          _totalPages = res.pages.length;
          _page = _page.clamp(1, _totalPages);
        }
      });
      _precacheSlidingWindow(res.pages, 0);

      if (idx == _currentChapterIndex) {
        _syncProgress(_page);
        // Prefetch the next chapter so continuing to read has no loading gap.
        _loadChapter(idx + 1);
      }
    } catch (err) {
      _loadingChapterIds.remove(chapter.id);
      if (!mounted) return;
      setState(() => _chapterErrors[chapter.id] = err.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _reloadChapterPages(int idx) async {
    if (idx < 0 || idx >= _chapters.length) return;
    final chapter = _chapters[idx];
    final oldPages = _pagesCache[chapter.id] ?? const <String>[];
    for (final u in oldPages) {
      _prefetchedUrls.remove(u);
      if (u.startsWith('http')) {
        CachedNetworkImageProvider(u).evict().catchError((_) => false);
      }
    }
    await _loadChapter(idx, forceRefresh: true);
  }

  List<String> _fallbackUrlsFor(String chapterId, int pageIndex, String primaryUrl) {
    final fallbacks = <String>[];
    // If primaryUrl is a MangaDex@Home volunteer node, add official uploads.mangadex.org origin
    if (primaryUrl.contains('/data/') &&
        !primaryUrl.startsWith('https://uploads.mangadex.org/')) {
      final idx = primaryUrl.indexOf('/data/');
      if (idx != -1) {
        fallbacks.add('https://uploads.mangadex.org${primaryUrl.substring(idx)}');
      }
    }
    final savers = _dataSaverCache[chapterId];
    if (savers != null && pageIndex >= 0 && pageIndex < savers.length) {
      final saverUrl = savers[pageIndex];
      if (saverUrl.isNotEmpty && saverUrl != primaryUrl && !fallbacks.contains(saverUrl)) {
        fallbacks.add(saverUrl);
      }
    }
    return fallbacks;
  }

  void _precacheRange(List<String> pages, int start, int count) {
    if (!mounted || pages.isEmpty) return;
    final end = math.min(pages.length, start + count);
    for (var i = math.max(0, start); i < end; i++) {
      final p = pages[i];
      if (!_prefetchedUrls.add(p)) continue;
      if (p.startsWith('file://')) {
        precacheImage(FileImage(File(p.replaceFirst('file://', ''))), context, onError: (_, _) {});
      } else if (p.startsWith('http')) {
        precacheImage(
          CachedNetworkImageProvider(p, headers: imageHeadersForUrl(p)),
          context,
          onError: (_, _) {},
        );
      }
    }
  }

  void _precacheSlidingWindow(List<String> pages, int currentIndex, {int window = 2}) {
    if (!mounted || pages.isEmpty) return;
    final start = math.max(0, currentIndex - window);
    final count = (window * 2) + 1;
    _precacheRange(pages, start, count);
  }

  void _syncProgress(int currentPage) {
    if (widget.mangaId.isEmpty) return;
    final chapter = _currentChapter;
    if (chapter.id.isEmpty) return;

    final pages = _pagesCache[chapter.id];
    final actualTotal = pages?.length ?? _totalPages;
    final completed = pages != null && pages.isNotEmpty && currentPage >= actualTotal;
    if (completed) {
      _onChapterFinished(_currentChapterIndex);
    }

    _progressDebounceTimer?.cancel();
    _progressDebounceTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      ApiService.instance.saveProgress(
        mangaId: widget.mangaId,
        chapterId: chapter.id,
        mangaTitle: widget.mangaTitle,
        cover: widget.coverUrl,
        chapterNumber: chapter.number,
        chapterTitle: chapter.title,
        page: currentPage,
        totalPages: actualTotal,
        completed: completed,
      );
    });
  }

  void _flushProgress() {
    _progressDebounceTimer?.cancel();
    _progressDebounceTimer = null;
    if (widget.mangaId.isEmpty) return;
    final chapter = _currentChapter;
    if (chapter.id.isEmpty) return;

    final pages = _pagesCache[chapter.id];
    final actualTotal = pages?.length ?? _totalPages;
    final completed = pages != null && pages.isNotEmpty && _page >= actualTotal;
    if (completed) {
      _onChapterFinished(_currentChapterIndex);
    }

    ApiService.instance.saveProgress(
      mangaId: widget.mangaId,
      chapterId: chapter.id,
      mangaTitle: widget.mangaTitle,
      cover: widget.coverUrl,
      chapterNumber: chapter.number,
      chapterTitle: chapter.title,
      page: _page,
      totalPages: actualTotal,
      completed: completed,
    );
  }

  void _onChapterFinished(int finishedIdx) {
    if (finishedIdx < 0 || finishedIdx >= _chapters.length) return;
    final finished = _chapters[finishedIdx];
    if (finished.id.isEmpty) return;
    if (!_finishedChapterIds.add(finished.id)) return; // Avoid duplicate triggers

    // Automatically mark the finished chapter as read
    ApiService.instance.markChapterRead(widget.mangaId, finished.id, read: true);
    // Auto sync reading progress to AniList Tracker
    TrackerService.instance.onChapterFinished(
      mangaTitle: widget.mangaTitle,
      chapterNumber: finished.number,
    );
  }

  /// Jump to another chapter (bottom bar buttons / transition card). The
  /// webtoon feed is re-anchored on the new chapter and the page controller is
  /// replaced, so the new chapter always starts at its first page.
  void _switchToChapter(int newIndex) {
    if (newIndex < 0 || newIndex >= _chapters.length || newIndex == _currentChapterIndex) return;
    final currentPages = _pagesCache[_chapters[_currentChapterIndex].id];
    final currentTotal = currentPages?.length ?? _totalPages;
    if (currentPages != null && currentPages.isNotEmpty && _page >= currentTotal) {
      _onChapterFinished(_currentChapterIndex);
    }

    final chapter = _chapters[newIndex];
    final cached = _pagesCache[chapter.id];
    final oldController = _pageController;

    _pauseTracking(600);
    setState(() {
      _currentChapterIndex = newIndex;
      _page = 1;
      _totalPages = cached?.length ?? 1;
      _chapterErrors.remove(chapter.id);
      _webtoonLoadedIndices
        ..clear()
        ..add(newIndex);
      _pageSlots.clear();
      _pageController = _newPageController(0);
    });
    _pageNotifier.value = 1;
    WidgetsBinding.instance.addPostFrameCallback((_) => oldController.dispose());

    if (_scrollController.hasClients) _scrollController.jumpTo(0);

    if (cached != null) {
      _syncProgress(1);
      _loadChapter(newIndex + 1);
    } else {
      _loadChapter(newIndex);
    }
  }

  // ---- Webtoon feed tracking ----

  /// Appends the next chapter to the continuous feed. Never appends past a
  /// chapter that hasn't loaded, otherwise that chapter would be skipped.
  void _extendWebtoonFeed() {
    if (_webtoonLoadedIndices.isEmpty) return;
    final last = _webtoonLoadedIndices.last;
    final next = last + 1;
    if (next >= _chapters.length) return;
    if (!_pagesCache.containsKey(_chapters[last].id)) return;
    _onChapterFinished(last);
    setState(() => _webtoonLoadedIndices.add(next));
    _loadChapter(next);
  }

  bool _onWebtoonScroll(ScrollNotification notif) {
    if (notif.depth != 0) return false;
    if (notif is! ScrollUpdateNotification && notif is! ScrollEndNotification) return false;

    if (notif.metrics.extentAfter < 2000) _extendWebtoonFeed();

    // Reached bottom of loaded webtoon feed -> mark completed chapters read
    if (notif.metrics.pixels >= notif.metrics.maxScrollExtent - 200) {
      for (final idx in _webtoonLoadedIndices) {
        final ch = _chapters[idx];
        final pages = _pagesCache[ch.id];
        if (pages != null && pages.isNotEmpty) {
          _onChapterFinished(idx);
        }
      }
    }

    if (DateTime.now().isBefore(_trackingPausedUntil)) return false;

    final now = DateTime.now();
    // Throttle render-tree measurements to at most once per 80ms during scroll, or on scroll end
    if (notif is ScrollEndNotification || now.difference(_lastTrackTime).inMilliseconds >= 80) {
      _lastTrackTime = now;
      _trackWebtoonPosition();
    }
    return false;
  }

  /// Finds the page that is actually under the reading line by measuring the
  /// mounted page widgets (page heights vary a lot, so estimating from the
  /// scroll fraction picks the wrong chapter/page).
  void _trackWebtoonPosition() {
    final listBox = _listKey.currentContext?.findRenderObject();
    if (listBox is! RenderBox || !listBox.attached || !listBox.hasSize) return;
    final anchor = listBox.size.height * 0.4;

    _PageSlot? activeSlot;
    for (final slot in _pageSlots.values) {
      final box = slot.key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: listBox).dy;
      if (top <= anchor && anchor < top + box.size.height) {
        activeSlot = slot;
        break;
      } else if (top + box.size.height <= anchor) {
        // This page is fully above the anchor line (user read past it)
        final pages = _pagesCache[_chapters[slot.chapterIndex].id];
        if (pages != null && pages.isNotEmpty && slot.pageIndex >= pages.length - 1) {
          _onChapterFinished(slot.chapterIndex);
        }
      }
    }

    if (activeSlot != null) {
      _updateWebtoonPosition(activeSlot.chapterIndex, activeSlot.pageIndex);
    }
  }

  void _updateWebtoonPosition(int chapterIndex, int pageIndex) {
    final pages = _pagesCache[_chapters[chapterIndex].id];
    if (pages == null || pages.isEmpty) return;
    final newPage = (pageIndex + 1).clamp(1, pages.length);

    if (chapterIndex != _currentChapterIndex) {
      final oldIdx = _currentChapterIndex;
      _onChapterFinished(oldIdx);
      setState(() {
        _currentChapterIndex = chapterIndex;
        _totalPages = pages.length;
        _page = newPage;
      });
      _pageNotifier.value = newPage;
      if (newPage >= pages.length) {
        _onChapterFinished(chapterIndex);
      }
      _syncProgress(newPage);
      _precacheSlidingWindow(pages, pageIndex);
      _loadChapter(chapterIndex + 1);
    } else if (newPage != _page) {
      _page = newPage;
      _pageNotifier.value = newPage;
      if (newPage >= pages.length) {
        _onChapterFinished(chapterIndex);
      }
      _syncProgress(newPage);
      _precacheSlidingWindow(pages, pageIndex);
    }
  }

  void _scrollToWebtoonPage(int target) {
    if (!_scrollController.hasClients) return;
    _pauseTracking(450);

    final ctx = _pageSlots['p:$_currentChapterIndex:${target - 1}']?.key.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.05,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
      return;
    }

    // Target page isn't built yet: step by the average height of built pages.
    var total = 0.0;
    var count = 0;
    for (final slot in _pageSlots.values) {
      final box = slot.key.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        total += box.size.height;
        count++;
      }
    }
    final avg = count > 0 ? total / count : MediaQuery.sizeOf(context).height;
    final position = _scrollController.position;
    final dest = (position.pixels + (target - _page) * avg)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    _scrollController.animateTo(dest, duration: const Duration(milliseconds: 250), curve: Curves.easeInOut);
  }

  void _go(int p) {
    final target = p.clamp(1, _totalPages);
    _page = target;
    _pageNotifier.value = target;
    final pages = _pagesCache[_currentChapter.id];
    final actualTotal = pages?.length ?? _totalPages;
    if (pages != null && pages.isNotEmpty && target >= actualTotal) {
      _onChapterFinished(_currentChapterIndex);
    }
    _syncProgress(target);

    if (_mode == ReaderMode.webtoon) {
      _scrollToWebtoonPage(target);
    } else if (_pageController.hasClients) {
      _pageController.jumpToPage(target - 1);
    }
  }

  void _setMode(ReaderMode mode) {
    if (mode == _selectedMode) return;
    final oldEffective = _effectiveMode;
    final oldController = _pageController;

    setState(() {
      _selectedMode = mode;
      final newEffective = _effectiveMode;
      if (newEffective != oldEffective) {
        _pageController = _newPageController(_page - 1);
        _webtoonLoadedIndices
          ..clear()
          ..add(_currentChapterIndex);
        _pageSlots.clear();
      }
    });

    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString('reader_direction_${widget.mangaId}', mode.name),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_effectiveMode != oldEffective) {
        oldController.dispose();
      }
      if (mounted && _effectiveMode == ReaderMode.webtoon && _page > 1) {
        _scrollToWebtoonPage(_page);
      }
    });

    final msg = mode == ReaderMode.automatic
        ? 'Reading Direction: Auto (${_effectiveMode.shortLabel})'
        : 'Reading Direction: ${mode.label}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _showModeSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Text(
                  'READING DIRECTION',
                  style: AppText.sectionHeader,
                ),
              ),
              ListTile(
                leading: Icon(
                  Icons.auto_awesome_rounded,
                  color: _selectedMode == ReaderMode.automatic ? AppColors.primary : AppColors.muted,
                ),
                title: Text('Automatic', style: AppText.bodyMedium),
                subtitle: Text(
                  'Auto-detect: Manga → RTL, Manhwa → Webtoon, Other → LTR (${_effectiveMode.label})',
                  style: AppText.caption,
                ),
                trailing: _selectedMode == ReaderMode.automatic
                    ? const Icon(Icons.check_rounded, color: AppColors.primary)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  _setMode(ReaderMode.automatic);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.arrow_back_rounded,
                  color: _selectedMode == ReaderMode.rightToLeft ? AppColors.primary : AppColors.muted,
                ),
                title: Text('Right to Left (Standard Manga 🇯🇵)', style: AppText.bodyMedium),
                subtitle: Text('Swipe left for next page, auto-advances to next chapter', style: AppText.caption),
                trailing: _selectedMode == ReaderMode.rightToLeft
                    ? const Icon(Icons.check_rounded, color: AppColors.primary)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  _setMode(ReaderMode.rightToLeft);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.swap_vert_rounded,
                  color: _selectedMode == ReaderMode.webtoon ? AppColors.primary : AppColors.muted,
                ),
                title: Text('Webtoon (Vertical continuous scroll 🇰🇷)', style: AppText.bodyMedium),
                subtitle: Text('Continuous strip across chapters with zero loading', style: AppText.caption),
                trailing: _selectedMode == ReaderMode.webtoon
                    ? const Icon(Icons.check_rounded, color: AppColors.primary)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  _setMode(ReaderMode.webtoon);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.arrow_forward_rounded,
                  color: _selectedMode == ReaderMode.leftToRight ? AppColors.primary : AppColors.muted,
                ),
                title: Text('Left to Right (Western comics / Manhua 🇨🇳)', style: AppText.bodyMedium),
                subtitle: Text('Swipe right for next page, auto-advances to next chapter', style: AppText.caption),
                trailing: _selectedMode == ReaderMode.leftToRight
                    ? const Icon(Icons.check_rounded, color: AppColors.primary)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  _setMode(ReaderMode.leftToRight);
                },
              ),
              const Divider(color: AppColors.outline, height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Text(
                  'NAVIGATION & TOUCH CONTROLS',
                  style: AppText.sectionHeader,
                ),
              ),
              SwitchListTile(
                value: _enableTapZones,
                activeThumbColor: AppColors.primary,
                title: Text('Tap Zones Navigation', style: AppText.bodyMedium),
                subtitle: Text('Tap sides to turn page, center for reader menu', style: AppText.caption),
                onChanged: (val) {
                  _setEnableTapZones(val);
                  Navigator.pop(context);
                },
              ),
              SwitchListTile(
                value: _invertTapZones,
                activeThumbColor: AppColors.primary,
                title: Text('Invert Tap Zones', style: AppText.bodyMedium),
                subtitle: Text('Flips left and right tap zone actions', style: AppText.caption),
                onChanged: _enableTapZones
                    ? (val) {
                        _setInvertTapZones(val);
                        Navigator.pop(context);
                      }
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleTap(TapUpDetails details, BoxConstraints constraints) {
    if (_mode == ReaderMode.webtoon || !_enableTapZones) {
      setState(() => _chrome = !_chrome);
      return;
    }
    final x = details.localPosition.dx;
    final w = constraints.maxWidth;
    final leftBound = w * 0.30;
    final rightBound = w * 0.70;

    final isRtl = _mode == ReaderMode.rightToLeft;
    bool nextOnRight = !isRtl;
    if (_invertTapZones) nextOnRight = !nextOnRight;

    if (x < leftBound) {
      if (nextOnRight) {
        _prevPage();
      } else {
        _nextPage();
      }
    } else if (x > rightBound) {
      if (nextOnRight) {
        _nextPage();
      } else {
        _prevPage();
      }
    } else {
      setState(() => _chrome = !_chrome);
    }
  }

  void _prevPage() {
    if (_pageController.hasClients && _pageController.page != null) {
      final cur = _pageController.page!.round();
      if (cur > 0) {
        _pageController.previousPage(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else if (_hasPrevChapter) {
        _switchToChapter(_currentChapterIndex - 1);
      }
    }
  }

  void _nextPage() {
    if (_pageController.hasClients && _pageController.page != null) {
      final cur = _pageController.page!.round();
      final pages = _pagesCache[_currentChapter.id];
      final total = (pages?.length ?? 0) + (_hasNextChapter ? 1 : 0);
      if (cur + 1 < total) {
        _pageController.nextPage(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else if (_hasNextChapter) {
        _switchToChapter(_currentChapterIndex + 1);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        _flushProgress();
      },
      child: Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Content reader layer
          LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) => _handleTap(details, constraints),
                child: _buildReaderBody(),
              );
            },
          ),
          // Brightness dimming overlay
          if (_brightness < 0.99)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: (1.0 - _brightness).clamp(0.0, 0.8)),
                ),
              ),
            ),
          // Warm eye-care tint overlay
          if (_tint > 0.01)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: const Color(0xFFFFA726).withValues(alpha: (_tint * 0.35).clamp(0.0, 0.45)),
                ),
              ),
            ),
          // Top Bar
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            left: 0,
            right: 0,
            top: _chrome ? 0 : -(76 + MediaQuery.paddingOf(context).top),
            child: _topBar(context),
          ),
          // Bottom Bar
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            left: 0,
            right: 0,
            bottom: _chrome ? 0 : -(160 + MediaQuery.paddingOf(context).bottom),
            child: _bottom(context),
          ),
        ],
      ),
    ),
  );
  }

  Widget _buildReaderBody() =>
      _mode == ReaderMode.webtoon ? _buildWebtoonReader() : _buildPagedReader();

  Future<void> _openChapterInWebViewAndRetry(int chapterIndex) async {
    final chapter = _chapters[chapterIndex];
    String? webUrl;
    if (chapter.id.startsWith('ext:')) {
      final parts = chapter.id.split(':');
      if (parts.length >= 3) {
        final pkg = parts[1];
        final rawUrl = Uri.decodeComponent(parts.sublist(2).join(':'));
        if (rawUrl.startsWith('http')) {
          webUrl = rawUrl;
        } else {
          final baseUrl = await ExtensionBridge.instance.getSourceBaseUrl(pkg: pkg);
          final ext = ExtensionService.instance.getExtensionByPkg(pkg.split('@').first);
          final base = (baseUrl != null && baseUrl.isNotEmpty) ? baseUrl : (ext?.homeUrl ?? '');
          if (base.isNotEmpty) {
            webUrl = base.endsWith('/') && rawUrl.startsWith('/')
                ? '$base${rawUrl.substring(1)}'
                : '$base$rawUrl';
          }
        }
      }
    }
    if (webUrl != null && webUrl.isNotEmpty) {
      await ExtensionBridge.instance.openInWebView(
        url: webUrl,
        title: widget.mangaTitle.isNotEmpty ? widget.mangaTitle : chapter.displayTitle,
      );
      if (mounted) {
        _reloadChapterPages(chapterIndex);
      }
    }
  }

  /// Inline loading / error state for a chapter whose pages aren't available.
  Widget _buildChapterStatus(int chapterIndex, {bool fill = false}) {
    final chapter = _chapters[chapterIndex];
    final error = _chapterErrors[chapter.id];
    final isExtChapter = chapter.id.startsWith('ext:');

    final Widget content = AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: error != null
          ? Container(
              key: ValueKey('err:${chapter.id}'),
              padding: const EdgeInsets.all(24),
              constraints: const BoxConstraints(maxWidth: 360),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.outline),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline_rounded, size: 42, color: AppColors.primary),
                  const SizedBox(height: 12),
                  Text(
                    'Could not load ${chapter.displayTitle}',
                    textAlign: TextAlign.center,
                    style: AppText.cardTitle,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    error,
                    textAlign: TextAlign.center,
                    style: AppText.caption.copyWith(height: 1.4),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: () => _reloadChapterPages(chapterIndex),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text('Retry Chapter', style: AppText.bodySemiBold.copyWith(color: AppColors.onPrimary)),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.onPrimary,
                      minimumSize: const Size(0, 44),
                    ),
                  ),
                  if (isExtChapter) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => _openChapterInWebViewAndRetry(chapterIndex),
                      icon: const Icon(Icons.shield_outlined, size: 16),
                      label: Text('Solve in WebView & Retry', style: AppText.bodyMedium),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.text,
                        side: const BorderSide(color: AppColors.outline),
                        minimumSize: const Size(0, 44),
                      ),
                    ),
                  ],
                ],
              ),
            )
          : Column(
              key: ValueKey('load:${chapter.id}'),
              mainAxisSize: MainAxisSize.min,
              children: [
                ShimmerLoading(
                  child: Container(
                    width: 220,
                    height: 180,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2.2),
                ),
                const SizedBox(height: 10),
                Text(
                  'Loading ${chapter.displayTitle}...',
                  style: AppText.caption,
                ),
              ],
            ),
    );

    final body = Center(child: Padding(padding: const EdgeInsets.all(24), child: content));
    return fill ? body : SizedBox(height: 320, child: body);
  }

  // ---- Continuous Webtoon Reader ----

  _PageSlot _slotFor(_FeedItem item) =>
      _pageSlots.putIfAbsent(item.id, () => _PageSlot(item.chapterIndex!, item.pageIndex!));

  Widget _buildWebtoonReader() {
    final feedItems = <_FeedItem>[];

    for (var k = 0; k < _webtoonLoadedIndices.length; k++) {
      final chIdx = _webtoonLoadedIndices[k];
      final chapter = _chapters[chIdx];
      final pages = _pagesCache[chapter.id];

      if (k > 0) {
        feedItems.add(_FeedItem.divider(
          prevChapter: _chapters[_webtoonLoadedIndices[k - 1]],
          nextChapter: chapter,
          chapterIndex: chIdx,
        ));
      }

      if (pages == null) {
        // Loading or failed: shown inline (with Retry) so it can't be skipped.
        feedItems.add(_FeedItem.status(chIdx));
      } else {
        for (var p = 0; p < pages.length; p++) {
          feedItems.add(_FeedItem.page(chapterIndex: chIdx, pageIndex: p, url: pages[p]));
        }
      }
    }

    final lastIdx = _webtoonLoadedIndices.last;
    if (_pagesCache.containsKey(_chapters[lastIdx].id)) {
      if (lastIdx + 1 < _chapters.length) {
        feedItems.add(_FeedItem.nextChapterTrigger(_chapters[lastIdx + 1], lastIdx + 1));
      } else {
        feedItems.add(_FeedItem.endOfManga());
      }
    }

    final keys = <Key>[
      for (final item in feedItems)
        item.type == _ItemType.page ? _slotFor(item).key : ValueKey(item.id),
    ];
    final indexByKey = <Key, int>{for (var i = 0; i < keys.length; i++) keys[i]: i};

    return NotificationListener<ScrollNotification>(
      onNotification: _onWebtoonScroll,
      child: ListView.builder(
        key: _listKey,
        controller: _scrollController,
        // ignore: deprecated_member_use
        cacheExtent: MediaQuery.sizeOf(context).height * 1.5,
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 50,
          bottom: MediaQuery.paddingOf(context).bottom + 90,
        ),
        itemCount: feedItems.length,
        findChildIndexCallback: (key) => indexByKey[key],
        itemBuilder: (context, i) => KeyedSubtree(
          key: keys[i],
          child: _buildFeedItem(feedItems[i]),
        ),
      ),
    );
  }

  Widget _buildFeedItem(_FeedItem item) {
    switch (item.type) {
      case _ItemType.page:
        final chIdx = item.chapterIndex ?? _currentChapterIndex;
        final pageIdx = item.pageIndex ?? 0;
        final chapterId = _chapters[chIdx].id;
        final url = item.url!;
        return _ReaderPageImage(
          url: url,
          fallbackUrls: _fallbackUrlsFor(chapterId, pageIdx, url),
          pageNumber: pageIdx + 1,
          fit: BoxFit.fitWidth,
          expandWidth: true,
          onReloadChapter: () => _reloadChapterPages(chIdx),
        );

      case _ItemType.divider:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.outline),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.check_circle_rounded, color: AppColors.primary, size: 16),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '${item.prevChapter?.displayTitle ?? "Previous Chapter"} finished',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '↓ Continuing to ${item.nextChapter?.displayTitle ?? "Next Chapter"}',
                textAlign: TextAlign.center,
                style: AppText.cardTitle,
              ),
            ],
          ),
        );

      case _ItemType.status:
        return _buildChapterStatus(item.chapterIndex!);

      case _ItemType.nextTrigger:
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 36),
          child: Center(
            child: FilledButton.tonalIcon(
              onPressed: _extendWebtoonFeed,
              icon: const Icon(Icons.arrow_downward_rounded, size: 18),
              label: Text(
                'Next: ${item.nextChapter?.displayTitle ?? "Next Chapter"}',
                style: AppText.bodySemiBold,
              ),
            ),
          ),
        );

      case _ItemType.endOfManga:
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.celebration_rounded, color: AppColors.primary, size: 36),
                const SizedBox(height: 12),
                Text(
                  "You've reached the latest chapter!",
                  style: AppText.cardTitle,
                ),
                const SizedBox(height: 4),
                Text(
                  'Check back later for new releases',
                  style: AppText.caption,
                ),
              ],
            ),
          ),
        );
    }
  }

  // ---- Continuous Paged Reader (RTL Japanese Manga & LTR Western) ----

  /// Called when the reader lands on the "next chapter" card. Waits a beat and
  /// only advances if the user is still on that card (they may swipe back).
  void _scheduleAutoAdvance(int fromIdx, int cardPage) {
    if (_advancing) return;
    _advancing = true;
    Future.delayed(const Duration(milliseconds: 1500), () {
      _advancing = false;
      if (!mounted || _mode == ReaderMode.webtoon || _currentChapterIndex != fromIdx) return;
      if (!_pageController.hasClients || _pageController.page?.round() != cardPage) return;
      _switchToChapter(fromIdx + 1);
    });
  }

  Widget _buildPagedReader() {
    final curChapter = _currentChapter;
    final pages = _pagesCache[curChapter.id];

    if (pages == null) {
      return _buildChapterStatus(_currentChapterIndex, fill: true);
    }

    final isRtl = _mode == ReaderMode.rightToLeft;

    // Total items in pageview: pages + 1 transition card to next chapter if available
    final hasNext = _hasNextChapter;
    final pageCount = pages.length + (hasNext ? 1 : 0);
    final chapterIdx = _currentChapterIndex;

    return PageView.builder(
      key: ValueKey('${curChapter.id}:${_mode.name}'),
      controller: _pageController,
      reverse: isRtl,
      itemCount: pageCount,
      physics: const PageScrollPhysics(),
      onPageChanged: (idx) {
        if (idx < pages.length) {
          final newP = idx + 1;
          if (_page != newP) {
            _page = newP;
            _pageNotifier.value = newP;
            if (newP >= pages.length) {
              _onChapterFinished(chapterIdx);
            }
            _syncProgress(newP);
            _precacheSlidingWindow(pages, idx);
            // Prefetch next chapter when nearing the end
            if (idx >= pages.length - 3 && chapterIdx + 1 < _chapters.length) {
              _loadChapter(chapterIdx + 1);
            }
          }
        } else if (hasNext) {
          _onChapterFinished(chapterIdx);
          _scheduleAutoAdvance(chapterIdx, idx);
        }
      },
      itemBuilder: (_, i) {
        if (i < pages.length) {
          final pageUrl = pages[i];
          return Center(
            child: ZoomablePageWrapper(
              child: _ReaderPageImage(
                url: pageUrl,
                fallbackUrls: _fallbackUrlsFor(curChapter.id, i, pageUrl),
                pageNumber: i + 1,
                fit: _fitMode,
                expandWidth: false,
                onReloadChapter: () => _reloadChapterPages(chapterIdx),
              ),
            ),
          );
        }

        // Seamless Next Chapter Transition Card
        final nextCh = _chapters[chapterIdx + 1];
        return Center(
          child: Container(
            padding: const EdgeInsets.all(32),
            margin: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.outline),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle_rounded, color: AppColors.primary, size: 48),
                const SizedBox(height: 16),
                Text(
                  '${curChapter.displayTitle} Finished',
                  textAlign: TextAlign.center,
                  style: AppText.sheetTitle,
                ),
                const SizedBox(height: 8),
                Text(
                  'Up next: ${nextCh.displayTitle}',
                  textAlign: TextAlign.center,
                  style: AppText.body.copyWith(color: AppColors.muted),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => _switchToChapter(chapterIdx + 1),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text('Read Next Chapter', style: AppText.bodySemiBold.copyWith(color: AppColors.onPrimary)),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimary,
                    minimumSize: const Size(0, 44),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _topBar(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final curChapter = _currentChapter;
    final isBookmarked = ApiService.instance.isChapterBookmarked(curChapter.id);

    return Container(
      constraints: BoxConstraints(minHeight: 74 + top),
      padding: EdgeInsets.fromLTRB(6, top + 4, 6, 4),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: .94),
        border: const Border(bottom: BorderSide(color: AppColors.outline)),
      ),
      child: Row(
        children: [
          BarIcon(Icons.arrow_back_rounded, label: 'Back', onTap: () => Navigator.of(context).maybePop()),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.mangaTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodyMedium,
                ),
                const SizedBox(height: 3),
                ValueListenableBuilder<int>(
                  valueListenable: _pageNotifier,
                  builder: (_, page, _) => Text(
                    '$_chapterLabel · Page $page/$_totalPages',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption,
                  ),
                ),
              ],
            ),
          ),
          // Bookmark Chapter Icon Button
          IconButton(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            icon: Icon(
              isBookmarked ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              color: isBookmarked ? AppColors.primary : AppColors.text,
              size: 22,
            ),
            tooltip: isBookmarked ? 'Bookmarked' : 'Bookmark Chapter',
            onPressed: () async {
              final state = await ApiService.instance.toggleChapterBookmark(curChapter.id);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      state
                          ? 'Bookmarked ${curChapter.displayTitle}'
                          : 'Removed bookmark for ${curChapter.displayTitle}',
                    ),
                    duration: const Duration(seconds: 1),
                  ),
                );
              }
            },
          ),
          BarIcon(
            Icons.tune_rounded,
            label: 'Display & Filter',
            onTap: _showDisplaySheet,
          ),
          BarIcon(
            Icons.refresh_rounded,
            label: 'Reload Chapter',
            onTap: () => _reloadChapterPages(_currentChapterIndex),
          ),
          BarIcon(
            _selectedMode == ReaderMode.automatic ? Icons.auto_awesome_rounded : _mode.icon,
            label: _selectedMode == ReaderMode.automatic
                ? 'Auto (${_mode.shortLabel})'
                : _selectedMode.label,
            onTap: _showModeSheet,
          ),
        ],
      ),
    );
  }

  Widget _bottom(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Page Scrubber Slider
        Container(
          constraints: const BoxConstraints(minHeight: 54),
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(27),
            border: Border.all(color: AppColors.outline),
          ),
          child: Row(
            children: [
              _ScrubButton('‹', () => _go(_page - 1)),
              Expanded(
                child: ValueListenableBuilder<int>(
                  valueListenable: _pageNotifier,
                  builder: (context, page, _) => SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      activeTrackColor: AppColors.primary,
                      inactiveTrackColor: AppColors.outline,
                      thumbColor: AppColors.primary,
                      overlayColor: AppColors.primary.withValues(alpha: .12),
                    ),
                    child: Slider(
                      min: 1,
                      max: math.max(1, _totalPages).toDouble(),
                      value: page.clamp(1, math.max(1, _totalPages)).toDouble(),
                      onChanged: (v) => _go(v.round()),
                    ),
                  ),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 52),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ValueListenableBuilder<int>(
                    valueListenable: _pageNotifier,
                    builder: (_, page, _) => Text(
                      '$page / $_totalPages',
                      textAlign: TextAlign.center,
                      style: AppText.caption,
                    ),
                  ),
                ),
              ),
              _ScrubButton('›', () => _go(_page + 1)),
            ],
          ),
        ),
        // Clean Bottom Controls with Next/Prev Chapter & Fit
        Container(
          constraints: BoxConstraints(minHeight: 64 + bottom),
          padding: EdgeInsets.only(top: 6, bottom: bottom + 4),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: .95),
            border: const Border(top: BorderSide(color: AppColors.outline)),
          ),
          child: Row(
            children: [
              // Previous Chapter
              Expanded(
                child: InkWell(
                  onTap: _hasPrevChapter ? () => _switchToChapter(_currentChapterIndex - 1) : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.skip_previous_rounded,
                          size: 20,
                          color: _hasPrevChapter ? AppColors.text : AppColors.muted.withValues(alpha: .3),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Prev Ch.',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(
                            color: _hasPrevChapter ? AppColors.muted : AppColors.muted.withValues(alpha: .3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Direction toggle (Webtoon / RTL Manga / LTR)
              Expanded(
                child: InkWell(
                  onTap: _showModeSheet,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _selectedMode == ReaderMode.automatic ? Icons.auto_awesome_rounded : _mode.icon,
                          size: 20,
                          color: AppColors.primary,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _selectedMode == ReaderMode.automatic
                              ? 'Auto (${_mode.shortLabel})'
                              : _selectedMode.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(color: AppColors.primary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Fit mode toggle (Fit Width vs Fit Screen)
              Expanded(
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _fitMode = _fitMode == BoxFit.contain ? BoxFit.fitWidth : BoxFit.contain;
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(_fitMode == BoxFit.contain ? 'Mode: Fit Page' : 'Mode: Fit Width'),
                        duration: const Duration(milliseconds: 800),
                      ),
                    );
                  },
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _fitMode == BoxFit.contain ? Icons.fit_screen_rounded : Icons.photo_size_select_actual_outlined,
                          size: 20,
                          color: AppColors.text,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _fitMode == BoxFit.contain ? 'Fit Page' : 'Fit Width',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Next Chapter
              Expanded(
                child: InkWell(
                  onTap: _hasNextChapter ? () => _switchToChapter(_currentChapterIndex + 1) : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.skip_next_rounded,
                          size: 20,
                          color: _hasNextChapter ? AppColors.primary : AppColors.muted.withValues(alpha: .3),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Next Ch.',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(
                            color: _hasNextChapter ? AppColors.primary : AppColors.muted.withValues(alpha: .3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ScrubButton extends StatelessWidget {
  const _ScrubButton(this.glyph, this.onTap);
  final String glyph;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 44,
        height: 44,
        child: InkResponse(
          onTap: onTap,
          radius: 22,
          child: Center(
            child: Text(glyph, style: const TextStyle(fontSize: 28, color: AppColors.primary, height: 1)),
          ),
        ),
      );
}

// Supporting models for continuous webtoon feed
enum _ItemType { page, divider, status, nextTrigger, endOfManga }

/// Tracks a mounted page widget so the reader can measure which page is under
/// the reading line.
class _PageSlot {
  _PageSlot(this.chapterIndex, this.pageIndex);
  final int chapterIndex;
  final int pageIndex;
  final GlobalKey key = GlobalKey();
}

class _FeedItem {
  final _ItemType type;
  final int? chapterIndex;
  final int? pageIndex;
  final String? url;
  final ChapterItem? prevChapter;
  final ChapterItem? nextChapter;

  const _FeedItem._({
    required this.type,
    this.chapterIndex,
    this.pageIndex,
    this.url,
    this.prevChapter,
    this.nextChapter,
  });

  /// Stable identity, used for widget keys.
  String get id => switch (type) {
        _ItemType.page => 'p:$chapterIndex:$pageIndex',
        _ItemType.divider => 'd:$chapterIndex',
        _ItemType.status => 's:$chapterIndex',
        _ItemType.nextTrigger => 'n:$chapterIndex',
        _ItemType.endOfManga => 'end',
      };

  factory _FeedItem.page({
    required int chapterIndex,
    required int pageIndex,
    required String url,
  }) =>
      _FeedItem._(
        type: _ItemType.page,
        chapterIndex: chapterIndex,
        pageIndex: pageIndex,
        url: url,
      );

  factory _FeedItem.divider({
    required ChapterItem prevChapter,
    required ChapterItem nextChapter,
    required int chapterIndex,
  }) =>
      _FeedItem._(
        type: _ItemType.divider,
        prevChapter: prevChapter,
        nextChapter: nextChapter,
        chapterIndex: chapterIndex,
      );

  factory _FeedItem.status(int chapterIndex) =>
      _FeedItem._(type: _ItemType.status, chapterIndex: chapterIndex);

  factory _FeedItem.nextChapterTrigger(ChapterItem chapter, int chapterIndex) =>
      _FeedItem._(type: _ItemType.nextTrigger, nextChapter: chapter, chapterIndex: chapterIndex);

  factory _FeedItem.endOfManga() => const _FeedItem._(type: _ItemType.endOfManga);
}

class ZoomablePageWrapper extends StatefulWidget {
  const ZoomablePageWrapper({super.key, required this.child});
  final Widget child;

  @override
  State<ZoomablePageWrapper> createState() => _ZoomablePageWrapperState();
}

class _ZoomablePageWrapperState extends State<ZoomablePageWrapper> {
  final TransformationController _controller = TransformationController();
  TapDownDetails? _doubleTapDetails;
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTransformChanged);
  }

  void _onTransformChanged() {
    final zoomed = _controller.value.getMaxScaleOnAxis() > 1.05;
    if (zoomed != _isZoomed) {
      setState(() => _isZoomed = zoomed);
    }
  }

  void _handleDoubleTap() {
    final currentScale = _controller.value.getMaxScaleOnAxis();
    if (currentScale > 1.08) {
      _controller.value = Matrix4.identity();
    } else {
      final position = _doubleTapDetails?.localPosition ?? Offset.zero;
      final zoomed = Matrix4.identity()
        ..translateByDouble(-position.dx * 1.5, -position.dy * 1.5, 0.0, 1.0)
        ..scaleByDouble(2.5, 2.5, 1.0, 1.0);
      _controller.value = zoomed;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTransformChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onDoubleTapDown: (details) => _doubleTapDetails = details,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: 1.0,
        maxScale: 4.0,
        panEnabled: _isZoomed,
        clipBehavior: Clip.none,
        child: widget.child,
      ),
    );
  }
}

class _ReaderPageImage extends StatefulWidget {
  const _ReaderPageImage({
    required this.url,
    required this.fallbackUrls,
    required this.pageNumber,
    required this.fit,
    required this.expandWidth,
    this.onReloadChapter,
  });

  final String url;
  final List<String> fallbackUrls;
  final int pageNumber;
  final BoxFit fit;
  final bool expandWidth;
  final VoidCallback? onReloadChapter;

  @override
  State<_ReaderPageImage> createState() => _ReaderPageImageState();
}

class _ReaderPageImageState extends State<_ReaderPageImage> {
  int _localReloadGen = 0;

  @override
  Widget build(BuildContext context) {
    final url = widget.url.trim();
    if (url.startsWith('file://')) {
      final file = File(url.replaceFirst('file://', ''));
      return Image.file(
        file,
        key: ValueKey('file:$url#$_localReloadGen'),
        fit: widget.fit,
        width: widget.expandWidth ? double.infinity : null,
        errorBuilder: (_, _, _) => _PageErrorCard(
          pageNumber: widget.pageNumber,
          fill: !widget.expandWidth,
          onRetryPage: () {
            FileImage(file).evict();
            setState(() => _localReloadGen++);
          },
          onReloadChapter: widget.onReloadChapter,
        ),
      );
    }

    final normalizedUrl = url.startsWith('//') ? 'https:$url' : url;
    if (!normalizedUrl.startsWith('http')) {
      return _PageErrorCard(
        pageNumber: widget.pageNumber,
        fill: !widget.expandWidth,
        onRetryPage: () => setState(() => _localReloadGen++),
        onReloadChapter: widget.onReloadChapter,
      );
    }

    void forceRetryThisPage() {
      evictCachedImageUrl(normalizedUrl);
      for (final fb in widget.fallbackUrls) {
        if (fb.startsWith('http')) {
          evictCachedImageUrl(fb);
        }
      }
      if (mounted) {
        setState(() => _localReloadGen++);
      }
    }

    return RetryingNetworkImage(
      key: ValueKey('net:$normalizedUrl#$_localReloadGen'),
      url: normalizedUrl,
      fallbackUrls: widget.fallbackUrls,
      fit: widget.fit,
      width: widget.expandWidth ? double.infinity : null,
      fadeInDuration: const Duration(milliseconds: 60),
      progressBuilder: (_, progress) => _PageLoadingSkeleton(
        pageNumber: widget.pageNumber,
        progress: progress,
        fill: !widget.expandWidth,
        onForceRetry: forceRetryThisPage,
        onReloadChapter: widget.onReloadChapter,
      ),
      errorBuilder: (_, retry) => _PageErrorCard(
        pageNumber: widget.pageNumber,
        fill: !widget.expandWidth,
        onRetryPage: () {
          evictCachedImageUrl(normalizedUrl);
          retry();
        },
        onReloadChapter: widget.onReloadChapter,
      ),
    );
  }
}

class _PageLoadingSkeleton extends StatefulWidget {
  const _PageLoadingSkeleton({
    required this.pageNumber,
    required this.progress,
    required this.fill,
    this.onForceRetry,
    this.onReloadChapter,
  });

  final int pageNumber;
  final double? progress;
  final bool fill;
  final VoidCallback? onForceRetry;
  final VoidCallback? onReloadChapter;

  @override
  State<_PageLoadingSkeleton> createState() => _PageLoadingSkeletonState();
}

class _PageLoadingSkeletonState extends State<_PageLoadingSkeleton> {
  bool _showSlowRetry = false;
  Timer? _slowTimer;

  @override
  void initState() {
    super.initState();
    if (widget.onForceRetry != null) {
      _slowTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) {
          setState(() => _showSlowRetry = true);
        }
      });
    }
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress;
    final pageNumber = widget.pageNumber;
    final pct = (progress != null && progress > 0) ? (progress * 100).round().clamp(1, 99) : null;
    final box = Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: ShimmerLoading(
            child: Container(
              color: AppColors.surface.withValues(alpha: 0.7),
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.outline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  value: (progress != null && progress > 0 && progress < 1) ? progress : null,
                  color: AppColors.primary,
                  backgroundColor: AppColors.surfaceHigh,
                  strokeWidth: 2.4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                pct != null ? 'Page $pageNumber · $pct%' : 'Page $pageNumber',
                style: AppText.caption,
              ),
              if (_showSlowRetry && widget.onForceRetry != null) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: widget.onForceRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 14),
                  label: Text('Retry Page $pageNumber'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: BorderSide(color: AppColors.primary.withValues(alpha: 0.55)),
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    textStyle: AppText.chip,
                  ),
                ),
                if (widget.onReloadChapter != null)
                  TextButton(
                    onPressed: widget.onReloadChapter,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.muted,
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      textStyle: AppText.caption,
                    ),
                    child: const Text('Reload Chapter URLs'),
                  ),
              ],
            ],
          ),
        ),
      ],
    );

    if (widget.fill) {
      return SizedBox(
        width: double.infinity,
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: box,
      );
    }
    return Container(
      height: 440,
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 1),
      child: box,
    );
  }
}

class _PageErrorCard extends StatelessWidget {
  const _PageErrorCard({
    required this.pageNumber,
    required this.onRetryPage,
    required this.fill,
    this.onReloadChapter,
  });

  final int pageNumber;
  final VoidCallback onRetryPage;
  final VoidCallback? onReloadChapter;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final card = Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        constraints: const BoxConstraints(maxWidth: 340),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.outline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.broken_image_outlined, color: AppColors.primary, size: 22),
            ),
            const SizedBox(height: 12),
            Text(
              'Page $pageNumber failed to load',
              textAlign: TextAlign.center,
              style: AppText.cardTitle,
            ),
            const SizedBox(height: 4),
            Text(
              'The image server timed out or dropped the connection.',
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(height: 1.4),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetryPage,
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: Text(
                'Retry Page $pageNumber',
                style: AppText.bodySemiBold.copyWith(color: AppColors.onPrimary),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.onPrimary,
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              ),
            ),
            if (onReloadChapter != null) ...[
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: onReloadChapter,
                icon: const Icon(Icons.sync_rounded, size: 15),
                label: const Text('Reload Chapter URLs'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.muted,
                  minimumSize: const Size(0, 44),
                  textStyle: AppText.caption,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (fill) return card;
    return SizedBox(
      width: double.infinity,
      height: 280,
      child: card,
    );
  }
}
