import 'package:flutter/material.dart';

import '../display_settings.dart';
import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/duplicate_migration_sheet.dart';
import '../widgets/skeleton.dart';
import 'detail_screen.dart';
import 'display_sheet.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, this.isActive = true});

  final bool isActive;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with WidgetsBindingObserver {
  String? _category;
  List<MangaItem> _userLibrary = [];
  bool _loading = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadUserLibrary();
    ApiService.instance.addListener(_onServiceChanged);
  }

  @override
  void didUpdateWidget(covariant LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive && _dirty) {
      _dirty = false;
      _loadUserLibrary(silent: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ApiService.instance.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (!widget.isActive) {
      _dirty = true;
      return;
    }
    if (mounted) {
      setState(() {});
      _loadUserLibrary(silent: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadUserLibrary(silent: true);
    }
  }

  Future<void> _loadUserLibrary({bool silent = false}) async {
    if (!silent && _userLibrary.isEmpty) {
      setState(() => _loading = true);
    }
    try {
      final items = await ApiService.instance.getLibrary();
      if (mounted) {
        setState(() {
          _userLibrary = items;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshLibraryWithUpdates() async {
    await _loadUserLibrary(silent: false);
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
    if (!s.categoryTabs || visibleTabs.isEmpty) {
      return _sortItems([..._userLibrary], s.sort);
    }
    List<MangaItem> items;
    if (_category == '__all__') {
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
    return _sortItems(items, s.sort);
  }

  List<MangaItem> _sortItems(List<MangaItem> items, LibrarySort sort) {
    if (sort == LibrarySort.alphabetical) {
      items.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    } else if (sort == LibrarySort.lastRead) {
      final dateMap = <String, DateTime>{
        for (final m in items)
          m.id: ApiService.instance.historyRepo.localProgress[m.id]?.updatedAt ?? DateTime(1970),
      };
      items.sort((a, b) => (dateMap[b.id]!).compareTo(dateMap[a.id]!));
    } else if (sort == LibrarySort.lastUpdated) {
      final chapterMap = <String, double>{
        for (final m in items)
          m.id: double.tryParse(m.lastChapter ?? '') ?? 0.0,
      };
      items.sort((a, b) => (chapterMap[b.id]!).compareTo(chapterMap[a.id]!));
    } else if (sort == LibrarySort.unreadCount) {
      final unreadMap = <String, int>{
        for (final m in items)
          m.id: ApiService.instance.getUnreadCount(m.id),
      };
      items.sort((a, b) => (unreadMap[b.id]!).compareTo(unreadMap[a.id]!));
    }
    return items;
  }

  Future<void> _removeMangaWithUndo(MangaItem manga) async {
    final originalCategories = ApiService.instance.getMangaCategoryIds(manga.id);
    await ApiService.instance.removeFromLibrary(manga.id);
    if (!mounted) return;
    _loadUserLibrary(silent: true);

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
            if (mounted) _loadUserLibrary(silent: true);
          },
        ),
      ),
    );
  }

  void _showMangaContextMenu(MangaItem manga) {
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
              const Divider(color: AppColors.outline, height: 16),
              ListTile(
                leading: const Icon(Icons.label_outline_rounded, color: AppColors.primary),
                title: const Text('Set Categories', style: TextStyle(color: AppColors.text)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showMangaCategoryDialog(manga);
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
            focusedBorder: const UnderlineInputBorder(
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
          decoration: const InputDecoration(
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

  Map<String, List<MangaItem>> _findDuplicateGroups() {
    final groups = <String, List<MangaItem>>{};
    for (int i = 0; i < _userLibrary.length; i++) {
      for (int j = i + 1; j < _userLibrary.length; j++) {
        if (DuplicateDetector.isPossibleDuplicate(
          _userLibrary[i].title,
          _userLibrary[j].title,
        )) {
          final norm = DuplicateDetector.normalize(_userLibrary[i].title);
          groups.putIfAbsent(norm, () => []).addAll([_userLibrary[i], _userLibrary[j]]);
        }
      }
    }
    final result = <String, List<MangaItem>>{};
    groups.forEach((key, list) {
      final seen = <String>{};
      final unique = list.where((m) => seen.add(m.id)).toList();
      if (unique.length > 1) {
        result[key] = unique;
      }
    });
    return result;
  }

  void _showResolveDuplicatesSheet(Map<String, List<MangaItem>> duplicateGroups) {
    showLibraryDuplicatesSheet(
      context: context,
      duplicateGroups: duplicateGroups,
      onRefresh: () => _loadUserLibrary(silent: true),
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
                      const Divider(color: AppColors.outline, height: 1),
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
                                leading: const Icon(
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
                                  '$count titles',
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
                                      tooltip: 'Rename category',
                                      icon: const Icon(
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
                                      icon: const Icon(
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
                                    manga.title,
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
                      const Divider(color: AppColors.outline, height: 1),
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
                                    _loadUserLibrary(silent: true);
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

        // Categories ONLY appear when they have something in them
        final visibleTabCategories = <(String?, String)>[];
        if (uncategorizedCount > 0) {
          visibleTabCategories.add((null, 'All'));
        }
        for (final c in userCats) {
          if ((categoryCounts[c.id] ?? 0) > 0) {
            visibleTabCategories.add((c.id, c.name));
          }
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
            AppTopBar(
              title: 'Library',
              branded: true,
              actions: [
                if (duplicateGroups.isNotEmpty)
                  BarIcon(
                    Icons.copy_all_rounded,
                    label: 'Resolve duplicates (${duplicateGroups.length})',
                    onTap: () => _showResolveDuplicatesSheet(duplicateGroups),
                  ),
                PopupMenuButton<LibrarySort>(
                  icon: const Icon(Icons.sort_rounded, size: 22, color: AppColors.muted),
                  tooltip: 'Sort library',
                  color: AppColors.surface,
                  initialValue: s.sort,
                  onSelected: (val) => s.update(() => s.sort = val),
                  itemBuilder: (ctx) => [
                    for (final sortOpt in LibrarySort.values)
                      PopupMenuItem(
                        value: sortOpt,
                        child: Row(
                          children: [
                            if (s.sort == sortOpt)
                              const Icon(Icons.check_rounded, size: 16, color: AppColors.primary)
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
                    const Icon(Icons.info_outline_rounded, size: 18, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${duplicateGroups.length} duplicate title${duplicateGroups.length > 1 ? "s" : ""} in library ($duplicateCount entries)',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white,
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
                      child: const Text(
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
                            ? _list(items)
                            : _grid(s, items),
                      ),
              ),
            ),
          ],
        );
      },
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
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _showOnboardingSheet,
            icon: const Icon(Icons.help_outline_rounded, size: 18, color: AppColors.primary),
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
      .then((_) => _loadUserLibrary(silent: true));

  Widget _grid(DisplaySettings s, List<MangaItem> items) {
    final comfortable = s.mode == DisplayMode.comfortableGrid;
    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: s.columns,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: comfortable ? 2 / 3.55 : 2 / 3,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) {
        final manga = items[i];
        final unread = ApiService.instance.getUnreadCount(manga.id);
        return RepaintBoundary(
          child: CoverCard(
            title: manga.title,
            imageUrl: manga.cover,
            mangaId: manga.id,
            mode: s.mode,
            unreadCount: unread,
            onTap: () => _openManga(manga),
            onLongPress: () => _showMangaContextMenu(manga),
          ),
        );
      },
    );
  }

  Widget _list(List<MangaItem> items) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
      itemCount: items.length,
      itemBuilder: (_, i) {
        final manga = items[i];
        final unread = ApiService.instance.getUnreadCount(manga.id);
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
          child: InkWell(
            onTap: () => _openManga(manga),
            onLongPress: () => _showMangaContextMenu(manga),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    height: 58,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: CoverImage(
                        imageUrl: manga.cover,
                        mangaId: manga.id,
                        saturation: .6,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          manga.title,
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
                  if (unread > 0)
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        unread > 99 ? '99+' : '$unread',
                        style: AppText.badge.copyWith(color: AppColors.onPrimary),
                      ),
                    ),
                  IconButton(
                    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                    icon: const Icon(
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
          ),
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
      decoration: const BoxDecoration(
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
          side: const BorderSide(color: AppColors.outline, width: 1.0),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.add_rounded, size: 14, color: AppColors.muted),
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
    this.onTap,
    this.onLongPress,
  });

  final String title;
  final DisplayMode mode;
  final String? imageUrl;
  final String? mangaId;
  final int? unreadCount;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final coverOnly = mode == DisplayMode.coverOnlyGrid;
    final comfortable = mode == DisplayMode.comfortableGrid;

    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: AppColors.surfaceHigh),
          CoverImage(imageUrl: imageUrl, mangaId: mangaId, saturation: .62),
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
              right: 7,
              bottom: 7,
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyMedium.copyWith(
                  fontSize: 12.5,
                  height: 16 / 12.5,
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
