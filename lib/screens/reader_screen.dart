import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

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
    required this.chapterId,
    required this.mangaId,
    required this.mangaTitle,
    this.chapterNumber,
    this.chapterTitle,
    this.coverUrl,
  });

  final String chapterId;
  final String mangaId;
  final String mangaTitle;
  final String? chapterNumber;
  final String? chapterTitle;
  final String? coverUrl;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  int _totalPages = 1;
  int _page = 1;
  bool _chrome = true;
  bool _loading = true;
  String? _error;
  List<String> _pageUrls = [];
  // Default to Japanese Manga Right-to-Left
  ReaderMode _mode = ReaderMode.rightToLeft;
  BoxFit _fitMode = BoxFit.contain;

  final _scrollController = ScrollController();
  late PageController _pageController;

  String get _chapterLabel {
    final n = widget.chapterNumber;
    return (n != null && n.isNotEmpty) ? 'Chapter $n' : (widget.chapterTitle ?? 'Chapter');
  }

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    _loadPages();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadPages() async {
    if (widget.chapterId.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'This chapter is not available.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final res = await ApiService.instance.getChapterPages(widget.chapterId);
      if (mounted) {
        setState(() {
          _pageUrls = res.pages;
          _totalPages = res.pages.isNotEmpty ? res.pages.length : 1;
          _loading = false;
          _page = 1;
        });
        _syncProgress(1);
      }
    } catch (err) {
      if (mounted) {
        setState(() {
          _error = err.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  void _syncProgress(int currentPage) {
    if (widget.mangaId.isEmpty || _pageUrls.isEmpty) return;
    final completed = currentPage >= _totalPages && _totalPages > 0;
    ApiService.instance.saveProgress(
      mangaId: widget.mangaId,
      chapterId: widget.chapterId,
      mangaTitle: widget.mangaTitle,
      cover: widget.coverUrl,
      chapterNumber: widget.chapterNumber,
      chapterTitle: widget.chapterTitle,
      page: currentPage,
      totalPages: _totalPages,
      completed: completed,
    );
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
                  Icons.arrow_back_rounded,
                  color: _mode == ReaderMode.rightToLeft ? AppColors.primary : AppColors.muted,
                ),
                title: const Text('Right to Left (Standard Manga 🇯🇵)'),
                subtitle: const Text('Swipe left for next page, true to Japanese manga direction'),
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
                  Icons.swap_vert_rounded,
                  color: _mode == ReaderMode.webtoon ? AppColors.primary : AppColors.muted,
                ),
                title: const Text('Webtoon (Vertical continuous scroll 🇰🇷)'),
                subtitle: const Text('Smooth vertical strip for manhwa and webtoons'),
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
                  Icons.arrow_forward_rounded,
                  color: _mode == ReaderMode.leftToRight ? AppColors.primary : AppColors.muted,
                ),
                title: const Text('Left to Right (Western comics 🇨🇳)'),
                subtitle: const Text('Standard Western comics and manhua'),
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
          // Content layer
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
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    if (_error != null) {
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
                onPressed: _loadPages,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry'),
                style: FilledButton.styleFrom(backgroundColor: AppColors.surfaceHigh),
              ),
            ],
          ),
        ),
      );
    }

    if (_pageUrls.isNotEmpty) {
      if (_mode == ReaderMode.webtoon) {
        return NotificationListener<ScrollNotification>(
          onNotification: (notif) {
            if (_scrollController.hasClients && _totalPages > 1) {
              final progress = _scrollController.offset / _scrollController.position.maxScrollExtent;
              final curPage = (progress * (_totalPages - 1)).round() + 1;
              final clamped = curPage.clamp(1, _totalPages);
              if (clamped != _page) {
                setState(() => _page = clamped);
                _syncProgress(clamped);
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
            itemCount: _pageUrls.length,
            itemBuilder: (_, i) => CachedNetworkImage(
              imageUrl: _pageUrls[i],
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
                  child: Text('Page ${i + 1} failed to load', style: const TextStyle(color: AppColors.muted)),
                ),
              ),
            ),
          ),
        );
      } else {
        // Paged mode: reverse: true for Right-To-Left Japanese Manga!
        final isRtl = _mode == ReaderMode.rightToLeft;
        return PageView.builder(
          controller: _pageController,
          reverse: isRtl,
          itemCount: _pageUrls.length,
          onPageChanged: (idx) {
            setState(() => _page = idx + 1);
            _syncProgress(idx + 1);
          },
          itemBuilder: (_, i) => Center(
            child: InteractiveViewer(
              child: CachedNetworkImage(
                imageUrl: _pageUrls[i],
                fit: _fitMode,
                placeholder: (_, _) => const Center(
                  child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2),
                ),
                errorWidget: (_, _, _) => Center(
                  child: Text('Page ${i + 1} failed to load', style: const TextStyle(color: AppColors.muted)),
                ),
              ),
            ),
          ),
        );
      }
    }

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

  Widget _topBar(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
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
                const SizedBox(height: 5),
                Text(
                  '$_chapterLabel · Page $_page/$_totalPages',
                  style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                ),
              ],
            ),
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
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
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
        // Clean Bottom Controls (No fake placeholder buttons)
        Container(
          height: 70 + bottom,
          padding: EdgeInsets.only(top: 8, bottom: bottom),
          color: const Color.fromRGBO(17, 19, 24, .95),
          child: Row(
            children: [
              // Direction toggle (RTL Manga / Webtoon / LTR)
              Expanded(
                child: InkWell(
                  onTap: _showModeSheet,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(_mode.icon, size: 20, color: AppColors.primary),
                      const SizedBox(height: 5),
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
                      const SizedBox(height: 5),
                      Text(
                        _fitMode == BoxFit.contain ? 'Fit Page' : 'Fit Width',
                        style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
              ),
              // Quick Jump First Page
              Expanded(
                child: InkWell(
                  onTap: () => _go(1),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.first_page_rounded, size: 20, color: AppColors.text),
                      const SizedBox(height: 5),
                      Text('First Page', style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted)),
                    ],
                  ),
                ),
              ),
              // Quick Jump Last Page
              Expanded(
                child: InkWell(
                  onTap: () => _go(_totalPages),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.last_page_rounded, size: 20, color: AppColors.text),
                      const SizedBox(height: 5),
                      Text('Last Page', style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted)),
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
