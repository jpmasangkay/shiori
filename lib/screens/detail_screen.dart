import 'dart:ui';
import 'package:flutter/material.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/extension_bridge.dart';
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
  bool _loadingChapters = true;
  bool _loadingDetails = true;
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
    _inLibrary = ApiService.instance.isInLibrary(_manga.id);
    ApiService.instance.cacheKnownManga(_manga);
    ApiService.instance.addListener(_onApiChanged);
    DownloadService.instance.addListener(_onDownloadsChanged);
    _loadMangaData();
  }

  @override
  void dispose() {
    ApiService.instance.removeListener(_onApiChanged);
    DownloadService.instance.removeListener(_onDownloadsChanged);
    super.dispose();
  }

  void _onApiChanged() {
    if (!mounted) return;
    final inLib = ApiService.instance.isInLibrary(_manga.id);
    final localRead = ApiService.instance.getReadChapterIds(_manga.id);
    setState(() {
      _inLibrary = inLib;
      _readChapterIds = {..._readChapterIds, ...localRead};
    });
  }

  void _onDownloadsChanged() {
    if (mounted) setState(() {});
  }

  MangaItem _mergeManga(MangaItem base, MangaItem incoming) {
    return MangaItem(
      id: incoming.id.isNotEmpty ? incoming.id : base.id,
      title: (incoming.title.isNotEmpty && incoming.title != 'Untitled')
          ? incoming.title
          : base.title,
      description: incoming.description.isNotEmpty ? incoming.description : base.description,
      status: incoming.status.isNotEmpty ? incoming.status : base.status,
      year: incoming.year ?? base.year,
      tags: incoming.tags.isNotEmpty ? incoming.tags : base.tags,
      cover: incoming.cover.isNotEmpty ? incoming.cover : base.cover,
      authors: incoming.authors.isNotEmpty ? incoming.authors : base.authors,
      lastChapter: (incoming.lastChapter != null && incoming.lastChapter!.isNotEmpty)
          ? incoming.lastChapter
          : base.lastChapter,
      type: incoming.type.isNotEmpty ? incoming.type : base.type,
      source: (incoming.source.isNotEmpty && incoming.source != 'mangadex')
          ? incoming.source
          : (base.source.isNotEmpty ? base.source : incoming.source),
    );
  }

  void _syncResumeButton() {
    if (_resumeChapterId == null && _apiChapters.isNotEmpty) {
      // Chapters are sorted descending (latest at 0, chapter 1 at length-1)
      final firstCh = _apiChapters.last;
      _resumeChapterId = firstCh.id;
      _resumeLabel = firstCh.number != null ? 'Start Ch. ${firstCh.number}' : 'Start Reading';
    }
  }

  Future<void> _loadMangaData() async {
    final m = _manga;
    if (mounted) {
      setState(() {
        if (_apiChapters.isEmpty) {
          _loadingChapters = true;
        }
        _loadingDetails = true;
        _chaptersError = null;
      });
    }

    // Run library status, full metadata, progress, and chapter list in parallel
    final libFuture = ApiService.instance.checkInLibrary(m.id).then((inLib) {
      if (mounted) setState(() => _inLibrary = inLib);
    }).catchError((_) {});

    final detailsFuture = ApiService.instance.getManga(m.id).then((full) {
      if (!mounted) return;
      final merged = _mergeManga(_manga, full);
      setState(() {
        _manga = merged;
        _loadingDetails = false;
      });
      if (merged.cover.isNotEmpty) {
        ApiService.instance.updateCachedMangaMetadata(merged);
      }
    }).catchError((_) {
      if (mounted) setState(() => _loadingDetails = false);
    });

    final progressFuture = () async {
      final localRead = ApiService.instance.getReadChapterIds(m.id);
      try {
        final progress = await ApiService.instance.getMangaProgress(m.id);
        if (!mounted) return;
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
          } else {
            _syncResumeButton();
          }
        });
      } catch (_) {
        if (mounted) {
          setState(() => _readChapterIds = localRead);
        }
      }
    }();

    final chaptersFuture = () async {
      try {
        final chapters = await ApiService.instance.getChapters(m.id);
        if (!mounted) return;
        setState(() {
          _apiChapters = chapters;
          _loadingChapters = false;
          _chaptersError = null;
          _syncResumeButton();
        });
      } catch (err) {
        if (!mounted) return;
        setState(() {
          _chaptersError = err.toString().replaceFirst('Exception: ', '');
          _loadingChapters = false;
        });
      }
    }();

    await Future.wait([libFuture, detailsFuture, progressFuture, chaptersFuture]);
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

  Future<void> _openWebView() async {
    String? webUrl;
    if (_manga.id.startsWith('ext:')) {
      final parts = _manga.id.split(':');
      if (parts.length >= 3) {
        final pkg = parts[1];
        final rawMangaUrl = Uri.decodeComponent(parts.sublist(2).join(':'));
        if (rawMangaUrl.startsWith('http')) {
          webUrl = rawMangaUrl;
        } else {
          final baseUrl = await ExtensionBridge.instance.getSourceBaseUrl(pkg: pkg);
          if (baseUrl != null && baseUrl.isNotEmpty) {
            webUrl = baseUrl.endsWith('/') && rawMangaUrl.startsWith('/')
                ? '$baseUrl${rawMangaUrl.substring(1)}'
                : '$baseUrl$rawMangaUrl';
          }
        }
      }
    }
    if (webUrl == null || webUrl.isEmpty) {
      final src = _manga.source;
      final ext = ExtensionService.instance.getExtensionByPkg(src);
      if (ext != null && ext.homeUrl.isNotEmpty) {
        webUrl = ext.homeUrl;
      }
    }
    if (webUrl != null && webUrl.isNotEmpty) {
      await ExtensionBridge.instance.openInWebView(url: webUrl, title: _manga.title);
      if (mounted) _loadMangaData();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No web URL available for this title')),
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
    double? parseChapterNum(ChapterItem c) {
      if (c.number != null && c.number!.isNotEmpty) {
        final parsed = double.tryParse(c.number!);
        if (parsed != null) return parsed;
      }
      final match = RegExp(r'(?:chapter|ch\.?|ep\.?|episode)\s*(\d+(?:\.\d+)?)', caseSensitive: false).firstMatch(c.title);
      if (match != null) return double.tryParse(match.group(1)!);
      final matchAny = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(c.title);
      if (matchAny != null) return double.tryParse(matchAny.group(1)!);
      return null;
    }

    final readingChapters = [..._apiChapters];
    final firstNum = _apiChapters.isNotEmpty ? parseChapterNum(_apiChapters.first) : null;
    final lastNum = _apiChapters.isNotEmpty ? parseChapterNum(_apiChapters.last) : null;
    final isSourceDescending = (firstNum != null && lastNum != null && firstNum > lastNum);

    readingChapters.sort((a, b) {
      final aNum = parseChapterNum(a);
      final bNum = parseChapterNum(b);
      if (aNum != null && bNum != null && aNum != bNum) {
        return aNum.compareTo(bNum);
      }
      final idxA = _apiChapters.indexOf(a);
      final idxB = _apiChapters.indexOf(b);
      return isSourceDescending ? idxB.compareTo(idxA) : idxA.compareTo(idxB);
    });

    var idx = readingChapters.indexWhere((c) => c.id == chapterId);
    if (idx < 0) idx = 0;

    Navigator.of(context).push(
      smoothRoute(
        ReaderScreen(
          chapterId: chapterId,
          mangaId: _manga.id,
          mangaTitle: _manga.title,
          coverUrl: _manga.cover,
          chapterNumber: chapterNumber,
          chapterTitle: title,
          chapters: readingChapters,
          initialIndex: idx,
          mangaType: _manga.type,
          tags: _manga.tags,
        ),
      ),
    ).then((_) {
      if (mounted) {
        final localRead = ApiService.instance.getReadChapterIds(_manga.id);
        setState(() {
          _readChapterIds = {..._readChapterIds, ...localRead};
        });
        _loadMangaData();
      }
    });
  }

  void _showChapterOptions(ChapterItem chapter, bool isRead, bool isBookmarked) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Text(
                  chapter.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.cardTitle,
                ),
              ),
              ListTile(
                leading: Icon(
                  isRead ? Icons.radio_button_unchecked_rounded : Icons.check_circle_rounded,
                  color: AppColors.primary,
                ),
                title: Text(isRead ? 'Mark as Unread' : 'Mark as Read', style: AppText.bodyMedium),
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
                title: Text(isBookmarked ? 'Remove Bookmark' : 'Bookmark Chapter', style: AppText.bodyMedium),
                onTap: () async {
                  Navigator.pop(context);
                  await ApiService.instance.toggleChapterBookmark(chapter.id);
                  setState(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.done_all_rounded, color: AppColors.primary),
                title: Text('Mark Previous Chapters as Read', style: AppText.bodyMedium),
                subtitle: Text('Marks all older chapters up to this one as read', style: AppText.caption),
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
              ListTile(
                leading: Icon(
                  DownloadService.instance.isChapterDownloaded(chapter.id)
                      ? Icons.delete_outline_rounded
                      : Icons.download_rounded,
                  color: AppColors.primary,
                ),
                title: Text(
                  DownloadService.instance.isChapterDownloaded(chapter.id)
                      ? 'Delete Download'
                      : 'Download Chapter',
                  style: AppText.bodyMedium,
                ),
                onTap: () {
                  Navigator.pop(context);
                  _handleChapterDownload(chapter);
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
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final categories = ApiService.instance.getCategories();
          final assigned = ApiService.instance.getMangaCategoryIds(_manga.id).toSet();
          final media = MediaQuery.of(ctx);
          final availHeight = (media.size.height -
                  media.viewInsets.bottom -
                  media.padding.top -
                  media.padding.bottom -
                  24)
              .clamp(140.0, 520.0);

          return AnimatedPadding(
            duration: const Duration(milliseconds: 150),
            padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
            child: SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: availHeight),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'ASSIGN CATEGORIES',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.sectionHeader,
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton.icon(
                              onPressed: () => _promptCreateCategory(onCreated: () => setSheetState(() {})),
                              icon: const Icon(Icons.add_rounded, size: 16),
                              label: Text('New', style: AppText.chip.copyWith(color: AppColors.primary)),
                              style: TextButton.styleFrom(
                                foregroundColor: AppColors.primary,
                                minimumSize: const Size(44, 44),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(color: AppColors.outline, height: 1),
                      if (categories.isEmpty)
                        Flexible(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(24),
                            child: Center(
                              child: Text(
                                'No categories yet. Create one!',
                                style: AppText.body.copyWith(color: AppColors.muted),
                              ),
                            ),
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: categories.length,
                            itemBuilder: (ctx, i) {
                              final cat = categories[i];
                              final isSelected = assigned.contains(cat.id);
                              return CheckboxListTile(
                                value: isSelected,
                                activeColor: AppColors.primary,
                                title: Text(
                                  cat.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.bodyMedium,
                                ),
                                onChanged: (val) async {
                                  await ApiService.instance.toggleMangaCategory(
                                    _manga.id,
                                    cat.id,
                                    manga: _manga,
                                  );
                                  setSheetState(() {});
                                  if (mounted) {
                                    setState(() {
                                      _inLibrary = ApiService.instance.isInLibrary(_manga.id);
                                    });
                                  }
                                },
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
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
        scrollable: true,
        backgroundColor: AppColors.surface,
        title: Text(
          'New Category',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.sheetTitle,
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: AppText.body,
          decoration: InputDecoration(
            hintText: 'e.g. Favorites, Reading, Shonen',
            hintStyle: AppText.caption,
            focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: AppColors.primary)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
            child: Text('Cancel', style: AppText.bodyMedium.copyWith(color: AppColors.muted)),
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
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              minimumSize: const Size(64, 44),
            ),
            child: Text('Create', style: AppText.bodySemiBold.copyWith(color: AppColors.onPrimary)),
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
          ? FadeSlideIn(
              key: const ValueKey('resume_fab'),
              child: _ResumeFab(
                label: _resumeLabel,
                onTap: () => _openReader(chapterId: _resumeChapterId),
              ),
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
                        style: AppText.caption,
                      ),
                      const SizedBox(height: 12),
                      Builder(builder: (context) {
                        final errLower = _chaptersError!.toLowerCase();
                        final isCf = errLower.contains('403') ||
                            errLower.contains('503') ||
                            errLower.contains('522') ||
                            errLower.contains('cloudflare') ||
                            errLower.contains('cookie') ||
                            errLower.contains('webview') ||
                            errLower.contains('turnstile') ||
                            errLower.contains('challenge');
                        if (isCf) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: FilledButton.icon(
                              onPressed: _openWebView,
                              icon: const Icon(Icons.shield_rounded, size: 16),
                              label: Text(
                                'Solve Cloudflare in WebView',
                                style: AppText.bodySemiBold.copyWith(color: AppColors.onPrimary),
                              ),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: AppColors.onPrimary,
                                minimumSize: const Size(0, 44),
                              ),
                            ),
                          );
                        }
                        return const SizedBox.shrink();
                      }),
                      FilledButton.icon(
                        onPressed: _loadMangaData,
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: Text('Retry', style: AppText.bodySemiBold),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.surfaceHigh,
                          minimumSize: const Size(0, 44),
                        ),
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
                    style: AppText.body.copyWith(color: AppColors.muted),
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
                    final downloadStatus = DownloadService.instance.getStatus(c.id);
                    final downloadProgress = DownloadService.instance.getProgress(c.id);

                    return _ApiChapterTile(
                      chapter: c,
                      isRead: isRead,
                      isBookmarked: isBookmarked,
                      downloadStatus: downloadStatus,
                      downloadProgress: downloadProgress,
                      onToggleDownload: () => _handleChapterDownload(c),
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

  void _handleChapterDownload(ChapterItem c) {
    final status = DownloadService.instance.getStatus(c.id);
    if (status == DownloadStatus.downloaded) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('Delete ${c.displayTitle}?'),
          content: const Text('Remove downloaded chapter from local storage?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                DownloadService.instance.deleteDownloadedChapter(c.id);
              },
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
    } else if (status == DownloadStatus.downloading || status == DownloadStatus.queued) {
      DownloadService.instance.cancelDownload(c.id);
    } else {
      DownloadService.instance.downloadChapter(_manga, c);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Downloading ${c.displayTitle}...'), duration: const Duration(seconds: 1)),
      );
    }
  }

  void _downloadBatch(int count) {
    final unread = _apiChapters.where((c) => !_readChapterIds.contains(c.id)).toList();
    final toDownload = (unread.isNotEmpty ? unread : _apiChapters).take(count).toList();
    for (final c in toDownload) {
      DownloadService.instance.downloadChapter(_manga, c);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Queued ${toDownload.length} chapters for download'), duration: const Duration(seconds: 2)),
    );
  }

  void _downloadUnread() {
    final unread = _apiChapters.where((c) => !_readChapterIds.contains(c.id)).toList();
    for (final c in unread) {
      DownloadService.instance.downloadChapter(_manga, c);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Queued ${unread.length} unread chapters for download'), duration: const Duration(seconds: 2)),
    );
  }

  void _downloadAll() {
    for (final c in _apiChapters) {
      DownloadService.instance.downloadChapter(_manga, c);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Queued ${_apiChapters.length} chapters for download'), duration: const Duration(seconds: 2)),
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
    } else if (id.startsWith('pill:') || id.startsWith('mpill:') || s.contains('mangapill')) {
      sourceName = 'MANGAPILL';
      sourceColor = const Color(0xFF10B981);
    } else if (id.startsWith('katana:') || id.startsWith('mkatana:') || s.contains('mangakatana')) {
      sourceName = 'MANGAKATANA';
      sourceColor = const Color(0xFFF59E0B);
    } else if (id.startsWith('mread:') || s.contains('mangaread')) {
      sourceName = 'MANGAREAD';
      sourceColor = const Color(0xFFEC4899);
    } else if (id.startsWith('ext:') || s.startsWith('ext:')) {
      final rawSpec = id.startsWith('ext:') ? m.id : m.source;
      final parts = rawSpec.split(':');
      final pkgId = parts.length > 1 ? parts[1] : 'extension';
      final ext = ExtensionService.instance.getExtensionByPkg(pkgId);
      String resolvedName = ext?.name ?? pkgId;
      if (pkgId.contains('@') && ext != null && ext.subSources.isNotEmpty) {
        final sel = pkgId.split('@').sublist(1).join('@').toUpperCase();
        final matchSub = ext.subSources.where((sub) =>
            (sub['id'] ?? '').toUpperCase() == sel ||
            (sub['lang'] ?? '').toUpperCase() == sel ||
            (sub['name'] ?? '').toUpperCase() == sel).firstOrNull;
        if (matchSub != null && (matchSub['name'] ?? '').isNotEmpty) {
          resolvedName = matchSub['name']!;
        }
      }
      sourceName = resolvedName.toUpperCase();
      sourceColor = const Color(0xFF8B5CF6);
    } else if (s.isEmpty || s == 'mangadex') {
      sourceName = 'MANGADEX';
      sourceColor = const Color(0xFFFF6740);
    } else {
      sourceName = s.toUpperCase();
      sourceColor = const Color(0xFFE50914);
    }

    return ClipRect(
      child: SizedBox(
        height: 290,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Background cover with blur
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
              child: CoverImage(imageUrl: m.cover, mangaId: m.id, saturation: .5),
            ),
            const ColoredBox(color: Color.fromRGBO(0, 0, 0, .82)),
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
                      child: CoverImage(imageUrl: m.cover, mangaId: m.id),
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
                          style: AppText.badge.copyWith(color: sourceColor),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        m.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.title.copyWith(fontSize: 18, height: 1.2),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        m.authors.isNotEmpty ? m.authors.join(', ') : 'Unknown Author',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption,
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
                            Flexible(
                              child: Text(
                                m.status.toUpperCase(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.badge.copyWith(color: AppColors.muted),
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          Text(
                            m.type.toUpperCase(),
                            style: AppText.badge.copyWith(color: AppColors.muted),
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
    ),
  );
}

  Widget _actionRow() {
    final assignedCategories = ApiService.instance.getMangaCategoryIds(_manga.id);

    return Container(
      constraints: const BoxConstraints(minHeight: 74),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.outline)),
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
          _Action(
            icon: Icons.public_rounded,
            label: 'WebView',
            onTap: _openWebView,
          ),
        ],
      ),
    );
  }

  Widget _synopsisBlock() {
    if (_loadingDetails && _manga.description.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        child: ShimmerLoading(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 11,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                height: 11,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                height: 11,
                width: 190,
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final synopsis = _manga.description.isNotEmpty
        ? _manga.description
        : 'No synopsis available.';

    final style = AppText.body.copyWith(color: AppColors.muted, height: 1.45);
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
              constraints: const BoxConstraints(minHeight: 30),
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.outline),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(t, style: AppText.chip.copyWith(color: AppColors.muted)),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle() {
    final count = _apiChapters.length;
    final readCount = _apiChapters.where((c) => _readChapterIds.contains(c.id)).length;

    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.only(left: 16, right: 8, top: 4, bottom: 4),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.outline)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _loadingChapters && _apiChapters.isEmpty
                ? Row(
                    children: [
                      ShimmerLoading(
                        child: Container(
                          width: 96,
                          height: 15,
                          decoration: BoxDecoration(
                            color: AppColors.surfaceHigh,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Flexible(
                        child: Text(
                          '$count Chapters',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.cardTitle,
                        ),
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
                            style: AppText.badge.copyWith(color: AppColors.primary),
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
            icon: const Icon(Icons.download_rounded, size: 20, color: AppColors.muted),
            color: AppColors.surface,
            tooltip: 'Download options',
            onSelected: (val) {
              if (val == 'next_5') {
                _downloadBatch(5);
              } else if (val == 'next_10') {
                _downloadBatch(10);
              } else if (val == 'unread') {
                _downloadUnread();
              } else if (val == 'all') {
                _downloadAll();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'next_5', child: Text('Download next 5', style: AppText.body)),
              PopupMenuItem(value: 'next_10', child: Text('Download next 10', style: AppText.body)),
              PopupMenuItem(value: 'unread', child: Text('Download unread', style: AppText.body)),
              PopupMenuItem(value: 'all', child: Text('Download all', style: AppText.body)),
            ],
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
              PopupMenuItem(
                value: 'mark_all_read',
                child: Text('Mark all as read', style: AppText.body),
              ),
              PopupMenuItem(
                value: 'mark_all_unread',
                child: Text('Mark all as unread', style: AppText.body),
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
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: active ? AppColors.primary : AppColors.muted),
                const SizedBox(height: 5),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                    color: active ? AppColors.primary : AppColors.muted,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
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
    required this.downloadStatus,
    required this.downloadProgress,
    required this.onTap,
    required this.onToggleRead,
    required this.onToggleBookmark,
    required this.onToggleDownload,
    required this.onLongPress,
  });

  final ChapterItem chapter;
  final bool isRead;
  final bool isBookmarked;
  final DownloadStatus downloadStatus;
  final double downloadProgress;
  final VoidCallback onTap;
  final VoidCallback onToggleRead;
  final VoidCallback onToggleBookmark;
  final VoidCallback onToggleDownload;
  final VoidCallback onLongPress;

  Widget _buildDownloadIcon() {
    switch (downloadStatus) {
      case DownloadStatus.downloaded:
        return IconButton(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          icon: const Icon(Icons.check_circle_rounded, size: 20, color: AppColors.primary),
          tooltip: 'Downloaded (tap to delete)',
          onPressed: onToggleDownload,
        );
      case DownloadStatus.downloading:
        return const SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primary,
              ),
            ),
          ),
        );
      case DownloadStatus.queued:
        return IconButton(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          icon: const Icon(Icons.schedule_rounded, size: 20, color: AppColors.muted),
          tooltip: 'Queued for download',
          onPressed: onToggleDownload,
        );
      case DownloadStatus.failed:
        return IconButton(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          icon: const Icon(Icons.error_outline_rounded, size: 20, color: Colors.redAccent),
          tooltip: 'Download failed (tap to retry)',
          onPressed: onToggleDownload,
        );
      case DownloadStatus.notDownloaded:
        return IconButton(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          icon: Icon(Icons.download_rounded, size: 20, color: AppColors.muted.withValues(alpha: .5)),
          tooltip: 'Download chapter',
          onPressed: onToggleDownload,
        );
    }
  }

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
        constraints: const BoxConstraints(minHeight: 58),
        margin: const EdgeInsets.only(left: 16),
        padding: const EdgeInsets.only(right: 4, top: 6, bottom: 6),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.outline)),
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
                    style: AppText.body.copyWith(
                      fontWeight: isBookmarked ? FontWeight.w600 : FontWeight.w400,
                      color: isBookmarked && !isRead ? AppColors.primary : color,
                    ),
                  ),
                  if (metaParts.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      metaParts.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(color: metaColor),
                    ),
                  ],
                ],
              ),
            ),
            _buildDownloadIcon(),
            IconButton(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              icon: Icon(
                isBookmarked ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                size: 20,
                color: isBookmarked ? AppColors.primary : AppColors.muted.withValues(alpha: .5),
              ),
              tooltip: isBookmarked ? 'Bookmarked' : 'Bookmark chapter',
              onPressed: onToggleBookmark,
            ),
            IconButton(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
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
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.play_arrow_rounded, size: 22, color: AppColors.onPrimary),
              const SizedBox(width: 9),
              Text(
                label,
                style: AppText.bodySemiBold.copyWith(color: AppColors.onPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
