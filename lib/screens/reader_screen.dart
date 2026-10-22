import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
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

  // Webtoon continuous feed chapters
  final List<int> _webtoonLoadedIndices = [];

  int _totalPages = 1;
  int _page = 1;
  bool _chrome = true;
  bool _loading = true;
  String? _error;

  ReaderMode _mode = ReaderMode.webtoon;
  BoxFit _fitMode = BoxFit.fitWidth;

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

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

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
    _loadCurrentChapter();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentChapter() async {
    final chapter = _currentChapter;
    if (chapter.id.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'This chapter is not available.';
      });
      return;
    }

    if (_pagesCache.containsKey(chapter.id)) {
      final cachedPages = _pagesCache[chapter.id]!;
      setState(() {
        _totalPages = cachedPages.isNotEmpty ? cachedPages.length : 1;
        _page = 1;
        _loading = false;
        _error = null;
      });
      _syncProgress(1);
      _preloadNextChapter(_currentChapterIndex + 1);
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      _loadingChapterIds.add(chapter.id);
      final res = await ApiService.instance.getChapterPages(chapter.id);
      _pagesCache[chapter.id] = res.pages;
      _loadingChapterIds.remove(chapter.id);

      if (mounted) {
        setState(() {
          _totalPages = res.pages.isNotEmpty ? res.pages.length : 1;
          _page = 1;
          _loading = false;
        });
        _syncProgress(1);

        // Preload next chapter immediately in background for zero-delay continuous reading
        _preloadNextChapter(_currentChapterIndex + 1);
      }
    } catch (err) {
      _loadingChapterIds.remove(chapter.id);
      if (mounted) {
        setState(() {
          _error = err.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  Future<void> _preloadNextChapter(int nextIndex) async {
    if (nextIndex < 0 || nextIndex >= _chapters.length) return;
    final nextChapter = _chapters[nextIndex];
    if (_pagesCache.containsKey(nextChapter.id) || _loadingChapterIds.contains(nextChapter.id)) {
      return;
    }

    _loadingChapterIds.add(nextChapter.id);
    try {
      final res = await ApiService.instance.getChapterPages(nextChapter.id);
      _pagesCache[nextChapter.id] = res.pages;
      _loadingChapterIds.remove(nextChapter.id);

      // Pre-cache first 3 images into memory cache
      if (mounted && res.pages.isNotEmpty) {
        for (var i = 0; i < math.min(3, res.pages.length); i++) {
          try {
            precacheImage(CachedNetworkImageProvider(res.pages[i]), context);
          } catch (_) {}
        }
        // If webtoon mode and waiting on this chapter, trigger rebuild to display it seamlessly
        if (_mode == ReaderMode.webtoon && _webtoonLoadedIndices.contains(nextIndex)) {
          setState(() {});
        }
      }
    } catch (e) {
      _loadingChapterIds.remove(nextChapter.id);
      _chapterErrors[nextChapter.id] = e.toString();
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
  }

  void _switchToChapter(int newIndex, {bool jumpToStart = true}) {
    if (newIndex < 0 || newIndex >= _chapters.length) return;
    final prevIdx = _currentChapterIndex;
    if (prevIdx != newIndex) {
      _onChapterFinished(prevIdx);
    }

    setState(() {
      _currentChapterIndex = newIndex;
      if (!_webtoonLoadedIndices.contains(newIndex)) {
        _webtoonLoadedIndices.add(newIndex);
      }
    });

    final ch = _chapters[newIndex];
    if (_pagesCache.containsKey(ch.id)) {
      final pages = _pagesCache[ch.id]!;
      setState(() {
        _totalPages = pages.isNotEmpty ? pages.length : 1;
        _page = 1;
        _loading = false;
        _error = null;
      });
      _syncProgress(1);
      _preloadNextChapter(newIndex + 1);

      if (_mode != ReaderMode.webtoon && _pageController.hasClients && jumpToStart) {
        _pageController.jumpToPage(0);
      }
    } else {
      _loadCurrentChapter();
    }
  }

  void _go(int p) {
    final target = p.clamp(1, _totalPages);
    setState(() => _page = target);
    _syncProgress(target);

    if (_mode != ReaderMode.webtoon && _pageController.hasClients) {
      _pageController.jumpToPage(target - 1);
    } else if (_mode == ReaderMode.webtoon && _scrollController.hasClients) {
      final max = _scrollController.position.maxScrollExtent;
      final offset = (target - 1) * (max / (_totalPages > 1 ? _totalPages - 1 : 1));
      _scrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _setMode(ReaderMode mode) {
    setState(() {
      _mode = mode;
      _pageController.dispose();
      _pageController = PageController(initialPage: _page - 1);
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
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Content reader layer
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _chrome = !_chrome),
            child: _buildReaderBody(),
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

  Widget _buildReaderBody() {
    if (_loading && !_pagesCache.containsKey(_currentChapter.id)) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    if (_error != null && !_pagesCache.containsKey(_currentChapter.id)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 44, color: AppColors.muted),
              const SizedBox(height: 12),
              Text(
                'Could not load chapter pages',
                style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadCurrentChapter,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry'),
                style: FilledButton.styleFrom(backgroundColor: AppColors.surfaceHigh),
              ),
            ],
          ),
        ),
      );
    }

    if (_mode == ReaderMode.webtoon) {
      return _buildWebtoonReader();
    } else {
      return _buildPagedReader();
    }
  }

  // ---- Continuous Webtoon Reader ----

  Widget _buildWebtoonReader() {
    // Build continuous feed elements
    final feedItems = <_FeedItem>[];

    for (var k = 0; k < _webtoonLoadedIndices.length; k++) {
      final chIdx = _webtoonLoadedIndices[k];
      final chapter = _chapters[chIdx];
      final pages = _pagesCache[chapter.id] ?? const [];

      if (k > 0) {
        // Divider between chapter k-1 and chapter k
        feedItems.add(_FeedItem.divider(
          prevChapter: _chapters[_webtoonLoadedIndices[k - 1]],
          nextChapter: chapter,
          chapterIndex: chIdx,
        ));
      }

      for (var p = 0; p < pages.length; p++) {
        feedItems.add(_FeedItem.page(
          chapterIndex: chIdx,
          pageIndex: p,
          totalPages: pages.length,
          url: pages[p],
        ));
      }

      // If chapter k has no cached pages yet, show inline loader
      if (pages.isEmpty && _loadingChapterIds.contains(chapter.id)) {
        feedItems.add(_FeedItem.loader(chapter));
      }
    }

    // If at the end of current loaded chapters and there is a next chapter, add a continuous trigger/footer
    final lastLoadedIdx = _webtoonLoadedIndices.isNotEmpty ? _webtoonLoadedIndices.last : _currentChapterIndex;
    final hasMore = lastLoadedIdx + 1 < _chapters.length;

    if (hasMore) {
      final nextCh = _chapters[lastLoadedIdx + 1];
      feedItems.add(_FeedItem.nextChapterTrigger(nextCh, lastLoadedIdx + 1));
    } else {
      feedItems.add(_FeedItem.endOfManga());
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notif) {
        // Near bottom: auto-load next chapter into continuous strip with zero loading screen
        if (notif.metrics.extentAfter < 1600 && hasMore) {
          final nextIdx = lastLoadedIdx + 1;
          if (!_webtoonLoadedIndices.contains(nextIdx)) {
            setState(() {
              _webtoonLoadedIndices.add(nextIdx);
            });
            _preloadNextChapter(nextIdx);
          }
        }

        // Track active chapter and page by scroll position
        if (_scrollController.hasClients && feedItems.isNotEmpty) {
          final maxExtent = _scrollController.position.maxScrollExtent;
          if (maxExtent > 0) {
            final progress = (_scrollController.offset / maxExtent).clamp(0.0, 1.0);
            final targetItemIdx = (progress * (feedItems.length - 1)).round().clamp(0, feedItems.length - 1);
            final item = feedItems[targetItemIdx];

            if (item.chapterIndex != null && item.chapterIndex != _currentChapterIndex) {
              final oldIdx = _currentChapterIndex;
              final newIdx = item.chapterIndex!;
              _onChapterFinished(oldIdx);

              setState(() {
                _currentChapterIndex = newIdx;
                final chPages = _pagesCache[_chapters[newIdx].id];
                _totalPages = chPages?.isNotEmpty == true ? chPages!.length : 1;
                _page = (item.pageIndex != null ? item.pageIndex! + 1 : 1).clamp(1, _totalPages);
              });
              _syncProgress(_page);
              _preloadNextChapter(newIdx + 1);
            } else if (item.pageIndex != null) {
              final newPage = (item.pageIndex! + 1).clamp(1, _totalPages);
              if (newPage != _page) {
                setState(() => _page = newPage);
                _syncProgress(newPage);
              }
            }
          }
        }
        return false;
      },
      child: ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 50,
          bottom: MediaQuery.paddingOf(context).bottom + 90,
        ),
        itemCount: feedItems.length,
        itemBuilder: (context, i) {
          final item = feedItems[i];
          switch (item.type) {
            case _ItemType.page:
              return CachedNetworkImage(
                imageUrl: item.url!,
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

            case _ItemType.loader:
              return Container(
                height: 220,
                color: AppColors.surface,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2.5),
                      const SizedBox(height: 12),
                      Text(
                        'Seamlessly loading ${item.nextChapter?.displayTitle ?? "next chapter"}...',
                        style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
              );

            case _ItemType.nextTrigger:
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 36),
                child: Center(
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      final nextIdx = item.chapterIndex!;
                      if (!_webtoonLoadedIndices.contains(nextIdx)) {
                        setState(() => _webtoonLoadedIndices.add(nextIdx));
                        _preloadNextChapter(nextIdx);
                      }
                    },
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
        },
      ),
    );
  }

  // ---- Continuous Paged Reader (RTL Japanese Manga & LTR Western) ----

  Widget _buildPagedReader() {
    final curChapter = _currentChapter;
    final pages = _pagesCache[curChapter.id] ?? const [];

    if (pages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_not_supported_outlined, size: 44, color: AppColors.muted),
            const SizedBox(height: 12),
            Text(
              'This chapter has no pages',
              style: GoogleFonts.inter(fontSize: 14, color: AppColors.muted),
            ),
          ],
        ),
      );
    }

    final isRtl = _mode == ReaderMode.rightToLeft;

    // Total items in pageview: pages + 1 transition card to next chapter if available
    final hasNext = _hasNextChapter;
    final pageCount = pages.length + (hasNext ? 1 : 0);

    return PageView.builder(
      controller: _pageController,
      reverse: isRtl,
      itemCount: pageCount,
      onPageChanged: (idx) {
        if (idx < pages.length) {
          setState(() => _page = idx + 1);
          _syncProgress(idx + 1);
        } else if (idx == pages.length && hasNext) {
          // Reached next chapter transition page
          _onChapterFinished(_currentChapterIndex);
          // Automatically switch to next chapter!
          _switchToChapter(_currentChapterIndex + 1);
        }
      },
      itemBuilder: (_, i) {
        if (i < pages.length) {
          return Center(
            child: InteractiveViewer(
              child: CachedNetworkImage(
                imageUrl: pages[i],
                fit: _fitMode,
                placeholder: (_, _) => const Center(
                  child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2),
                ),
                errorWidget: (_, _, _) => Center(
                  child: Text('Page ${i + 1} failed to load', style: const TextStyle(color: AppColors.muted)),
                ),
              ),
            ),
          );
        }

        // Seamless Next Chapter Transition Card
        final nextCh = _chapters[_currentChapterIndex + 1];
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
                  '${_currentChapter.displayTitle} Finished',
                  style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Up next: ${nextCh.displayTitle}',
                  style: GoogleFonts.inter(fontSize: 13, color: AppColors.muted),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => _switchToChapter(_currentChapterIndex + 1),
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
enum _ItemType { page, divider, loader, nextTrigger, endOfManga }

class _FeedItem {
  final _ItemType type;
  final int? chapterIndex;
  final int? pageIndex;
  final int? totalPages;
  final String? url;
  final ChapterItem? prevChapter;
  final ChapterItem? nextChapter;

  const _FeedItem._({
    required this.type,
    this.chapterIndex,
    this.pageIndex,
    this.totalPages,
    this.url,
    this.prevChapter,
    this.nextChapter,
  });

  factory _FeedItem.page({
    required int chapterIndex,
    required int pageIndex,
    required int totalPages,
    required String url,
  }) =>
      _FeedItem._(
        type: _ItemType.page,
        chapterIndex: chapterIndex,
        pageIndex: pageIndex,
        totalPages: totalPages,
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

  factory _FeedItem.loader(ChapterItem chapter) =>
      _FeedItem._(type: _ItemType.loader, nextChapter: chapter);

  factory _FeedItem.nextChapterTrigger(ChapterItem chapter, int chapterIndex) =>
      _FeedItem._(type: _ItemType.nextTrigger, nextChapter: chapter, chapterIndex: chapterIndex);

  factory _FeedItem.endOfManga() => const _FeedItem._(type: _ItemType.endOfManga);
}
