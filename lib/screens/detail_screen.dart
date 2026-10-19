import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data.dart';
import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'reader_screen.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    this.cover = 0,
    this.manga,
  });

  final int cover;
  final MangaItem? manga;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late final List<ChapterEntry> _dummyChapters;
  List<ChapterItem> _apiChapters = [];
  bool _loadingChapters = false;
  String? _chaptersError;

  bool _inLibrary = false;
  bool _expanded = false;
  bool _descending = true;
  String? _resumeChapterId;
  String _resumeLabel = 'Resume Ch. 1';
  Set<String> _readChapterIds = {};

  @override
  void initState() {
    super.initState();
    _dummyChapters = buildChapters();
    if (widget.manga != null) {
      _loadMangaData();
    } else {
      _inLibrary = true;
    }
  }

  Future<void> _loadMangaData() async {
    final m = widget.manga!;
    // 1. Check in library
    final inLib = await ApiService.instance.checkInLibrary(m.id);
    if (mounted) setState(() => _inLibrary = inLib);

    // 2. Fetch progress & history from MongoDB
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

    // 3. Load chapters from MangaDex via Backend
    setState(() => _loadingChapters = true);
    try {
      final chapters = await ApiService.instance.getChapters(m.id);
      if (mounted) {
        setState(() {
          _apiChapters = chapters;
          _loadingChapters = false;
          if (_resumeChapterId == null && chapters.isNotEmpty) {
            _resumeChapterId = chapters.last.id;
            _resumeLabel = chapters.last.number != null ? 'Start Ch. ${chapters.last.number}' : 'Start Reading';
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
    final m = widget.manga;
    if (m == null) {
      setState(() => _inLibrary = !_inLibrary);
      return;
    }

    if (!ApiService.instance.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sign in under "More" tab to save to MongoDB cloud library!'),
          duration: Duration(seconds: 3),
        ),
      );
    }

    final newStatus = !_inLibrary;
    setState(() => _inLibrary = newStatus);

    try {
      if (newStatus) {
        await ApiService.instance.addToLibrary(m);
      } else {
        await ApiService.instance.removeFromLibrary(m.id);
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

  void _openReader({String? chapterId, int? chapterNum, String? title}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          chapter: chapterNum ?? 1,
          chapterId: chapterId,
          mangaId: widget.manga?.id,
          mangaTitle: widget.manga?.title ?? 'The Breaker: Eternal Force',
          coverUrl: widget.manga?.cover,
          chapterTitle: title,
        ),
      ),
    ).then((_) {
      // Refresh progress when returning from reader
      if (widget.manga != null) {
        _loadMangaData();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isApi = widget.manga != null;
    final top = MediaQuery.paddingOf(context).top;

    return Scaffold(
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: _ResumeFab(
        label: isApi ? _resumeLabel : 'Resume Ch. 142',
        onTap: () {
          if (isApi) {
            _openReader(chapterId: _resumeChapterId);
          } else {
            _openReader(chapterNum: 142);
          }
        },
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _hero(top)),
          SliverToBoxAdapter(child: _actionRow()),
          SliverToBoxAdapter(child: _synopsisBlock()),
          SliverToBoxAdapter(child: _chips()),
          SliverToBoxAdapter(child: _sectionTitle()),
          if (isApi) ...[
            if (_loadingChapters)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CircularProgressIndicator(color: AppColors.primary)),
                ),
              )
            else if (_chaptersError != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'Failed to load chapters: $_chaptersError',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
                    ),
                  ),
                ),
              )
            else
              SliverList.builder(
                itemCount: _apiChapters.length,
                itemBuilder: (_, i) {
                  final list = _descending ? _apiChapters : _apiChapters.reversed.toList();
                  final c = list[i];
                  final isRead = _readChapterIds.contains(c.id);
                  return _ApiChapterTile(
                    chapter: c,
                    isRead: isRead,
                    onTap: () => _openReader(
                      chapterId: c.id,
                      chapterNum: int.tryParse(c.number ?? '1'),
                      title: c.title,
                    ),
                  );
                },
              ),
          ] else ...[
            SliverList.builder(
              itemCount: _dummyChapters.length,
              itemBuilder: (_, i) {
                final list = _descending ? _dummyChapters : _dummyChapters.reversed.toList();
                final c = list[i];
                return _ChapterTile(
                  c,
                  onTap: () => _openReader(chapterNum: c.num, title: c.title),
                );
              },
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 88)),
        ],
      ),
    );
  }

  Widget _hero(double top) {
    final m = widget.manga;
    final title = m?.title ?? 'The Breaker:\nEternal Force';
    final authors = m != null && m.authors.isNotEmpty
        ? m.authors.join(' · ')
        : 'Jeon Geuk-jin · Park Jin-hwan';
    final status = m != null
        ? '${m.status.toUpperCase()} · ${m.type.toUpperCase()}'
        : 'Ongoing · Asura Scans';

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
                child: CoverImage(widget.cover, imageUrl: m?.cover, saturation: .5),
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
                    child: CoverImage(widget.cover, imageUrl: m?.cover, saturation: .75),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                      const SizedBox(height: 9),
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
    final synopsis = widget.manga?.description.isNotEmpty == true
        ? widget.manga!.description
        : 'After his master disappears, a reluctant student is pulled back into the hidden world of martial arts. A new generation gathers around him as old enemies return.';

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
    final chips = widget.manga != null && widget.manga!.tags.isNotEmpty
        ? widget.manga!.tags.take(6).toList()
        : const ['Seinen', 'Action', 'Martial Arts', 'Regression'];

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
    final count = widget.manga != null ? _apiChapters.length : 184;
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
            label: 'Sort and filter',
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

class _ChapterTile extends StatelessWidget {
  const _ChapterTile(this.c, {required this.onTap});
  final ChapterEntry c;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = c.read ? AppColors.read : AppColors.text;
    final metaColor = c.read ? AppColors.read : AppColors.muted;
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
                    'Chapter ${c.num} - ${c.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(fontSize: 13, color: color),
                  ),
                  const SizedBox(height: 4),
                  Text(c.meta, style: GoogleFonts.inter(fontSize: 10, color: metaColor)),
                ],
              ),
            ),
            _DownloadButton(c.state),
          ],
        ),
      ),
    );
  }
}

class _DownloadButton extends StatelessWidget {
  const _DownloadButton(this.state);
  final DownloadState state;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      height: 34,
      child: switch (state) {
        DownloadState.download =>
          const Icon(Icons.file_download_outlined, size: 17, color: AppColors.muted),
        DownloadState.check => const Icon(Icons.check_rounded, size: 17, color: AppColors.primary),
        DownloadState.progress => Stack(
            alignment: Alignment.center,
            children: [
              const SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(
                  value: .25,
                  strokeWidth: 2,
                  color: AppColors.primary,
                  backgroundColor: AppColors.outline,
                ),
              ),
              Container(
                width: 5,
                height: 5,
                decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
              ),
            ],
          ),
      },
    );
  }
}

class _ResumeFab extends StatelessWidget {
  const _ResumeFab({required this.onTap, this.label = 'Resume Ch. 142'});
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
