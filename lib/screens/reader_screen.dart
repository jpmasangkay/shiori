import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/api_service.dart';
import '../theme.dart';
import '../widgets/common.dart';

enum ReaderMode { webtoon, paged }

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    this.chapter = 142,
    this.chapterId,
    this.mangaId,
    this.mangaTitle = 'The Breaker: Eternal Force',
    this.chapterTitle,
    this.coverUrl,
  });

  final int chapter;
  final String? chapterId;
  final String? mangaId;
  final String mangaTitle;
  final String? chapterTitle;
  final String? coverUrl;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  int _totalPages = 24;
  int _page = 1;
  bool _chrome = true;
  bool _loading = false;
  String? _error;
  List<String> _pageUrls = [];
  ReaderMode _mode = ReaderMode.webtoon;

  final _scrollController = ScrollController();
  final _pageController = PageController();

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    if (widget.chapterId != null) {
      _loadPages();
    } else {
      _totalPages = 24;
      _page = 8;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadPages() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final res = await ApiService.instance.getChapterPages(widget.chapterId!);
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
    if (widget.mangaId != null && widget.chapterId != null) {
      final completed = currentPage >= _totalPages && _totalPages > 0;
      ApiService.instance.saveProgress(
        mangaId: widget.mangaId!,
        chapterId: widget.chapterId!,
        mangaTitle: widget.mangaTitle,
        cover: widget.coverUrl,
        chapterNumber: widget.chapter.toString(),
        chapterTitle: widget.chapterTitle,
        page: currentPage,
        totalPages: _totalPages,
        completed: completed,
      );
    }
  }

  void _go(int p) {
    final target = p.clamp(1, _totalPages);
    setState(() => _page = target);
    _syncProgress(target);

    if (_mode == ReaderMode.paged && _pageController.hasClients) {
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

  void _toggleReaderMode() {
    setState(() {
      _mode = _mode == ReaderMode.webtoon ? ReaderMode.paged : ReaderMode.webtoon;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_mode == ReaderMode.webtoon ? 'Mode: Vertical Webtoon' : 'Mode: Horizontal Paged'),
        duration: const Duration(seconds: 1),
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

    // Real MangaDex pages
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
        // Paged horizontal mode
        return PageView.builder(
          controller: _pageController,
          itemCount: _pageUrls.length,
          onPageChanged: (idx) {
            setState(() => _page = idx + 1);
            _syncProgress(idx + 1);
          },
          itemBuilder: (_, i) => Center(
            child: InteractiveViewer(
              child: CachedNetworkImage(
                imageUrl: _pageUrls[i],
                fit: BoxFit.contain,
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

    // Static design fallback
    return const ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(width: 390, height: 844, child: _ComicArt()),
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
                  'Chapter ${widget.chapter} · Page $_page/$_totalPages',
                  style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                ),
              ],
            ),
          ),
          const BarIcon(Icons.bookmark_border_rounded, label: 'Bookmark'),
          const BarIcon(Icons.public_rounded, label: 'WebView'),
        ],
      ),
    );
  }

  Widget _bottom(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final tools = [
      (Icons.view_agenda_outlined, _mode == ReaderMode.webtoon ? 'Webtoon' : 'Paged', _toggleReaderMode),
      (Icons.crop_rounded, 'Crop', () {}),
      (Icons.grid_view_rounded, 'Layout', () {}),
      (Icons.brightness_6_outlined, 'Filter', () {}),
      (Icons.settings_outlined, 'Settings', () {}),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
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
        Container(
          height: 86 + bottom,
          padding: EdgeInsets.only(top: 9, bottom: bottom),
          color: const Color.fromRGBO(17, 19, 24, .94),
          child: Row(
            children: [
              for (final (icon, label, callback) in tools)
                Expanded(
                  child: InkWell(
                    onTap: callback,
                    child: Column(
                      children: [
                        Icon(icon, size: 20, color: AppColors.muted),
                        const SizedBox(height: 7),
                        Text(label, style: GoogleFonts.inter(fontSize: 9, color: AppColors.muted)),
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

/// The monochrome placeholder comic page, drawn on a 390×844 canvas.
class _ComicArt extends StatelessWidget {
  const _ComicArt();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: CustomPaint(painter: _ComicPainter())),
        Positioned(
          top: 294,
          left: 22,
          width: 120,
          height: 76,
          child: Transform.rotate(
            angle: -5 * math.pi / 180,
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFFAF9F3),
                border: Border.all(color: const Color(0xFF171717), width: 2),
                borderRadius: const BorderRadius.all(Radius.elliptical(60, 38)),
              ),
              child: const Text(
                'You should not\nhave come here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Georgia',
                  fontFamilyFallback: ['Times New Roman', 'serif'],
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF111111),
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ComicPainter extends CustomPainter {
  Path _ridge(Rect r) {
    Offset p(double x, double y) => Offset(r.left + r.width * x / 100, r.top + r.height * y / 100);
    return Path()
      ..moveTo(p(0, 66).dx, p(0, 66).dy)
      ..lineTo(p(14, 38).dx, p(14, 38).dy)
      ..lineTo(p(26, 61).dx, p(26, 61).dy)
      ..lineTo(p(45, 18).dx, p(45, 18).dy)
      ..lineTo(p(62, 58).dx, p(62, 58).dy)
      ..lineTo(p(76, 31).dx, p(76, 31).dy)
      ..lineTo(p(100, 65).dx, p(100, 65).dy)
      ..lineTo(p(100, 100).dx, p(100, 100).dy)
      ..lineTo(p(0, 100).dx, p(0, 100).dy)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    const w = 390.0, h = 844.0;
    canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFE5E3DC));

    // Diagonal hatching (repeating-linear-gradient 125deg, 5px period, 24% opacity).
    final hatch = Paint()
      ..color = const Color(0xFF111111).withValues(alpha: .24)
      ..strokeWidth = 1;
    final a = 125 * math.pi / 180;
    final dir = Offset(math.sin(a), -math.cos(a));
    final perp = Offset(-dir.dy, dir.dx);
    const c = Offset(w / 2, h / 2);
    for (double t = -520; t <= 520; t += 5) {
      final o = c + dir * t;
      canvas.drawLine(o - perp * 700, o + perp * 700, hatch);
    }

    // Moon.
    canvas.drawCircle(const Offset(200, 275), 115, Paint()..color = const Color(0xFFF8F7F0));
    canvas.drawCircle(
      const Offset(200, 275),
      113,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = const Color(0xFF242424),
    );

    // Ridges.
    canvas.drawPath(
      _ridge(const Rect.fromLTWH(-25, 504, 440, 250)),
      Paint()..color = const Color(0xFF191919).withValues(alpha: .32),
    );
    canvas.drawPath(
      _ridge(const Rect.fromLTWH(-50, 544, 500, 300)),
      Paint()..color = const Color(0xFF191919).withValues(alpha: .84),
    );

    // Ink figure.
    const f = Rect.fromLTWH(159, 509, 92, 240);
    Offset p(double x, double y) => Offset(f.left + f.width * x / 100, f.top + f.height * y / 100);
    final fig = Path()..moveTo(p(38, 0).dx, p(38, 0).dy);
    for (final pt in const [
      [62, 0], [69, 12], [65, 28], [87, 61], [100, 100],
      [0, 100], [19, 62], [35, 28], [30, 12],
    ]) {
      final o = p(pt[0].toDouble(), pt[1].toDouble());
      fig.lineTo(o.dx, o.dy);
    }
    fig.close();
    canvas.drawPath(fig, Paint()..color = const Color(0xFF0B0B0B));

    // Panel line (450×8, rotated -5deg around its centre).
    canvas.save();
    canvas.translate(195, 454);
    canvas.rotate(-5 * math.pi / 180);
    canvas.drawRect(
      const Rect.fromLTWH(-225, -4, 450, 8),
      Paint()..color = const Color(0xFF111111),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
