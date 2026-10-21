import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/extension_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/skeleton.dart';
import 'reader_screen.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.manga,
  });

  final MangaItem manga;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late MangaItem _manga;
  List<ChapterItem> _apiChapters = [];
  bool _loadingChapters = false;
  String? _chaptersError;

  bool _inLibrary = false;
  bool _expanded = false;
  bool _descending = true;
  String? _resumeChapterId;
  String _resumeLabel = 'Start Reading';
  Set<String> _readChapterIds = {};

  @override
  void initState() {
    super.initState();
    _manga = widget.manga;
    _loadMangaData();
  }

  Future<void> _loadMangaData() async {
    final m = _manga;
    // 1. Check in library
    final inLib = await ApiService.instance.checkInLibrary(m.id);
    if (mounted) setState(() => _inLibrary = inLib);

    // 2. Fetch full metadata from source if available
    try {
      final full = await ApiService.instance.getManga(m.id);
      if (mounted) setState(() => _manga = full);
    } catch (_) {}

    // 3. Fetch progress & history
    final progress = await ApiService.instance.getMangaProgress(m.id);
    if (mounted && progress.isNotEmpty) {
      final completed = (progress['completedChapterIds'] as List<dynamic>?)?.map((e) => e.toString()).toSet() ?? {};
      final lastRead = progress['lastRead'] as Map<String, dynamic>?;
      setState(() {
        _readChapterIds = completed;
        if (lastRead != null) {
          _resumeChapterId = lastRead['chapterId'] as String?;
          final num = lastRead['chapterNumber'] ?? '';
          _resumeLabel = num.toString().isNotEmpty ? 'Resume Ch. $num' : 'Resume Reading';
        }
      });
    }

    // 4. Load chapters from API
    setState(() => _loadingChapters = true);
    try {
      final chapters = await ApiService.instance.getChapters(m.id);
      if (mounted) {
        setState(() {
          _apiChapters = chapters;
          _loadingChapters = false;
          if (_resumeChapterId == null && chapters.isNotEmpty) {
            // Chapters are sorted descending (latest at 0, chapter 1 at length-1)
            final firstCh = chapters.last;
            _resumeChapterId = firstCh.id;
            _resumeLabel = firstCh.number != null ? 'Start Ch. ${firstCh.number}' : 'Start Reading';
          }
        });
      }
    } catch (err) {
      if (mounted) {
        setState(() {
          _chaptersError = err.toString().replaceFirst('Exception: ', '');
          _loadingChapters = false;
        });
      }
    }
  }

  Future<void> _toggleLibrary() async {
    final m = _manga;
    final newStatus = !_inLibrary;
    setState(() => _inLibrary = newStatus);

    try {
      if (newStatus) {
        await ApiService.instance.addToLibrary(m);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Added to library'), duration: Duration(seconds: 1)),
          );
        }
      } else {
        await ApiService.instance.removeFromLibrary(m.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Removed from library'), duration: Duration(seconds: 1)),
          );
        }
      }
    } catch (err) {
      if (mounted) {
        setState(() => _inLibrary = !newStatus);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update library: $err')),
        );
      }
    }
  }

  void _openReader({String? chapterId, String? chapterNumber, String? title}) {
    if (chapterId == null && _apiChapters.isNotEmpty) {
      chapterId = _descending ? _apiChapters.last.id : _apiChapters.first.id;
      chapterNumber = _descending ? _apiChapters.last.number : _apiChapters.first.number;
      title = _descending ? _apiChapters.last.title : _apiChapters.first.title;
    }

    if (chapterId == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          chapterId: chapterId!,
          mangaId: _manga.id,
          mangaTitle: _manga.title,
          coverUrl: _manga.cover,
          chapterNumber: chapterNumber,
          chapterTitle: title,
        ),
      ),
    ).then((_) {
      if (mounted) {
        _loadMangaData();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;

    return Scaffold(
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: _apiChapters.isNotEmpty
          ? _ResumeFab(
              label: _resumeLabel,
              onTap: () => _openReader(chapterId: _resumeChapterId),
            )
          : null,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _hero(top)),
          SliverToBoxAdapter(child: _actionRow()),
          SliverToBoxAdapter(child: _synopsisBlock()),
          if (_manga.tags.isNotEmpty) SliverToBoxAdapter(child: _chips()),
          SliverToBoxAdapter(child: _sectionTitle()),
          if (_loadingChapters)
            SliverList.builder(
              itemCount: 8,
              itemBuilder: (ctx, i) => const ChapterTileSkeleton(),
            )
          else if (_chaptersError != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Column(
                    children: [
                      Text(
                        'Failed to load chapters: $_chaptersError',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _loadMangaData,
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('Retry'),
                        style: FilledButton.styleFrom(backgroundColor: AppColors.surfaceHigh),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (_apiChapters.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    'No chapters available for this title.',
                    style: GoogleFonts.inter(fontSize: 13, color: AppColors.muted),
                  ),
                ),
              ),
            )
          else
            Builder(
              builder: (context) {
                final chaptersList = _descending ? _apiChapters : _apiChapters.reversed.toList();
                return SliverList.builder(
                  itemCount: chaptersList.length,
                  itemBuilder: (_, i) {
                    final c = chaptersList[i];
                    final isRead = _readChapterIds.contains(c.id);
                    return _ApiChapterTile(
                      chapter: c,
                      isRead: isRead,
                      onTap: () => _openReader(
                        chapterId: c.id,
                        chapterNumber: c.number,
                        title: c.title,
                      ),
                    );
                  },
                );
              },
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 88)),
        ],
      ),
    );
  }

  Widget _hero(double top) {
    final m = _manga;
    final s = m.source.toLowerCase();
    final id = m.id.toLowerCase();

    String sourceName;
    Color sourceColor;

    if (id.startsWith('asura:') || s.contains('asura')) {
      sourceName = 'ASURA SCANS';
      sourceColor = const Color(0xFF6366F1);
    } else if (id.startsWith('flame:') || s.contains('flame')) {
      sourceName = 'FLAME COMICS';
      sourceColor = const Color(0xFFFF5722);
    } else if (id.startsWith('weeb:') || s.contains('weeb')) {
      sourceName = 'WEEB CENTRAL';
      sourceColor = const Color(0xFF00BCD4);
    } else if (id.startsWith('ext:') || (s.isNotEmpty && s != 'mangadex')) {
      final ext = ExtensionService.instance.getExtensionByPkg(m.source);
      sourceName = (ext?.name ?? m.source).toUpperCase();
      sourceColor = const Color(0xFF10B981);
    } else {
      sourceName = 'MANGADEX';
      sourceColor = const Color(0xFFFF6740);
    }

    final title = m.title;
    final authors = m.authors.isNotEmpty ? m.authors.join(' · ') : 'Unknown Author';
    final statusList = <String>[];
    if (m.status.isNotEmpty) statusList.add(m.status.toUpperCase());
    if (m.type.isNotEmpty) statusList.add(m.type.toUpperCase());
    final status = statusList.join(' · ');

    return SizedBox(
      height: 260 + top,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: Transform.scale(
              scale: 1.15,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: CoverImage(imageUrl: m.cover, saturation: .5),
              ),
            ),
          ),
          ColoredBox(color: Colors.black.withValues(alpha: .72)),
          Positioned(
            left: 16,
            right: 16,
            top: top + 72,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: 100,
                  height: 150,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CoverImage(imageUrl: m.cover, saturation: .75),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: sourceColor.withValues(alpha: .2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          sourceName,
                          style: GoogleFonts.inter(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: sourceColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 18,
                          height: 23 / 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        authors,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          height: 17 / 12,
                          color: AppColors.muted,
                        ),
                      ),
                      if (status.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(Icons.schedule_rounded, size: 11, color: AppColors.primary),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                status,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AppTopBar(
              title: '',
              gradient: true,
              onBack: () => Navigator.of(context).maybePop(),
              actions: const [
                BarIcon(Icons.share_outlined, label: 'Share'),
                BarIcon(Icons.more_vert_rounded, label: 'More'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionRow() {
    return Container(
      height: 76,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surface)),
      ),
      child: Row(
        children: [
          _Action(
            icon: _inLibrary ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            label: _inLibrary ? 'In Library' : 'Add to Library',
            active: _inLibrary,
            onTap: _toggleLibrary,
          ),
          const _Action(icon: Icons.sync_rounded, label: 'Tracking'),
          const _Action(icon: Icons.public_rounded, label: 'WebView'),
          const _Action(icon: Icons.share_outlined, label: 'Share'),
        ],
      ),
    );
  }

  Widget _synopsisBlock() {
    final synopsis = _manga.description.isNotEmpty
        ? _manga.description
        : 'No synopsis available.';

    final style = GoogleFonts.inter(fontSize: 12, height: 17 / 12, color: AppColors.muted);
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 7),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: Text.rich(
            TextSpan(
              text: synopsis,
              children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 3),
                    child: Icon(
                      _expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ],
            ),
            style: style,
            maxLines: _expanded ? null : 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  Widget _chips() {
    final chips = _manga.tags.take(6).toList();
    if (chips.isEmpty) return const SizedBox.shrink();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 5, 16, 11),
      child: Row(
        children: [
          for (final t in chips)
            Container(
              height: 28,
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.outline),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(t, style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted)),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle() {
    final count = _apiChapters.length;
    return Container(
      height: 48,
      padding: const EdgeInsets.only(left: 16, right: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.surface)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$count Chapters',
              style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          BarIcon(
            Icons.sort_rounded,
            label: 'Sort order',
            onTap: () => setState(() => _descending = !_descending),
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, this.active = false, this.onTap});
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap ?? () {},
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: active ? AppColors.primary : AppColors.muted),
            const SizedBox(height: 5),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(fontSize: 10, color: active ? AppColors.primary : AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApiChapterTile extends StatelessWidget {
  const _ApiChapterTile({
    required this.chapter,
    required this.isRead,
    required this.onTap,
  });

  final ChapterItem chapter;
  final bool isRead;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isRead ? AppColors.read : AppColors.text;
    final metaColor = isRead ? AppColors.read : AppColors.muted;
    final metaParts = <String>[];
    if (chapter.group.isNotEmpty) metaParts.add(chapter.group);
    if (chapter.pages > 0) metaParts.add('${chapter.pages} pages');

    return InkWell(
      onTap: onTap,
      child: Container(
        height: 56,
        margin: const EdgeInsets.only(left: 16),
        padding: const EdgeInsets.only(right: 9),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.surface)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chapter.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(fontSize: 13, color: color),
                  ),
                  if (metaParts.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      metaParts.join(' · '),
                      style: GoogleFonts.inter(fontSize: 10, color: metaColor),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                isRead ? Icons.check_circle_rounded : Icons.file_download_outlined,
                size: 18,
                color: isRead ? AppColors.primary : AppColors.muted,
              ),
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
  }
}

class _ResumeFab extends StatelessWidget {
  const _ResumeFab({required this.onTap, required this.label});
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primary,
      borderRadius: BorderRadius.circular(16),
      elevation: 3,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.play_arrow_rounded, size: 22, color: AppColors.onPrimary),
              const SizedBox(width: 9),
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
