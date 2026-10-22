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

    // 3. Fetch progress & history & read status
    final localRead = ApiService.instance.getReadChapterIds(m.id);
    final progress = await ApiService.instance.getMangaProgress(m.id);
    if (mounted) {
      final completed = (progress['completedChapters'] as List<dynamic>?)?.map((e) => e.toString()).toSet() ??
          (progress['completedChapterIds'] as List<dynamic>?)?.map((e) => e.toString()).toSet() ??
          <String>{};
      localRead.addAll(completed);

      final lastRead = progress['lastRead'] as Map<String, dynamic>?;
      setState(() {
        _readChapterIds = localRead;
        if (lastRead != null) {
          _resumeChapterId = lastRead['chapterId'] as String?;
          final num = lastRead['chapterNumber'] ?? '';
          _resumeLabel = num.toString().isNotEmpty ? 'Resume Ch. $num' : 'Resume Reading';
        }
      });
    }

    // 4. Load chapters from API
    if (!mounted) return;
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

    // Build reading chapters in chronological ascending order
    final readingChapters = [..._apiChapters];
    readingChapters.sort((a, b) {
      final aNum = double.tryParse(a.number ?? '') ?? 0;
      final bNum = double.tryParse(b.number ?? '') ?? 0;
      if (aNum != bNum) return aNum.compareTo(bNum);
      return a.displayTitle.compareTo(b.displayTitle);
    });

    var idx = readingChapters.indexWhere((c) => c.id == chapterId);
    if (idx < 0) idx = 0;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          chapterId: chapterId,
          mangaId: _manga.id,
          mangaTitle: _manga.title,
          coverUrl: _manga.cover,
          chapterNumber: chapterNumber,
          chapterTitle: title,
          chapters: readingChapters,
          initialIndex: idx,
        ),
      ),
    ).then((_) {
      if (mounted) {
        _loadMangaData();
      }
    });
  }

  void _showChapterOptions(ChapterItem chapter, bool isRead, bool isBookmarked) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Text(
                  chapter.displayTitle,
                  style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
              ListTile(
                leading: Icon(
                  isRead ? Icons.radio_button_unchecked_rounded : Icons.check_circle_rounded,
                  color: AppColors.primary,
                ),
                title: Text(isRead ? 'Mark as Unread' : 'Mark as Read'),
                onTap: () async {
                  Navigator.pop(context);
                  await ApiService.instance.markChapterRead(_manga.id, chapter.id, read: !isRead);
                  setState(() {
                    if (!isRead) {
                      _readChapterIds.add(chapter.id);
                    } else {
                      _readChapterIds.remove(chapter.id);
                    }
                  });
                },
              ),
              ListTile(
                leading: Icon(
                  isBookmarked ? Icons.bookmark_remove_rounded : Icons.bookmark_add_rounded,
                  color: AppColors.primary,
                ),
                title: Text(isBookmarked ? 'Remove Bookmark' : 'Bookmark Chapter'),
                onTap: () async {
                  Navigator.pop(context);
                  await ApiService.instance.toggleChapterBookmark(chapter.id);
                  setState(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.done_all_rounded, color: AppColors.primary),
                title: const Text('Mark Previous Chapters as Read'),
                subtitle: const Text('Marks all older chapters up to this one as read'),
                onTap: () async {
                  Navigator.pop(context);
                  final readingChapters = [..._apiChapters];
                  readingChapters.sort((a, b) {
                    final aNum = double.tryParse(a.number ?? '') ?? 0;
                    final bNum = double.tryParse(b.number ?? '') ?? 0;
                    if (aNum != bNum) return aNum.compareTo(bNum);
                    return a.displayTitle.compareTo(b.displayTitle);
                  });
                  final curIdx = readingChapters.indexWhere((c) => c.id == chapter.id);
                  if (curIdx >= 0) {
                    final prevIds = readingChapters.sublist(0, curIdx + 1).map((c) => c.id).toList();
                    await ApiService.instance.markChaptersRead(_manga.id, prevIds, read: true);
                    setState(() => _readChapterIds.addAll(prevIds));
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCategorySheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final categories = ApiService.instance.getCategories();
          final assigned = ApiService.instance.getMangaCategoryIds(_manga.id).toSet();

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'ASSIGN CATEGORIES',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1,
                            color: AppColors.muted,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => _promptCreateCategory(onCreated: () => setSheetState(() {})),
                          icon: const Icon(Icons.add_rounded, size: 16),
                          label: const Text('New'),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.primary,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (categories.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('No categories yet. Create one!')),
                    )
                  else
                    ...categories.map((cat) {
                      final isSelected = assigned.contains(cat.id);
                      return CheckboxListTile(
                        value: isSelected,
                        activeColor: AppColors.primary,
                        title: Text(cat.name, style: GoogleFonts.inter(fontSize: 14)),
                        onChanged: (val) async {
                          await ApiService.instance.toggleMangaCategory(_manga.id, cat.id);
                          setSheetState(() {});
                          if (mounted) setState(() {});
                        },
                      );
                    }),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _promptCreateCategory({VoidCallback? onCreated}) async {
    final textController = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('New Category', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600)),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. Favorites, Reading, Shonen',
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.primary)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: AppColors.muted)),
          ),
          FilledButton(
            onPressed: () async {
              final name = textController.text.trim();
              if (name.isNotEmpty) {
                await ApiService.instance.createCategory(name);
                if (ctx.mounted) Navigator.pop(ctx);
                onCreated?.call();
                if (mounted) setState(() {});
              }
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('Create'),
          ),
        ],
      ),
    );
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
                    final isBookmarked = ApiService.instance.isChapterBookmarked(c.id);

                    return _ApiChapterTile(
                      chapter: c,
                      isRead: isRead,
                      isBookmarked: isBookmarked,
                      onTap: () => _openReader(
                        chapterId: c.id,
                        chapterNumber: c.number,
                        title: c.title,
                      ),
                      onToggleRead: () async {
                        final nextState = !isRead;
                        await ApiService.instance.markChapterRead(_manga.id, c.id, read: nextState);
                        setState(() {
                          if (nextState) {
                            _readChapterIds.add(c.id);
                          } else {
                            _readChapterIds.remove(c.id);
                          }
                        });
                      },
                      onToggleBookmark: () async {
                        await ApiService.instance.toggleChapterBookmark(c.id);
                        setState(() {});
                      },
                      onLongPress: () => _showChapterOptions(c, isRead, isBookmarked),
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
    } else if (id.startsWith('ext:') || s.startsWith('ext:')) {
      final parts = (id.startsWith('ext:') ? id : s).split(':');
      final pkgId = parts.length > 1 ? parts[1] : 'extension';
      final ext = ExtensionService.instance.installedExtensions.where((e) => e.pkg == pkgId).firstOrNull;
      sourceName = (ext?.name ?? pkgId).toUpperCase();
      sourceColor = const Color(0xFF8B5CF6);
    } else {
      sourceName = s.toUpperCase();
      sourceColor = const Color(0xFFE50914);
    }

    return SizedBox(
      height: 290,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Background blur
          CoverImage(imageUrl: m.cover, saturation: .5),
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: const ColoredBox(color: Color.fromRGBO(5, 6, 9, .78)),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, AppColors.bg],
              ),
            ),
          ),
          // Content
          Positioned(
            left: 16,
            right: 16,
            bottom: 12,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Hero(
                  tag: 'cover_${m.id}',
                  child: Container(
                    width: 104,
                    height: 154,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.black.withValues(alpha: .5),
                          blurRadius: 16,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CoverImage(imageUrl: m.cover),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: sourceColor.withValues(alpha: .2),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: sourceColor.withValues(alpha: .5), width: .8),
                        ),
                        child: Text(
                          sourceName,
                          style: GoogleFonts.inter(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .8,
                            color: sourceColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        m.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        m.authors.isNotEmpty ? m.authors.join(', ') : 'Unknown Author',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (m.status.isNotEmpty) ...[
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: m.status.toLowerCase() == 'completed'
                                    ? const Color(0xFF4ADE80)
                                    : AppColors.primary,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              m.status.toUpperCase(),
                              style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                            ),
                            const SizedBox(width: 10),
                          ],
                          Text(
                            m.type.toUpperCase(),
                            style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Top Navigation Bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AppTopBar(
              title: '',
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
    final assignedCategories = ApiService.instance.getMangaCategoryIds(_manga.id);

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
          _Action(
            icon: Icons.label_outline_rounded,
            label: assignedCategories.isNotEmpty ? 'Categories (${assignedCategories.length})' : 'Categories',
            active: assignedCategories.isNotEmpty,
            onTap: _showCategorySheet,
          ),
          _Action(
            icon: Icons.bookmark_added_rounded,
            label: 'Bookmarked',
            active: _apiChapters.any((c) => ApiService.instance.isChapterBookmarked(c.id)),
            onTap: () {
              final bms = _apiChapters.where((c) => ApiService.instance.isChapterBookmarked(c.id)).toList();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(bms.isNotEmpty ? '${bms.length} chapters bookmarked' : 'No chapters bookmarked yet'),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          ),
          const _Action(icon: Icons.public_rounded, label: 'WebView'),
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
    final readCount = _apiChapters.where((c) => _readChapterIds.contains(c.id)).length;

    return Container(
      height: 48,
      padding: const EdgeInsets.only(left: 16, right: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.surface)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Text(
                  '$count Chapters',
                  style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                if (readCount > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '$readCount read',
                      style: GoogleFonts.inter(fontSize: 10, color: AppColors.primary),
                    ),
                  ),
                ],
              ],
            ),
          ),
          BarIcon(
            Icons.sort_rounded,
            label: _descending ? 'Descending' : 'Ascending',
            onTap: () => setState(() => _descending = !_descending),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, size: 20, color: AppColors.muted),
            color: AppColors.surface,
            onSelected: (val) async {
              if (val == 'mark_all_read') {
                final allIds = _apiChapters.map((c) => c.id).toList();
                await ApiService.instance.markChaptersRead(_manga.id, allIds, read: true);
                setState(() => _readChapterIds.addAll(allIds));
              } else if (val == 'mark_all_unread') {
                final allIds = _apiChapters.map((c) => c.id).toList();
                await ApiService.instance.markChaptersRead(_manga.id, allIds, read: false);
                setState(() => _readChapterIds.removeAll(allIds));
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'mark_all_read',
                child: Text('Mark all as read'),
              ),
              const PopupMenuItem(
                value: 'mark_all_unread',
                child: Text('Mark all as unread'),
              ),
            ],
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
    required this.isBookmarked,
    required this.onTap,
    required this.onToggleRead,
    required this.onToggleBookmark,
    required this.onLongPress,
  });

  final ChapterItem chapter;
  final bool isRead;
  final bool isBookmarked;
  final VoidCallback onTap;
  final VoidCallback onToggleRead;
  final VoidCallback onToggleBookmark;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final color = isRead ? AppColors.read : AppColors.text;
    final metaColor = isRead ? AppColors.read : AppColors.muted;
    final metaParts = <String>[];
    if (chapter.group.isNotEmpty) metaParts.add(chapter.group);
    if (chapter.pages > 0) metaParts.add('${chapter.pages} pages');

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        height: 58,
        margin: const EdgeInsets.only(left: 16),
        padding: const EdgeInsets.only(right: 6),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.surface)),
        ),
        child: Row(
          children: [
            if (isBookmarked) ...[
              const Icon(Icons.bookmark_rounded, size: 16, color: AppColors.primary),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chapter.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: isBookmarked ? FontWeight.w600 : FontWeight.w400,
                      color: isBookmarked && !isRead ? AppColors.primary : color,
                    ),
                  ),
                  if (metaParts.isNotEmpty) ...[
                    const SizedBox(height: 3),
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
                isBookmarked ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                size: 20,
                color: isBookmarked ? AppColors.primary : AppColors.muted.withValues(alpha: .5),
              ),
              tooltip: isBookmarked ? 'Bookmarked' : 'Bookmark chapter',
              onPressed: onToggleBookmark,
            ),
            IconButton(
              icon: Icon(
                isRead ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: isRead ? AppColors.primary : AppColors.muted.withValues(alpha: .5),
              ),
              tooltip: isRead ? 'Mark as unread' : 'Mark as read',
              onPressed: onToggleRead,
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
