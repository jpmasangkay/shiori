import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../display_settings.dart';
import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/extension_service.dart';
import '../services/reader_settings.dart';
import '../services/source_manager.dart';
import '../services/tracker_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/duplicate_migration_sheet.dart';
import '../widgets/skeleton.dart';
import 'detail_screen.dart';
import 'display_sheet.dart';
import 'reader_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    this.isActive = true,
    this.onBrowseSources,
  });

  final bool isActive;
  final VoidCallback? onBrowseSources;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with WidgetsBindingObserver {
  String? _category;
  List<MangaItem> _userLibrary = [];
  bool _loading = false;
  bool _dirty = false;
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedIds = {};

  bool get _isSelectionMode => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Instant synchronous local hydration (0ms load time — Mihon-style local-first)
    _userLibrary = ApiService.instance.libraryRepo.getLibraryItems();
    if (_userLibrary.isEmpty && ApiService.instance.isLoggedIn) {
      _loadUserLibrary(silent: false);
    }
    ApiService.instance.addListener(_onServiceChanged);
    DownloadService.instance.addListener(_onServiceChanged);
  }

  @override
  void didUpdateWidget(covariant LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive && _dirty) {
      _dirty = false;
      _syncLocalLibrary();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    ApiService.instance.removeListener(_onServiceChanged);
    DownloadService.instance.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _syncLocalLibrary() {
    if (!mounted) return;
    setState(() {
      _userLibrary = ApiService.instance.libraryRepo.getLibraryItems();
      _cachedDuplicateGroups = null;
      _loading = false;
    });
  }

  void _onServiceChanged() {
    if (!widget.isActive) {
      _dirty = true;
      return;
    }
    _syncLocalLibrary();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncLocalLibrary();
    }
  }

  Future<void> _loadUserLibrary({
    bool silent = false,
    bool forceCloudSync = false,
  }) async {
    if (!silent && _userLibrary.isEmpty) {
      setState(() => _loading = true);
    }
    try {
      final items = await ApiService.instance.getLibrary(
        forceCloudSync: forceCloudSync,
      );
      if (mounted) {
        setState(() {
          _userLibrary = items;
          _cachedDuplicateGroups = null;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshLibraryWithUpdates() async {
    if (ApiService.instance.isLoggedIn) {
      await ApiService.instance.syncAllCloudData();
    }
    await _loadUserLibrary(silent: false, forceCloudSync: true);
    final newChapters = await ApiService.instance.checkForLibraryUpdates();
    if (mounted && newChapters > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Found $newChapters new chapters in your library!'),
          backgroundColor: AppColors.surfaceHigh,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  List<MangaItem> _visibleItems(DisplaySettings s, List<(String?, String)> visibleTabs) {
    List<MangaItem> items;
    if (!s.categoryTabs || visibleTabs.isEmpty) {
      items = [..._userLibrary];
    } else if (_category == '__all__') {
      items = [..._userLibrary];
    } else if (_category == null) {
      final validCatIds = ApiService.instance
          .getCategories()
          .map((c) => c.id)
          .toSet();
      items = _userLibrary.where((m) {
        final catIds = ApiService.instance.getMangaCategoryIds(m.id);
        return !catIds.any(validCatIds.contains);
      }).toList();
    } else {
      items = _userLibrary.where((m) {
        final catIds = ApiService.instance.getMangaCategoryIds(m.id);
        return catIds.contains(_category);
      }).toList();
    }

    // Apply in-library search query
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      items = items.where((m) {
        if (m.displayTitle.toLowerCase().contains(q)) return true;
        if (m.authors.any((a) => a.toLowerCase().contains(q))) return true;
        if (m.tags.any((t) => t.toLowerCase().contains(q))) return true;
        if (m.source.toLowerCase().contains(q)) return true;
        return false;
      }).toList();
    }

    // Apply library filters from DisplaySettings
    if (s.filterDownloaded) {
      items = items
          .where((m) => DownloadService.instance.getDownloadedCountForManga(m.id) > 0)
          .toList();
    }
    if (s.filterUnread) {
      items = items.where((m) => ApiService.instance.getUnreadCount(m.id) > 0).toList();
    }
    if (s.filterCompleted) {
      items = items.where((m) {
        final st = m.status.toLowerCase();
        return st.contains('completed') || st.contains('complete');
      }).toList();
    }
    if (s.filterTracked) {
      items = items.where((m) => TrackerService.instance.isMangaTracked(m.id)).toList();
    }

    return _sortItems(items, s.sort, ascending: s.sortAscending);
  }

  List<MangaItem> _sortItems(
    List<MangaItem> items,
    LibrarySort sort, {
    required bool ascending,
  }) {
    if (sort == LibrarySort.dateAdded) {
      if (ascending) {
        return items.reversed.toList();
      }
      return items;
    } else if (sort == LibrarySort.alphabetical) {
      items.sort((a, b) {
        final cmp = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        return ascending ? cmp : -cmp;
      });
    } else if (sort == LibrarySort.lastRead) {
      final dateMap = <String, DateTime>{
        for (final m in items)
          m.id: ApiService.instance.historyRepo.localProgress[m.id]?.updatedAt ?? DateTime(1970),
      };
      items.sort((a, b) {
        final cmp = dateMap[a.id]!.compareTo(dateMap[b.id]!);
        return ascending ? cmp : -cmp;
      });
    } else if (sort == LibrarySort.lastUpdated) {
      final updatedMap = <String, DateTime>{
        for (final m in items)
          m.id: ApiService.instance.getLatestChapterUpdatedAt(m.id) ??
              DateTime.fromMillisecondsSinceEpoch(0),
      };
      final chapterMap = <String, double>{
        for (final m in items)
          m.id: double.tryParse(m.lastChapter ?? '') ?? 0.0,
      };
      items.sort((a, b) {
        final dateCmp = updatedMap[a.id]!.compareTo(updatedMap[b.id]!);
        final cmp = dateCmp != 0
            ? dateCmp
            : chapterMap[a.id]!.compareTo(chapterMap[b.id]!);
        return ascending ? cmp : -cmp;
      });
    } else if (sort == LibrarySort.unreadCount) {
      final unreadMap = <String, int>{
        for (final m in items)
          m.id: ApiService.instance.getUnreadCount(m.id),
      };
      items.sort((a, b) {
        final cmp = unreadMap[a.id]!.compareTo(unreadMap[b.id]!);
        return ascending ? cmp : -cmp;
      });
    }
    return items;
  }

  Future<void> _removeMangaWithUndo(MangaItem manga) async {
    final originalCategories = ApiService.instance.getMangaCategoryIds(manga.id);
    await ApiService.instance.removeFromLibrary(manga.id);
    if (!mounted) return;
    _syncLocalLibrary();

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Removed "${manga.title}" from library'),
        backgroundColor: AppColors.surfaceHigh,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Undo',
          textColor: AppColors.primary,
          onPressed: () async {
            await ApiService.instance.addToLibrary(manga);
            if (originalCategories.isNotEmpty) {
              await ApiService.instance.setMangaCategories(manga.id, originalCategories, manga: manga);
            }
            if (mounted) _syncLocalLibrary();
          },
        ),
      ),
    );
  }

  void _quickResumeManga(MangaItem manga) {
    final target = ApiService.instance.resolveResumeTarget(
      manga.id,
      skipDuplicateChapters: ReaderSettings.instance.skipDuplicateChapters,
    );
    final targetChId = target.chapterId;
    if (targetChId != null && targetChId.isNotEmpty) {
      Navigator.of(context)
          .push(
            smoothRoute(
              ReaderScreen(
                chapterId: targetChId,
                mangaId: manga.id,
                mangaTitle: manga.displayTitle,
                coverUrl: manga.cover,
                chapterNumber: target.chapterNumber,
                chapterTitle: target.chapterTitle,
                chapters: target.orderedChapters,
                initialIndex: target.chapterIndex,
                initialPage: target.page,
                mangaType: manga.type,
                tags: manga.tags,
              ),
            ),
          )
          .then((_) => _syncLocalLibrary());
      return;
    }
    _openManga(manga);
  }

  void _toggleSelection(String mangaId) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedIds.contains(mangaId)) {
        _selectedIds.remove(mangaId);
      } else {
        _selectedIds.add(mangaId);
      }
    });
  }

  Future<void> _batchRemoveSelected() async {
    final selectedItems = _userLibrary
        .where((m) => _selectedIds.contains(m.id))
        .toList();
    if (selectedItems.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          'Remove ${selectedItems.length} ${selectedItems.length == 1 ? 'title' : 'titles'}?',
          style: AppText.sheetTitle,
        ),
        content: Text(
          'Selected titles will be removed from your library. You can undo right after.',
          style: AppText.body.copyWith(color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: AppText.bodyMedium.copyWith(color: AppColors.muted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: Text('Remove', style: AppText.bodySemiBold.copyWith(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final removedWithCats = <(MangaItem, List<String>)>[
      for (final m in selectedItems)
        (m, ApiService.instance.getMangaCategoryIds(m.id)),
    ];
    setState(() => _selectedIds.clear());
    for (final (m, _) in removedWithCats) {
      await ApiService.instance.removeFromLibrary(m.id);
    }
    if (!mounted) return;
    _syncLocalLibrary();
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Removed ${removedWithCats.length} titles from library'),
        backgroundColor: AppColors.surfaceHigh,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Undo',
          textColor: AppColors.primary,
          onPressed: () async {
            for (final (m, catIds) in removedWithCats) {
              await ApiService.instance.addToLibrary(m);
              if (catIds.isNotEmpty) {
                await ApiService.instance.setMangaCategories(m.id, catIds, manga: m);
              }
            }
            if (mounted) _syncLocalLibrary();
          },
        ),
      ),
    );
  }

  Future<void> _batchAssignCategories() async {
    final selectedItems = _userLibrary
        .where((m) => _selectedIds.contains(m.id))
        .toList();
    if (selectedItems.isEmpty) return;
    final cats = ApiService.instance.getCategories();
    if (cats.isEmpty) {
      await _promptCreateCategory();
      return;
    }

    // Tri-state map: true = add to all, false = remove from all, null = leave unchanged
    final states = <String, bool?>{};
    for (final c in cats) {
      var count = 0;
      for (final m in selectedItems) {
        if (ApiService.instance.getMangaCategoryIds(m.id).contains(c.id)) {
          count++;
        }
      }
      if (count == 0) {
        states[c.id] = false;
      } else if (count == selectedItems.length) {
        states[c.id] = true;
      } else {
        states[c.id] = null;
      }
    }

    final applied = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('Assign Categories (${selectedItems.length})', style: AppText.sheetTitle),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: cats.length,
              itemBuilder: (_, i) {
                final c = cats[i];
                final state = states[c.id];
                return CheckboxListTile(
                  tristate: true,
                  value: state,
                  activeColor: AppColors.primary,
                  title: Text(c.name, style: AppText.body),
                  subtitle: state == null
                      ? Text('Partially assigned (leave unchanged)', style: AppText.caption)
                      : null,
                  onChanged: (v) {
                    setDlg(() {
                      states[c.id] = v;
                    });
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (applied != true || !mounted) return;
    for (final m in selectedItems) {
      final current = ApiService.instance.getMangaCategoryIds(m.id).toSet();
      for (final c in cats) {
        final st = states[c.id];
        if (st == true) {
          current.add(c.id);
        } else if (st == false) {
          current.remove(c.id);
        }
        // st == null preserves existing assignment for this title
      }
      await ApiService.instance.setMangaCategories(m.id, current.toList(), manga: m);
    }
    setState(() => _selectedIds.clear());
    _syncLocalLibrary();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Updated categories for ${selectedItems.length} titles')),
      );
    }
  }

  Future<void> _batchMarkRead() async {
    final selectedItems = _userLibrary
        .where((m) => _selectedIds.contains(m.id))
        .toList();
    if (selectedItems.isEmpty) return;
    setState(() => _selectedIds.clear());
    var markedChapters = 0;
    for (final m in selectedItems) {
      final cached = ApiService.instance.getCachedChapters(m.id);
      if (cached.isNotEmpty) {
        await ApiService.instance.markChaptersRead(
          m.id,
          cached.map((c) => c.id).toList(),
          read: true,
        );
        markedChapters += cached.length;
      }
    }
    if (mounted) {
      _syncLocalLibrary();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Marked $markedChapters cached chapters read across ${selectedItems.length} titles'),
        ),
      );
    }
  }

  Future<void> _batchDownloadUnread() async {
    final selectedItems = _userLibrary
        .where((m) => _selectedIds.contains(m.id))
        .toList();
    if (selectedItems.isEmpty) return;
    setState(() => _selectedIds.clear());
    var queued = 0;
    for (final m in selectedItems) {
      final cached = ApiService.instance.getCachedChapters(m.id);
      final unread = cached
          .where((c) => !ApiService.instance.isChapterRead(m.id, c.id))
          .take(5)
          .toList();
      for (final ch in unread) {
        await DownloadService.instance.downloadChapter(m, ch);
        queued++;
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Queued $queued unread chapters for download')),
      );
    }
  }

  Future<void> _batchMassMigrate() async {
    final selectedItems = _userLibrary
        .where((m) => _selectedIds.contains(m.id))
        .toList();
    if (selectedItems.isEmpty) return;

    final targetSources = <(String id, String name)>[
      for (final ds in SourceManager.directSources) (ds.id, ds.name),
      if (!SourceManager.isIOSPlatform)
        for (final ext in ExtensionService.instance.installedExtensions)
          (ext.pkg, ext.name),
    ];
    if (targetSources.isEmpty) return;

    String selectedSourceId = targetSources.first.$1;
    var migrating = false;
    var doneCount = 0;
    var migratedCount = 0;
    String statusText = 'Pick a destination source to migrate ${selectedItems.length} selected titles:';

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.swap_horiz_rounded, color: AppColors.primary, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Mass Migrate (${selectedItems.length} titles)',
                        style: AppText.sheetTitle,
                      ),
                    ),
                    if (!migrating)
                      IconButton(
                        icon: Icon(Icons.close_rounded, color: AppColors.muted),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(statusText, style: AppText.caption),
                const SizedBox(height: 12),
                if (!migrating)
                  DropdownButtonFormField<String>(
                    initialValue: selectedSourceId,
                    dropdownColor: AppColors.surfaceHigh,
                    style: AppText.body,
                    decoration: InputDecoration(
                      labelText: 'Target Source',
                      filled: true,
                      fillColor: AppColors.surfaceHigh,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    items: [
                      for (final src in targetSources)
                        DropdownMenuItem(value: src.$1, child: Text(src.$2)),
                    ],
                    onChanged: (v) {
                      if (v != null) setSheet(() => selectedSourceId = v);
                    },
                  )
                else ...[
                  LinearProgressIndicator(
                    value: selectedItems.isEmpty ? 0 : doneCount / selectedItems.length,
                    color: AppColors.primary,
                    backgroundColor: AppColors.surfaceHigh,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Processed $doneCount / ${selectedItems.length} ($migratedCount matched)',
                    style: AppText.caption.copyWith(color: AppColors.primary),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: migrating
                      ? null
                      : () async {
                          setSheet(() {
                            migrating = true;
                            doneCount = 0;
                            migratedCount = 0;
                            statusText = 'Searching destination source & migrating reading progress...';
                          });
                          for (final oldManga in selectedItems) {
                            try {
                              final results = await ApiService.instance
                                  .searchManga(
                                    query: oldManga.displayTitle,
                                    source: selectedSourceId,
                                    limit: 5,
                                  )
                                  .timeout(const Duration(seconds: 12), onTimeout: () => const []);
                              final match = results.where((r) => r.id != oldManga.id).firstOrNull;
                              if (match != null) {
                                final cats = ApiService.instance.getMangaCategoryIds(oldManga.id);
                                await ApiService.instance.addToLibrary(match);
                                if (cats.isNotEmpty) {
                                  await ApiService.instance.setMangaCategories(match.id, cats, manga: match);
                                }
                                final targetChapters = await ApiService.instance
                                    .getChapters(match.id)
                                    .catchError((_) => const <ChapterItem>[]);
                                await ApiService.instance.migrateOrCopyReadingProgress(
                                  sourceMangaId: oldManga.id,
                                  targetManga: match,
                                  targetChapters: targetChapters,
                                );
                                await ApiService.instance.removeFromLibrary(oldManga.id);
                                migratedCount++;
                              }
                            } catch (_) {}
                            doneCount++;
                            if (ctx.mounted) setSheet(() {});
                          }
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (mounted) {
                            setState(() => _selectedIds.clear());
                            _syncLocalLibrary();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Migrated $migratedCount of ${selectedItems.length} titles!',
                                ),
                              ),
                            );
                          }
                        },
                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                  label: Text(migrating ? 'Migrating...' : 'Start Mass Migration'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimary,
                    minimumSize: const Size.fromHeight(44),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showMangaContextMenu(MangaItem manga) {
    final target = ApiService.instance.resolveResumeTarget(
      manga.id,
      skipDuplicateChapters: ReaderSettings.instance.skipDuplicateChapters,
    );
    final canQuickResume = target.chapterId != null && target.chapterId!.isNotEmpty;
    final resumeLabel = canQuickResume
        ? (target.page > 1 && !target.isCaughtUp
            ? '${target.label} (Page ${target.page})'
            : target.label)
        : 'Start Reading';

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 32,
                height: 4,
                margin: const EdgeInsets.only(top: 4, bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.read,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 36,
                      height: 48,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: CoverImage(imageUrl: manga.cover, mangaId: manga.id),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        manga.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.cardTitle,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(color: AppColors.outline, height: 16),
              if (canQuickResume)
                ListTile(
                  leading: Icon(Icons.play_arrow_rounded, color: AppColors.primary),
                  title: Text(resumeLabel, style: TextStyle(color: AppColors.text)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _quickResumeManga(manga);
                  },
                ),
              ListTile(
                leading: Icon(Icons.label_outline_rounded, color: AppColors.primary),
                title: Text('Set Categories', style: TextStyle(color: AppColors.text)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showMangaCategoryDialog(manga);
                },
              ),
              ListTile(
                leading: Icon(Icons.checklist_rounded, color: AppColors.primary),
                title: Text('Select Multiple', style: TextStyle(color: AppColors.text)),
                onTap: () {
                  Navigator.pop(ctx);
                  _toggleSelection(manga.id);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                title: const Text('Remove from Library', style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(ctx);
                  _removeMangaWithUndo(manga);
                },
              ),
            ],
          ),
        ),
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
            hintText: 'e.g. Reading, Favorites, Shonen',
            hintStyle: AppText.caption,
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.primary),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
            child: Text(
              'Cancel',
              style: AppText.bodyMedium.copyWith(color: AppColors.muted),
            ),
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
            child: Text(
              'Create',
              style: AppText.bodySemiBold.copyWith(color: AppColors.onPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _promptRenameCategory(
    CategoryItem cat, {
    VoidCallback? onRenamed,
  }) async {
    final textController = TextEditingController(text: cat.name);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        backgroundColor: AppColors.surface,
        title: Text(
          'Rename Category',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.sheetTitle,
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: AppText.body,
          decoration: InputDecoration(
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.primary),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
            child: Text(
              'Cancel',
              style: AppText.bodyMedium.copyWith(color: AppColors.muted),
            ),
          ),
          FilledButton(
            onPressed: () async {
              final name = textController.text.trim();
              if (name.isNotEmpty) {
                await ApiService.instance.renameCategory(cat.id, name);
                if (ctx.mounted) Navigator.pop(ctx);
                onRenamed?.call();
                if (mounted) setState(() {});
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              minimumSize: const Size(64, 44),
            ),
            child: Text(
              'Save',
              style: AppText.bodySemiBold.copyWith(color: AppColors.onPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteCategory(
    CategoryItem cat, {
    VoidCallback? onDeleted,
  }) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        backgroundColor: AppColors.surface,
        title: Text(
          'Delete "${cat.name}"?',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppText.sheetTitle,
        ),
        content: Text(
          'Titles in this category will not be deleted from your library.',
          style: AppText.body.copyWith(color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
            child: Text(
              'Cancel',
              style: AppText.bodyMedium.copyWith(color: AppColors.muted),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              minimumSize: const Size(64, 44),
            ),
            child: Text(
              'Delete',
              style: AppText.bodySemiBold.copyWith(color: AppColors.onPrimary),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      if (_category == cat.id) {
        _category = null;
      }
      await ApiService.instance.deleteCategory(cat.id);
      onDeleted?.call();
      if (mounted) setState(() {});
    }
  }

  Map<String, List<MangaItem>>? _cachedDuplicateGroups;

  Map<String, List<MangaItem>> _findDuplicateGroups() {
    if (_cachedDuplicateGroups != null) return _cachedDuplicateGroups!;
    _cachedDuplicateGroups = DuplicateDetector.groupDuplicates(_userLibrary);
    return _cachedDuplicateGroups!;
  }

  void _showResolveDuplicatesSheet(Map<String, List<MangaItem>> duplicateGroups) {
    showLibraryDuplicatesSheet(
      context: context,
      duplicateGroups: duplicateGroups,
      onRefresh: _syncLocalLibrary,
    );
  }

  void _showCategoryManagementSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final cats = ApiService.instance.getCategories();
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'MANAGE CATEGORIES',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.sectionHeader,
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              onPressed: () => _promptCreateCategory(
                                onCreated: () {
                                  setSheetState(() {});
                                  if (mounted) setState(() {});
                                },
                              ),
                              icon: const Icon(Icons.add_rounded, size: 16),
                              label: Text(
                                'Add',
                                style: AppText.chip.copyWith(
                                  color: AppColors.onPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: AppColors.onPrimary,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                minimumSize: const Size(44, 44),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Divider(color: AppColors.outline, height: 1),
                      if (cats.isEmpty)
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
                            itemCount: cats.length,
                            itemBuilder: (ctx, i) {
                              final cat = cats[i];
                              final count = _userLibrary
                                  .where(
                                    (m) => ApiService.instance
                                        .getMangaCategoryIds(m.id)
                                        .contains(cat.id),
                                  )
                                  .length;
                              return ListTile(
                                contentPadding: const EdgeInsets.only(left: 16, right: 8),
                                leading: Icon(
                                  Icons.folder_outlined,
                                  color: AppColors.muted,
                                  size: 20,
                                ),
                                title: Text(
                                  cat.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.bodyMedium,
                                ),
                                subtitle: Text(
                                  displaySettings.excludedUpdateCategoryIds.contains(cat.id)
                                      ? '$count titles · Excluded from updates'
                                      : '$count titles',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.caption,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      constraints: const BoxConstraints(
                                        minWidth: 44,
                                        minHeight: 44,
                                      ),
                                      padding: EdgeInsets.zero,
                                      tooltip: displaySettings.excludedUpdateCategoryIds.contains(cat.id)
                                          ? 'Include in global updates'
                                          : 'Exclude from global updates',
                                      icon: Icon(
                                        displaySettings.excludedUpdateCategoryIds.contains(cat.id)
                                            ? Icons.sync_disabled_rounded
                                            : Icons.sync_rounded,
                                        size: 18,
                                        color: displaySettings.excludedUpdateCategoryIds.contains(cat.id)
                                            ? Colors.orangeAccent
                                            : AppColors.muted,
                                      ),
                                      onPressed: () async {
                                        await displaySettings.toggleExcludedUpdateCategory(cat.id);
                                        setSheetState(() {});
                                      },
                                    ),
                                    IconButton(
                                      constraints: const BoxConstraints(
                                        minWidth: 44,
                                        minHeight: 44,
                                      ),
                                      padding: EdgeInsets.zero,
                                      tooltip: 'Rename category',
                                      icon: Icon(
                                        Icons.edit_outlined,
                                        size: 18,
                                        color: AppColors.muted,
                                      ),
                                      onPressed: () => _promptRenameCategory(
                                        cat,
                                        onRenamed: () {
                                          setSheetState(() {});
                                          if (mounted) setState(() {});
                                        },
                                      ),
                                    ),
                                    IconButton(
                                      constraints: const BoxConstraints(
                                        minWidth: 44,
                                        minHeight: 44,
                                      ),
                                      padding: EdgeInsets.zero,
                                      tooltip: 'Delete category',
                                      icon: Icon(
                                        Icons.delete_outline_rounded,
                                        size: 18,
                                        color: AppColors.muted,
                                      ),
                                      onPressed: () => _confirmDeleteCategory(
                                        cat,
                                        onDeleted: () {
                                          setSheetState(() {});
                                          if (mounted) setState(() {});
                                        },
                                      ),
                                    ),
                                  ],
                                ),
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

  void _showMangaCategoryDialog(MangaItem manga) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final cats = ApiService.instance.getCategories();
          final assigned = ApiService.instance
              .getMangaCategoryIds(manga.id)
              .toSet();
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    manga.displayTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.cardTitle,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Set Categories',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.caption,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton.icon(
                              onPressed: () => _promptCreateCategory(
                                onCreated: () => setSheetState(() {}),
                              ),
                              style: TextButton.styleFrom(
                                minimumSize: const Size(44, 44),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: const Icon(Icons.add_rounded, size: 16),
                              label: Text(
                                'New',
                                style: AppText.chip.copyWith(color: AppColors.primary),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Divider(color: AppColors.outline, height: 1),
                      if (cats.isEmpty)
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
                            itemCount: cats.length,
                            itemBuilder: (ctx, i) {
                              final cat = cats[i];
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
                                    manga.id,
                                    cat.id,
                                    manga: manga,
                                  );
                                  setSheetState(() {});
                                  if (mounted) {
                                    _syncLocalLibrary();
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: displaySettings,
      builder: (context, _) {
        final s = displaySettings;
        final userCats = ApiService.instance.getCategories();
        final validCatIds = userCats.map((c) => c.id).toSet();

        // Optimized single-pass category count calculation for low-end CPUs
        final categoryCounts = <String, int>{};
        int uncategorizedCount = 0;
        for (final m in _userLibrary) {
          final catIds = ApiService.instance.getMangaCategoryIds(m.id);
          bool hasValidCat = false;
          for (final cid in catIds) {
            if (validCatIds.contains(cid)) {
              categoryCounts[cid] = (categoryCounts[cid] ?? 0) + 1;
              hasValidCat = true;
            }
          }
          if (!hasValidCat) {
            uncategorizedCount++;
          }
        }

        // Categories appear when they have items (or when showEmptyCategories is toggled on).
        // Label uncategorized items clearly as 'Default', and prepend a true 'All' tab
        // whenever custom categories are active so users can always see their entire library.
        final visibleTabCategories = <(String?, String)>[];
        final activeCustomCats = [
          for (final c in userCats)
            if ((categoryCounts[c.id] ?? 0) > 0 || s.showEmptyCategories) c,
        ];
        if (activeCustomCats.isNotEmpty) {
          visibleTabCategories.add(('__all__', 'All'));
        }
        if (uncategorizedCount > 0 || s.showEmptyCategories) {
          visibleTabCategories.add((null, activeCustomCats.isNotEmpty ? 'Default' : 'All'));
        }
        for (final c in activeCustomCats) {
          visibleTabCategories.add((c.id, c.name));
        }

        final validTabKeys = visibleTabCategories.map((t) => t.$1).toSet();
        if (!validTabKeys.contains(_category)) {
          _category = visibleTabCategories.isNotEmpty ? visibleTabCategories.first.$1 : null;
        }

        final items = _visibleItems(s, visibleTabCategories);
        final duplicateGroups = _findDuplicateGroups();
        final duplicateCount =
            duplicateGroups.values.fold<int>(0, (sum, l) => sum + l.length);

        return Column(
          children: [
            if (_isSelectionMode)
              AppTopBar(
                title: '${_selectedIds.length} Selected',
                onBack: () => setState(() => _selectedIds.clear()),
                actions: [
                  BarIcon(
                    Icons.select_all_rounded,
                    label: 'Select all',
                    onTap: () {
                      setState(() {
                        if (_selectedIds.length == items.length) {
                          _selectedIds.clear();
                        } else {
                          _selectedIds.addAll(items.map((m) => m.id));
                        }
                      });
                    },
                  ),
                  BarIcon(
                    Icons.delete_outline_rounded,
                    label: 'Remove selected',
                    onTap: _batchRemoveSelected,
                  ),
                ],
              )
            else
              AppTopBar(
                title: 'Library',
                branded: true,
                actions: [
                  if (_userLibrary.isNotEmpty)
                    BarIcon(
                      _isSearching ? Icons.search_off_rounded : Icons.search_rounded,
                      label: 'Search library',
                      onTap: () {
                        setState(() {
                          _isSearching = !_isSearching;
                          if (!_isSearching) {
                            _searchController.clear();
                            _searchQuery = '';
                          }
                        });
                      },
                    ),
                  if (duplicateGroups.isNotEmpty)
                    BarIcon(
                      Icons.copy_all_rounded,
                      label: 'Resolve duplicates (${duplicateGroups.length})',
                      onTap: () => _showResolveDuplicatesSheet(duplicateGroups),
                    ),
                  PopupMenuButton<LibrarySort>(
                    icon: Icon(Icons.sort_rounded, size: 22, color: AppColors.muted),
                    tooltip: 'Sort library',
                    color: AppColors.surface,
                    initialValue: s.sort,
                    onSelected: (val) => s.setSort(val),
                    itemBuilder: (ctx) => [
                      for (final sortOpt in LibrarySort.values)
                        PopupMenuItem(
                          value: sortOpt,
                          child: Row(
                            children: [
                              if (s.sort == sortOpt)
                                Icon(
                                  s.sortAscending
                                      ? Icons.arrow_upward_rounded
                                      : Icons.arrow_downward_rounded,
                                  size: 16,
                                  color: AppColors.primary,
                                )
                              else
                                const SizedBox(width: 16),
                              const SizedBox(width: 8),
                              Text(sortOpt.label, style: AppText.body),
                            ],
                          ),
                        ),
                    ],
                  ),
                  if (!s.categoryTabs || _userLibrary.isEmpty || visibleTabCategories.isEmpty)
                    BarIcon(
                      Icons.playlist_add_rounded,
                      label: 'Manage categories',
                      onTap: _showCategoryManagementSheet,
                    ),
                  BarIcon(
                    Icons.filter_list_rounded,
                    label: 'Filter, sort and display',
                    onTap: () => showDisplaySheet(context, onManageCategories: _showCategoryManagementSheet),
                  ),
                ],
              ),
            if (_isSearching && _userLibrary.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: SizedBox(
                  height: 42,
                  child: TextField(
                    controller: _searchController,
                    autofocus: true,
                    style: AppText.body,
                    decoration: InputDecoration(
                      hintText: 'Search library by title, author, or tag...',
                      hintStyle: AppText.caption,
                      prefixIcon: Icon(Icons.search_rounded, size: 18, color: AppColors.muted),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: Icon(Icons.clear_rounded, size: 16, color: AppColors.muted),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: AppColors.surfaceHigh,
                      contentPadding: EdgeInsets.zero,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (val) => setState(() => _searchQuery = val.trim()),
                  ),
                ),
              ),
            if (s.hasActiveFilters && _userLibrary.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      if (s.filterDownloaded)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InputChip(
                            label: Text('Downloaded', style: AppText.chip),
                            selected: true,
                            onDeleted: () => s.update(() => s.filterDownloaded = false),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      if (s.filterUnread)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InputChip(
                            label: Text('Unread', style: AppText.chip),
                            selected: true,
                            onDeleted: () => s.update(() => s.filterUnread = false),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      if (s.filterCompleted)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InputChip(
                            label: Text('Completed', style: AppText.chip),
                            selected: true,
                            onDeleted: () => s.update(() => s.filterCompleted = false),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      if (s.filterTracked)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InputChip(
                            label: Text('Tracked', style: AppText.chip),
                            selected: true,
                            onDeleted: () => s.update(() => s.filterTracked = false),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      TextButton(
                        onPressed: s.clearFilters,
                        style: TextButton.styleFrom(
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text('Clear filters', style: AppText.caption.copyWith(color: AppColors.primary)),
                      ),
                    ],
                  ),
                ),
              ),
            if (duplicateGroups.isNotEmpty)
              Container(
                margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded, size: 18, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${duplicateGroups.length} duplicate title${duplicateGroups.length > 1 ? "s" : ""} in library ($duplicateCount entries)',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.text,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => _showResolveDuplicatesSheet(duplicateGroups),
                      child: Text(
                        'Resolve',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ValueListenableBuilder<LibraryUpdateProgress>(
              valueListenable: ApiService.instance.libraryUpdateProgress,
              builder: (context, prog, _) {
                if (!prog.isRunning || prog.total <= 0) {
                  return const SizedBox.shrink();
                }
                return Container(
                  margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.primary.withValues(alpha: .4)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Updating library (${prog.completed}/${prog.total})${prog.currentTitle != null ? ' • ${prog.currentTitle}' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.caption.copyWith(
                                color: AppColors.text,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (prog.newChaptersFound > 0)
                            Text(
                              '+${prog.newChaptersFound}',
                              style: AppText.badge.copyWith(color: AppColors.primary),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: prog.fraction,
                          minHeight: 3,
                          color: AppColors.primary,
                          backgroundColor: AppColors.surfaceHigh,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            if (s.categoryTabs && _userLibrary.isNotEmpty && visibleTabCategories.isNotEmpty)
              _Tabs(
                categories: visibleTabCategories,
                selected: _category,
                counts: {
                  '__all__': _userLibrary.length,
                  null: uncategorizedCount,
                  for (final c in userCats) c.id: categoryCounts[c.id] ?? 0,
                },
                onSelect: (c) => setState(() => _category = c),
                onManageCategories: _showCategoryManagementSheet,
              ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (!_isSelectionMode &&
                        s.categoryTabs &&
                        visibleTabCategories.length > 1)
                    ? (details) {
                        final v = details.primaryVelocity ?? 0;
                        if (v.abs() < 320) return;
                        final curIdx = visibleTabCategories
                            .indexWhere((t) => t.$1 == _category);
                        if (curIdx < 0) return;
                        final nextIdx = v < 0 ? curIdx + 1 : curIdx - 1;
                        if (nextIdx >= 0 && nextIdx < visibleTabCategories.length) {
                          HapticFeedback.selectionClick();
                          setState(() => _category = visibleTabCategories[nextIdx].$1);
                        }
                      }
                    : null,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: _loading && _userLibrary.isEmpty
                      ? MangaGridSkeleton(
                          key: const ValueKey('library_skeleton'),
                          count: s.columns * 2,
                          crossAxisCount: s.columns,
                        )
                      : RefreshIndicator(
                          key: const ValueKey('library_content'),
                          color: AppColors.primary,
                          backgroundColor: AppColors.surface,
                          onRefresh: _refreshLibraryWithUpdates,
                          child: items.isEmpty
                              ? LayoutBuilder(
                                  builder: (_, c) => SingleChildScrollView(
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                        minHeight: c.maxHeight,
                                      ),
                                      child: _emptyState(),
                                    ),
                                  ),
                                )
                              : s.mode == DisplayMode.list
                              ? _list(s, items)
                              : _grid(s, items),
                        ),
                ),
              ),
            ),
            if (_isSelectionMode)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border(top: BorderSide(color: AppColors.outline)),
                ),
                child: SafeArea(
                  top: false,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _bulkActionBtn(
                        icon: Icons.label_outline_rounded,
                        label: 'Category',
                        onTap: _batchAssignCategories,
                      ),
                      _bulkActionBtn(
                        icon: Icons.done_all_rounded,
                        label: 'Mark Read',
                        onTap: _batchMarkRead,
                      ),
                      _bulkActionBtn(
                        icon: Icons.download_rounded,
                        label: 'Download',
                        onTap: _batchDownloadUnread,
                      ),
                      _bulkActionBtn(
                        icon: Icons.swap_horiz_rounded,
                        label: 'Migrate',
                        onTap: _batchMassMigrate,
                      ),
                      _bulkActionBtn(
                        icon: Icons.delete_outline_rounded,
                        label: 'Remove',
                        color: Colors.redAccent,
                        onTap: _batchRemoveSelected,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _bulkActionBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    final c = color ?? AppColors.text;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: c),
            const SizedBox(height: 2),
            Text(label, style: AppText.badge.copyWith(color: c)),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    if (_userLibrary.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const EmptyState(
            icon: Icons.collections_bookmark_outlined,
            title: 'Your library is empty',
            message:
                'Open any title in Browse and tap "In Library" to bookmark it.',
          ),
          if (widget.onBrowseSources != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: widget.onBrowseSources,
              icon: const Icon(Icons.explore_rounded, size: 18),
              label: Text(
                'Browse Sources',
                style: AppText.bodySemiBold.copyWith(color: AppColors.onPrimary),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.onPrimary,
                minimumSize: const Size(180, 44),
              ),
            ),
          ],
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _showOnboardingSheet,
            icon: Icon(Icons.help_outline_rounded, size: 18, color: AppColors.primary),
            label: Text(
              'How it works (3-step guide)',
              style: AppText.bodyMedium.copyWith(color: AppColors.primary),
            ),
          ),
        ],
      );
    }
    if (_category == null) {
      return const EmptyState(
        icon: Icons.filter_alt_off_outlined,
        title: 'No uncategorized titles',
        message: 'All titles in your library are organized into categories.',
      );
    }
    return const EmptyState(
      icon: Icons.filter_alt_off_outlined,
      title: 'Nothing in this category',
      message: 'Long-press any manga cover to assign it to this category.',
    );
  }

  void _showOnboardingSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.read,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text('Welcome to Shiori', style: AppText.sheetTitle),
              const SizedBox(height: 6),
              Text(
                'Read manga, manhwa & webtoons seamlessly across all your sources.',
                style: AppText.caption,
              ),
              const SizedBox(height: 18),
              _buildOnboardingStep(
                step: '1',
                title: 'Browse Sources & Extensions',
                description: 'Discover popular titles or search across MangaDex, Asura Scans, WeebCentral, and extensions.',
                icon: Icons.explore_rounded,
              ),
              const SizedBox(height: 12),
              _buildOnboardingStep(
                step: '2',
                title: 'Bookmark & Organize',
                description: 'Add favorites to your Library and sort them into custom categories like Reading or Favorites.',
                icon: Icons.collections_bookmark_rounded,
              ),
              const SizedBox(height: 12),
              _buildOnboardingStep(
                step: '3',
                title: 'Read & Auto-Sync',
                description: 'Enjoy offline downloads, AniList tracking, and cross-device sync powered by cloud backup.',
                icon: Icons.sync_rounded,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    minimumSize: const Size(double.infinity, 48),
                  ),
                  child: Text('Get Started', style: AppText.bodySemiBold.copyWith(color: AppColors.onPrimary)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOnboardingStep({
    required String step,
    required String title,
    required String description,
    required IconData icon,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.outline),
          ),
          child: Center(
            child: Icon(icon, size: 18, color: AppColors.primary),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(description, style: AppText.caption),
            ],
          ),
        ),
      ],
    );
  }

  void _openManga(MangaItem manga) => Navigator.of(context)
      .push(smoothRoute(DetailScreen(manga: manga)))
      .then((_) => _syncLocalLibrary());

  List<(MangaItem, ReadProgress)> _continueReadingItems() {
    final progressMap = ApiService.instance.historyRepo.localProgress;
    if (progressMap.isEmpty) return const [];
    final list = <(MangaItem, ReadProgress)>[];
    for (final m in _userLibrary) {
      final p = progressMap[m.id];
      if (p != null && p.chapterId.isNotEmpty) {
        list.add((m, p));
      }
    }
    list.sort((a, b) {
      final ta = a.$2.updatedAt ?? DateTime(1970);
      final tb = b.$2.updatedAt ?? DateTime(1970);
      return tb.compareTo(ta);
    });
    return list.take(8).toList();
  }

  Widget _buildContinueReadingRail(List<(MangaItem, ReadProgress)> entries) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Row(
            children: [
              Icon(Icons.play_circle_outline_rounded, size: 15, color: AppColors.primary),
              const SizedBox(width: 6),
              Text('CONTINUE READING', style: AppText.sectionHeader),
            ],
          ),
        ),
        SizedBox(
          height: 82,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final (manga, entry) = entries[i];
              final target = ApiService.instance.resolveResumeTarget(
                manga.id,
                skipDuplicateChapters: ReaderSettings.instance.skipDuplicateChapters,
              );
              final statusLabel = (target.chapterId != null && target.chapterId!.isNotEmpty)
                  ? target.label
                  : (entry.chapterNumber.isNotEmpty
                      ? 'Ch. ${entry.chapterNumber}'
                      : 'Continue');
              final fraction = (!entry.completed && entry.totalPages > 0)
                  ? (entry.page / entry.totalPages).clamp(0.0, 1.0)
                  : (entry.completed ? 1.0 : null);
              return Material(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _quickResumeManga(manga),
                  child: Container(
                    width: 214,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.outline),
                    ),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: SizedBox(
                            width: 44,
                            height: 64,
                            child: CoverImage(
                              imageUrl: manga.cover,
                              mangaId: manga.id,
                              memCacheWidth: 96,
                              memCacheHeight: 140,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                manga.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.bodyMedium.copyWith(fontSize: 13),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                statusLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.caption.copyWith(color: AppColors.primary),
                              ),
                              if (fraction != null) ...[
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(2),
                                  child: LinearProgressIndicator(
                                    value: fraction,
                                    minHeight: 3,
                                    color: AppColors.primary,
                                    backgroundColor: AppColors.surfaceHigh,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _grid(DisplaySettings s, List<MangaItem> items) {
    final comfortable = s.mode == DisplayMode.comfortableGrid;
    final showRail = !_isSearching &&
        !_isSelectionMode &&
        _searchQuery.isEmpty &&
        !s.hasActiveFilters &&
        s.showContinueReadingButton;
    final continueItems = showRail ? _continueReadingItems() : const <(MangaItem, ReadProgress)>[];

    if (continueItems.isNotEmpty) {
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _buildContinueReadingRail(continueItems)),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 16),
            sliver: SliverGrid.builder(
              addRepaintBoundaries: true,
              addAutomaticKeepAlives: false,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: s.columns,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: comfortable ? 2 / 3.55 : 2 / 3,
              ),
              itemCount: items.length,
              itemBuilder: (_, i) => _buildGridCoverCard(s, items[i]),
            ),
          ),
        ],
      );
    }

    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      addRepaintBoundaries: true,
      addAutomaticKeepAlives: false,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: s.columns,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: comfortable ? 2 / 3.55 : 2 / 3,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) => _buildGridCoverCard(s, items[i]),
    );
  }

  Widget _buildGridCoverCard(DisplaySettings s, MangaItem manga) {
    final unread = ApiService.instance.getUnreadCount(manga.id);
    final downloaded = s.showDownloadBadges
        ? DownloadService.instance.getDownloadedCountForManga(manga.id)
        : 0;
    final isSelected = _selectedIds.contains(manga.id);
    return RepaintBoundary(
      child: CoverCard(
        title: manga.displayTitle,
        imageUrl: manga.cover,
        mangaId: manga.id,
        mode: s.mode,
        unreadCount: unread,
        downloadedCount: downloaded,
        isSelected: isSelected,
        enableHero: widget.isActive,
        onTap: () {
          if (_isSelectionMode) {
            _toggleSelection(manga.id);
          } else {
            _openManga(manga);
          }
        },
        onLongPress: () {
          HapticFeedback.mediumImpact();
          _showMangaContextMenu(manga);
        },
        onQuickResume: (s.showContinueReadingButton && !_isSelectionMode)
            ? () => _quickResumeManga(manga)
            : null,
      ),
    );
  }

  Widget _list(DisplaySettings s, List<MangaItem> items) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
      addRepaintBoundaries: true,
      addAutomaticKeepAlives: false,
      itemCount: items.length,
      itemBuilder: (_, i) {
        final manga = items[i];
        final unread = ApiService.instance.getUnreadCount(manga.id);
        final downloaded = s.showDownloadBadges
            ? DownloadService.instance.getDownloadedCountForManga(manga.id)
            : 0;
        final isSelected = _selectedIds.contains(manga.id);

        final row = InkWell(
          onTap: () {
            if (_isSelectionMode) {
              _toggleSelection(manga.id);
            } else {
              _openManga(manga);
            }
          },
          onLongPress: () {
            HapticFeedback.mediumImpact();
            _showMangaContextMenu(manga);
          },
          child: Container(
            color: isSelected ? AppColors.primary.withValues(alpha: 0.14) : null,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  height: 58,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      HeroMode(
                        enabled: widget.isActive,
                        child: Hero(
                          tag: 'cover_${manga.id}',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: CoverImage(
                              imageUrl: manga.cover,
                              mangaId: manga.id,
                              saturation: isSelected ? .35 : .85,
                            ),
                          ),
                        ),
                      ),
                      if (isSelected)
                        Container(
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: AppColors.primary, width: 2),
                          ),
                          child: Icon(
                            Icons.check_circle_rounded,
                            color: AppColors.onPrimary,
                            size: 20,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        manga.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodyMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        manga.authors.isNotEmpty
                            ? manga.authors.first
                            : manga.type.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
                if (downloaded > 0)
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      downloaded > 99 ? '99+' : '$downloaded',
                      style: AppText.badge.copyWith(color: Colors.black),
                    ),
                  ),
                if (unread > 0)
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      style: AppText.badge.copyWith(color: AppColors.onPrimary),
                    ),
                  ),
                if (s.showContinueReadingButton && !_isSelectionMode)
                  IconButton(
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                    icon: Icon(
                      Icons.play_arrow_rounded,
                      size: 20,
                      color: AppColors.primary,
                    ),
                    tooltip: 'Quick resume',
                    onPressed: () => _quickResumeManga(manga),
                  ),
                if (!_isSelectionMode)
                  IconButton(
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                    icon: Icon(
                      Icons.label_outline_rounded,
                      size: 18,
                      color: AppColors.muted,
                    ),
                    tooltip: 'Set categories',
                    onPressed: () => _showMangaCategoryDialog(manga),
                  ),
              ],
            ),
          ),
        );

        if (_isSelectionMode) {
          return RepaintBoundary(child: row);
        }

        return RepaintBoundary(
          child: Dismissible(
            key: ValueKey('lib_dismiss_${manga.id}'),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              color: Colors.red.shade900,
              child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
            ),
            onDismissed: (_) => _removeMangaWithUndo(manga),
            child: row,
          ),
        );
      },
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.categories,
    required this.selected,
    required this.counts,
    required this.onSelect,
    required this.onManageCategories,
  });

  final List<(String?, String)> categories;
  final String? selected;
  final Map<String?, int> counts;
  final ValueChanged<String?> onSelect;
  final VoidCallback onManageCategories;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.outline, width: 0.8)),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        itemCount: categories.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (ctx, index) {
          if (index == categories.length) {
            return _ManageCategoryPill(onTap: onManageCategories);
          }
          final (key, label) = categories[index];
          final count = counts[key] ?? 0;
          final isSelected = key == selected;
          return _CategoryPill(
            label: label,
            count: count,
            isSelected: isSelected,
            onTap: () => onSelect(key),
          );
        },
      ),
    );
  }
}

class _CategoryPill extends StatelessWidget {
  const _CategoryPill({
    required this.label,
    required this.count,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected ? AppColors.active : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.6)
              : AppColors.outline,
          width: isSelected ? 1.2 : 1.0,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Center(
            child: Text(
              '$label $count',
              style: AppText.chip.copyWith(
                color: isSelected ? AppColors.primary : AppColors.muted,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ManageCategoryPill extends StatelessWidget {
  const _ManageCategoryPill({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Manage categories',
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppColors.outline, width: 1.0),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, size: 14, color: AppColors.muted),
                const SizedBox(width: 4),
                Text(
                  'Manage',
                  style: AppText.chip.copyWith(
                    color: AppColors.muted,
                    fontWeight: FontWeight.w500,
                    fontSize: 12,
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

class CoverCard extends StatelessWidget {
  const CoverCard({
    super.key,
    required this.title,
    required this.mode,
    this.imageUrl,
    this.mangaId,
    this.unreadCount,
    this.downloadedCount,
    this.isSelected = false,
    this.enableHero = false,
    this.onTap,
    this.onLongPress,
    this.onQuickResume,
  });

  final String title;
  final DisplayMode mode;
  final String? imageUrl;
  final String? mangaId;
  final int? unreadCount;
  final int? downloadedCount;
  final bool isSelected;
  final bool enableHero;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onQuickResume;

  @override
  Widget build(BuildContext context) {
    final coverOnly = mode == DisplayMode.coverOnlyGrid;
    final comfortable = mode == DisplayMode.comfortableGrid;

    final coverImage = CoverImage(imageUrl: imageUrl, mangaId: mangaId);
    final heroCover = (enableHero && mangaId != null && mangaId!.isNotEmpty)
        ? HeroMode(
            enabled: true,
            child: Hero(tag: 'cover_$mangaId', child: coverImage),
          )
        : coverImage;

    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: AppColors.surfaceHigh),
          heroCover,
          if (!comfortable && !coverOnly)
            const Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: .5,
                widthFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Color.fromRGBO(0, 0, 0, .94),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (!comfortable && !coverOnly)
            Positioned(
              left: 7,
              right: onQuickResume != null ? 42 : 7,
              bottom: 7,
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyMedium.copyWith(
                  color: Colors.white,
                  fontSize: 12.5,
                  height: 16 / 12.5,
                ),
              ),
            ),
          if (onQuickResume != null && !isSelected)
            Positioned(
              right: 4,
              bottom: 4,
              child: Tooltip(
                message: 'Quick resume',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onQuickResume,
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: Center(
                        child: Material(
                          color: AppColors.primary.withValues(alpha: 0.94),
                          shape: const CircleBorder(),
                          elevation: 2,
                          child: SizedBox(
                            width: 30,
                            height: 30,
                            child: Icon(
                              Icons.play_arrow_rounded,
                              size: 18,
                              color: AppColors.onPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (downloadedCount != null && downloadedCount! > 0)
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .5),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.download_done_rounded, size: 10, color: Colors.black),
                    const SizedBox(width: 2),
                    Text(
                      downloadedCount! > 99 ? '99+' : '$downloadedCount',
                      style: AppText.badge.copyWith(color: Colors.black),
                    ),
                  ],
                ),
              ),
            ),
          if (unreadCount != null && unreadCount! > 0)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .5),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  unreadCount! > 99 ? '99+' : '$unreadCount',
                  style: AppText.badge.copyWith(color: AppColors.onPrimary),
                ),
              ),
            ),
          if (isSelected)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.28),
                  border: Border.all(color: AppColors.primary, width: 2.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Align(
                  alignment: Alignment.center,
                  child: Icon(Icons.check_circle_rounded, color: AppColors.primary, size: 32),
                ),
              ),
            ),
        ],
      ),
    );

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(6),
      child: comfortable
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: cover),
                const SizedBox(height: 5),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                    color: AppColors.text,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                  ),
                ),
              ],
            )
          : cover,
    );
  }
}
