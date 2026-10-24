import 'dart:io';
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/tracker_service.dart';
import '../theme.dart';
import '../widgets/common.dart';

enum ReaderMode {
  rightToLeft, // 🇯🇵 Standard Manga: Right to Left
  webtoon,     // 🇰🇷 Manhwa / Webtoon: Continuous vertical scroll
  leftToRight, // 🇨🇳 Manhua / Western: Left to Right
}

extension ReaderModeInfo on ReaderMode {
  String get label => switch (this) {
        ReaderMode.rightToLeft => 'RTL (Manga)',
        ReaderMode.webtoon => 'Webtoon',
        ReaderMode.leftToRight => 'Left-to-Right',
      };

  IconData get icon => switch (this) {
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
  });

  final String? chapterId;
  final String mangaId;
  final String mangaTitle;
  final String? chapterNumber;
  final String? chapterTitle;
  final String? coverUrl;
  final List<ChapterItem> chapters;
  final int initialIndex;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late List<ChapterItem> _chapters;
  late int _currentChapterIndex;

  // Pages cache keyed by chapter ID
  final Map<String, List<String>> _pagesCache = {};
  final Set<String> _loadingChapterIds = {};
  final Map<String, String> _chapterErrors = {};

  // Webtoon continuous feed. Always an ascending, contiguous run of chapter
  // indices so chapters can never appear out of order or be skipped.
  final List<int> _webtoonLoadedIndices = [];
  final Map<String, _PageSlot> _pageSlots = {};
  final GlobalKey _listKey = GlobalKey();
  DateTime _trackingPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  int _totalPages = 1;
  int _page = 1;
  bool _chrome = true;
  bool _advancing = false;

  ReaderMode _mode = ReaderMode.webtoon;
  BoxFit _fitMode = BoxFit.fitWidth;
  bool _enableTapZones = true;
  bool _invertTapZones = false;

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
    _pageController = _newPageController(0);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() {
          _enableTapZones = prefs.getBool('reader_enable_tap_zones') ?? true;
          _invertTapZones = prefs.getBool('reader_invert_tap_zones') ?? false;
        });
      }
    });

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

  @override
  void dispose() {
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  /// Loads a chapter's pages. A chapter that fails to load (or has no pages) is
  /// recorded in [_chapterErrors] so the reader can show a Retry tile instead
  /// of silently skipping over it.
  Future<void> _loadChapter(int idx) async {
    if (idx < 0 || idx >= _chapters.length) return;
    final chapter = _chapters[idx];
    if (_pagesCache.containsKey(chapter.id) || _loadingChapterIds.contains(chapter.id)) return;

    if (chapter.id.isEmpty) {
      setState(() => _chapterErrors[chapter.id] = 'This chapter is not available.');
      return;
    }

    setState(() {
      _chapterErrors.remove(chapter.id);
      _loadingChapterIds.add(chapter.id);
    });

    try {
      final res = await ApiService.instance.getChapterPages(chapter.id);
      if (res.pages.isEmpty) throw Exception('No pages found for this chapter.');
      _pagesCache[chapter.id] = res.pages;
      _loadingChapterIds.remove(chapter.id);
      if (!mounted) return;

      setState(() {
        if (idx == _currentChapterIndex) {
          _totalPages = res.pages.length;
          _page = _page.clamp(1, _totalPages);
        }
      });
      _precacheFirstPages(res.pages);

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

  void _precacheFirstPages(List<String> pages) {
    if (!mounted) return;
    for (var i = 0; i < math.min(3, pages.length); i++) {
      final p = pages[i];
      if (p.startsWith('file://')) {
        precacheImage(FileImage(File(p.replaceFirst('file://', ''))), context, onError: (_, _) {});
      } else {
        precacheImage(CachedNetworkImageProvider(p, headers: imageHeadersForUrl(p)), context, onError: (_, _) {});
      }
    }
  }

  void _syncProgress(int currentPage) {
    if (widget.mangaId.isEmpty) return;
    final chapter = _currentChapter;
    final completed = currentPage >= _totalPages && _totalPages > 0;
    ApiService.instance.saveProgress(
      mangaId: widget.mangaId,
      chapterId: chapter.id,
      mangaTitle: widget.mangaTitle,
      cover: widget.coverUrl,
      chapterNumber: chapter.number,
      chapterTitle: chapter.title,
      page: currentPage,
      totalPages: _totalPages,
      completed: completed,
    );
  }

  void _onChapterFinished(int finishedIdx) {
    if (finishedIdx < 0 || finishedIdx >= _chapters.length) return;
    final finished = _chapters[finishedIdx];
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
    // Only moving forward counts as finishing the chapter.
    if (newIndex == _currentChapterIndex + 1) _onChapterFinished(_currentChapterIndex);

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
    setState(() => _webtoonLoadedIndices.add(next));
    _loadChapter(next);
  }

  bool _onWebtoonScroll(ScrollNotification notif) {
    if (notif.depth != 0) return false;
    if (notif is! ScrollUpdateNotification && notif is! ScrollEndNotification) return false;

    if (notif.metrics.extentAfter < 1600) _extendWebtoonFeed();
    if (DateTime.now().isBefore(_trackingPausedUntil)) return false;
    _trackWebtoonPosition();
    return false;
  }

  /// Finds the page that is actually under the reading line by measuring the
  /// mounted page widgets (page heights vary a lot, so estimating from the
  /// scroll fraction picks the wrong chapter/page).
  void _trackWebtoonPosition() {
    final listBox = _listKey.currentContext?.findRenderObject();
    if (listBox is! RenderBox || !listBox.attached || !listBox.hasSize) return;
    final anchor = listBox.size.height * 0.4;

    for (final slot in _pageSlots.values) {
      final box = slot.key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: listBox).dy;
      if (top <= anchor && anchor < top + box.size.height) {
        _updateWebtoonPosition(slot.chapterIndex, slot.pageIndex);
        return;
      }
    }
  }

  void _updateWebtoonPosition(int chapterIndex, int pageIndex) {
    final pages = _pagesCache[_chapters[chapterIndex].id];
    if (pages == null || pages.isEmpty) return;
    final newPage = (pageIndex + 1).clamp(1, pages.length);

    if (chapterIndex != _currentChapterIndex) {
      final oldIdx = _currentChapterIndex;
      if (chapterIndex == oldIdx + 1) _onChapterFinished(oldIdx);
      setState(() {
        _currentChapterIndex = chapterIndex;
        _totalPages = pages.length;
        _page = newPage;
      });
      _syncProgress(newPage);
      _loadChapter(chapterIndex + 1);
    } else if (newPage != _page) {
      setState(() => _page = newPage);
      _syncProgress(newPage);
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
    setState(() => _page = target);
    _syncProgress(target);

    if (_mode == ReaderMode.webtoon) {
      _scrollToWebtoonPage(target);
    } else if (_pageController.hasClients) {
      _pageController.jumpToPage(target - 1);
    }
  }

  void _setMode(ReaderMode mode) {
    if (mode == _mode) return;
    final oldController = _pageController;
    setState(() {
      _mode = mode;
      _pageController = _newPageController(_page - 1);
      _webtoonLoadedIndices
        ..clear()
        ..add(_currentChapterIndex);
      _pageSlots.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldController.dispose();
      if (mounted && _mode == ReaderMode.webtoon && _page > 1) _scrollToWebtoonPage(_page);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Reading Mode: ${mode.label}'),
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
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Text(
                  'READING DIRECTION',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    color: AppColors.muted,
                  ),
                ),
              ),
              ListTile(
                leading: Icon(
                  Icons.swap_vert_rounded,
                  color: _mode == ReaderMode.webtoon ? AppColors.primary : AppColors.muted,
                ),
                title: const Text('Webtoon (Vertical continuous scroll 🇰🇷)'),
                subtitle: const Text('Continuous strip across chapters with zero loading'),
                trailing: _mode == ReaderMode.webtoon
                    ? const Icon(Icons.check_rounded, color: AppColors.primary)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  _setMode(ReaderMode.webtoon);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.arrow_back_rounded,
                  color: _mode == ReaderMode.rightToLeft ? AppColors.primary : AppColors.muted,
                ),
                title: const Text('Right to Left (Standard Manga 🇯🇵)'),
                subtitle: const Text('Swipe left for next page, auto-advances to next chapter'),
                trailing: _mode == ReaderMode.rightToLeft
                    ? const Icon(Icons.check_rounded, color: AppColors.primary)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  _setMode(ReaderMode.rightToLeft);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.arrow_forward_rounded,
                  color: _mode == ReaderMode.leftToRight ? AppColors.primary : AppColors.muted,
                ),
                title: const Text('Left to Right (Western comics 🇨🇳)'),
                subtitle: const Text('Swipe right for next page, auto-advances to next chapter'),
                trailing: _mode == ReaderMode.leftToRight
                    ? const Icon(Icons.check_rounded, color: AppColors.primary)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  _setMode(ReaderMode.leftToRight);
                },
              ),
              const Divider(color: AppColors.surfaceHigh, height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Text(
                  'NAVIGATION & TOUCH CONTROLS',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    color: AppColors.muted,
                  ),
                ),
              ),
              SwitchListTile(
                value: _enableTapZones,
                activeThumbColor: AppColors.primary,
                title: const Text('Tap Zones Navigation'),
                subtitle: const Text('Tap sides to turn page, center for reader menu'),
                onChanged: (val) {
                  _setEnableTapZones(val);
                  Navigator.pop(context);
                },
              ),
              SwitchListTile(
                value: _invertTapZones,
                activeThumbColor: AppColors.primary,
                title: const Text('Invert Tap Zones'),
                subtitle: const Text('Flips left and right tap zone actions'),
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
    final isAmoled = ThemeController.instance.isAmoled;
    return Scaffold(
      backgroundColor: isAmoled ? Colors.black : AppColors.black,
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
    );
  }

  Widget _buildReaderBody() =>
      _mode == ReaderMode.webtoon ? _buildWebtoonReader() : _buildPagedReader();

  /// Inline loading / error state for a chapter whose pages aren't available.
  Widget _buildChapterStatus(int chapterIndex, {bool fill = false}) {
    final chapter = _chapters[chapterIndex];
    final error = _chapterErrors[chapter.id];

    final Widget content = error != null
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 44, color: AppColors.muted),
              const SizedBox(height: 12),
              Text(
                'Could not load ${chapter.displayTitle}',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                error,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _loadChapter(chapterIndex),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry'),
                style: FilledButton.styleFrom(backgroundColor: AppColors.surfaceHigh),
              ),
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2.5),
              const SizedBox(height: 12),
              Text(
                'Loading ${chapter.displayTitle}...',
                style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
              ),
            ],
          );

    final body = Center(child: Padding(padding: const EdgeInsets.all(24), child: content));
    return fill ? body : SizedBox(height: 280, child: body);
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
        final url = item.url!;
        if (url.startsWith('file://')) {
          final file = File(url.replaceFirst('file://', ''));
          return Image.file(
            file,
            fit: BoxFit.fitWidth,
            width: double.infinity,
            errorBuilder: (_, _, _) => Container(
              height: 200,
              color: AppColors.surface,
              child: Center(
                child: Text('Page ${(item.pageIndex ?? 0) + 1} failed to load',
                    style: const TextStyle(color: AppColors.muted)),
              ),
            ),
          );
        }
        return CachedNetworkImage(
          imageUrl: url,
          httpHeaders: imageHeadersForUrl(url),
          fit: BoxFit.fitWidth,
          width: double.infinity,
          placeholder: (_, _) => Container(
            height: 400,
            color: AppColors.surface,
            child: const Center(
              child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2),
            ),
          ),
          errorWidget: (_, _, _) => Container(
            height: 200,
            color: AppColors.surface,
            child: Center(
              child: Text('Page ${(item.pageIndex ?? 0) + 1} failed to load',
                  style: const TextStyle(color: AppColors.muted)),
            ),
          ),
        );

      case _ItemType.divider:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.surfaceHigh),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.check_circle_rounded, color: AppColors.primary, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    '${item.prevChapter?.displayTitle ?? "Previous Chapter"} finished',
                    style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '↓ Continuing to ${item.nextChapter?.displayTitle ?? "Next Chapter"}',
                style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.text),
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
              label: Text('Next: ${item.nextChapter?.displayTitle ?? "Next Chapter"}'),
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
                  style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  'Check back later for new releases',
                  style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
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
      onPageChanged: (idx) {
        if (idx < pages.length) {
          if (_page != idx + 1) {
            setState(() => _page = idx + 1);
            _syncProgress(idx + 1);
            // Prefetch next chapter when nearing the end
            if (idx >= pages.length - 3 && chapterIdx + 1 < _chapters.length) {
              _loadChapter(chapterIdx + 1);
            }
          }
        } else if (hasNext) {
          _scheduleAutoAdvance(chapterIdx, idx);
        }
      },
      itemBuilder: (_, i) {
        if (i < pages.length) {
          final pageUrl = pages[i];
          Widget imgWidget;
          if (pageUrl.startsWith('file://')) {
            imgWidget = Image.file(
              File(pageUrl.replaceFirst('file://', '')),
              fit: _fitMode,
              errorBuilder: (_, _, _) => Center(
                child: Text('Page ${i + 1} failed to load', style: const TextStyle(color: AppColors.muted)),
              ),
            );
          } else {
            imgWidget = CachedNetworkImage(
              imageUrl: pageUrl,
              httpHeaders: imageHeadersForUrl(pageUrl),
              fit: _fitMode,
              placeholder: (_, _) => const Center(
                child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2),
              ),
              errorWidget: (_, _, _) => Center(
                child: Text('Page ${i + 1} failed to load', style: const TextStyle(color: AppColors.muted)),
              ),
            );
          }
          return Center(
            child: InteractiveViewer(
              child: imgWidget,
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
              border: Border.all(color: AppColors.surfaceHigh),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle_rounded, color: AppColors.primary, size: 48),
                const SizedBox(height: 16),
                Text(
                  '${curChapter.displayTitle} Finished',
                  style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Up next: ${nextCh.displayTitle}',
                  style: GoogleFonts.inter(fontSize: 13, color: AppColors.muted),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => _switchToChapter(chapterIdx + 1),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Read Next Chapter'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimary,
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
      height: 76 + top,
      padding: EdgeInsets.fromLTRB(6, top + 4, 6, 0),
      color: const Color.fromRGBO(17, 19, 24, .92),
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
                  style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 3),
                Text(
                  '$_chapterLabel · Page $_page/$_totalPages',
                  style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                ),
              ],
            ),
          ),
          // Bookmark Chapter Icon Button
          IconButton(
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
            _mode.icon,
            label: _mode.label,
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
          height: 54,
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(27),
          ),
          child: Row(
            children: [
              _ScrubButton('‹', () => _go(_page - 1)),
              Expanded(
                child: SliderTheme(
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
                    value: _page.clamp(1, math.max(1, _totalPages)).toDouble(),
                    onChanged: (v) => _go(v.round()),
                  ),
                ),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  '$_page / $_totalPages',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                ),
              ),
              _ScrubButton('›', () => _go(_page + 1)),
            ],
          ),
        ),
        // Clean Bottom Controls with Next/Prev Chapter & Fit
        Container(
          height: 64 + bottom,
          padding: EdgeInsets.only(top: 6, bottom: bottom),
          color: const Color.fromRGBO(17, 19, 24, .95),
          child: Row(
            children: [
              // Previous Chapter
              Expanded(
                child: InkWell(
                  onTap: _hasPrevChapter ? () => _switchToChapter(_currentChapterIndex - 1) : null,
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
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color: _hasPrevChapter ? AppColors.muted : AppColors.muted.withValues(alpha: .3),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Direction toggle (Webtoon / RTL Manga / LTR)
              Expanded(
                child: InkWell(
                  onTap: _showModeSheet,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(_mode.icon, size: 20, color: AppColors.primary),
                      const SizedBox(height: 4),
                      Text(_mode.label, style: GoogleFonts.inter(fontSize: 10, color: AppColors.primary)),
                    ],
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
                        style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
              ),
              // Next Chapter
              Expanded(
                child: InkWell(
                  onTap: _hasNextChapter ? () => _switchToChapter(_currentChapterIndex + 1) : null,
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
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color: _hasNextChapter ? AppColors.primary : AppColors.muted.withValues(alpha: .3),
                        ),
                      ),
                    ],
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
        width: 40,
        child: InkResponse(
          onTap: onTap,
          radius: 20,
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
