import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../display_settings.dart';
import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../theme.dart';
import '../widgets/auth_modal.dart';
import '../widgets/common.dart';
import '../widgets/skeleton.dart';
import 'detail_screen.dart';
import 'display_sheet.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with WidgetsBindingObserver {
  String? _category;
  List<MangaItem> _userLibrary = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadUserLibrary();
    ApiService.instance.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ApiService.instance.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) {
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

  List<MangaItem> _visibleItems(DisplaySettings s) {
    List<MangaItem> items;
    if (_category == null) {
      items = [..._userLibrary];
    } else {
      items = _userLibrary.where((m) {
        final catIds = ApiService.instance.getMangaCategoryIds(m.id);
        return catIds.contains(_category);
      }).toList();
    }
    if (s.sort == LibrarySort.alphabetical) {
      items.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    return items;
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
            hintText: 'e.g. Reading, Favorites, Shonen',
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

  Future<void> _promptRenameCategory(CategoryItem cat, {VoidCallback? onRenamed}) async {
    final textController = TextEditingController(text: cat.name);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Rename Category', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600)),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(
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
                await ApiService.instance.renameCategory(cat.id, name);
                if (ctx.mounted) Navigator.pop(ctx);
                onRenamed?.call();
                if (mounted) setState(() {});
              }
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteCategory(CategoryItem cat, {VoidCallback? onDeleted}) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Delete "${cat.name}"?', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600)),
        content: const Text('Titles in this category will not be deleted from your library.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: AppColors.muted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('Delete'),
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
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                top: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
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
                          'MANAGE CATEGORIES',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1,
                            color: AppColors.muted,
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: () => _promptCreateCategory(
                            onCreated: () {
                              setSheetState(() {});
                              if (mounted) setState(() {});
                            },
                          ),
                          icon: const Icon(Icons.add_rounded, size: 16),
                          label: const Text('Add'),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            minimumSize: const Size(0, 32),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: AppColors.surfaceHigh, height: 1),
                  if (cats.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('No categories yet. Create one!')),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 350),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: cats.length,
                        itemBuilder: (ctx, i) {
                          final cat = cats[i];
                          final count = _userLibrary
                              .where((m) => ApiService.instance.getMangaCategoryIds(m.id).contains(cat.id))
                              .length;
                          return ListTile(
                            leading: const Icon(Icons.folder_outlined, color: AppColors.muted),
                            title: Text(cat.name, style: GoogleFonts.inter(fontSize: 14)),
                            subtitle: Text('$count titles', style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined, size: 18, color: AppColors.muted),
                                  onPressed: () => _promptRenameCategory(
                                    cat,
                                    onRenamed: () {
                                      setSheetState(() {});
                                      if (mounted) setState(() {});
                                    },
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline_rounded, size: 18, color: AppColors.muted),
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
          );
        },
      ),
    );
  }

  void _showMangaCategoryDialog(MangaItem manga) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final cats = ApiService.instance.getCategories();
          final assigned = ApiService.instance.getMangaCategoryIds(manga.id).toSet();

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
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                manga.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 2),
                              Text('Set Categories', style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted)),
                            ],
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => _promptCreateCategory(
                            onCreated: () => setSheetState(() {}),
                          ),
                          icon: const Icon(Icons.add_rounded, size: 16),
                          label: const Text('New'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: AppColors.surfaceHigh, height: 1),
                  if (cats.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('No categories yet. Create one!')),
                    )
                  else
                    ...cats.map((cat) {
                      final isSelected = assigned.contains(cat.id);
                      return CheckboxListTile(
                        value: isSelected,
                        activeColor: AppColors.primary,
                        title: Text(cat.name, style: GoogleFonts.inter(fontSize: 14)),
                        onChanged: (val) async {
                          await ApiService.instance.toggleMangaCategory(manga.id, cat.id);
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: displaySettings,
      builder: (context, _) {
        final s = displaySettings;
        final items = _visibleItems(s);
        final userCats = ApiService.instance.getCategories();

        final tabCategories = <(String?, String)>[
          (null, 'All'),
          ...userCats.map((c) => (c.id as String?, c.name)),
        ];

        return Column(
          children: [
            AppTopBar(
              title: 'Library',
              branded: true,
              actions: [
                BarIcon(
                  Icons.playlist_add_rounded,
                  label: 'Manage categories',
                  onTap: _showCategoryManagementSheet,
                ),
                BarIcon(
                  Icons.filter_list_rounded,
                  label: 'Filter, sort and display',
                  onTap: () => showDisplaySheet(context),
                ),
                BarIcon(Icons.refresh_rounded, label: 'Refresh', onTap: _loadUserLibrary),
              ],
            ),
            _buildCloudSyncBanner(),
            if (s.categoryTabs && _userLibrary.isNotEmpty)
              _Tabs(
                categories: tabCategories,
                selected: _category,
                counts: {
                  null: _userLibrary.length,
                  for (final c in userCats)
                    c.id: _userLibrary
                        .where((m) => ApiService.instance.getMangaCategoryIds(m.id).contains(c.id))
                        .length,
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
                        onRefresh: _loadUserLibrary,
                        child: items.isEmpty
                            ? LayoutBuilder(
                                builder: (_, c) => SingleChildScrollView(
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(minHeight: c.maxHeight),
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

  Widget _buildCloudSyncBanner() {
    final api = ApiService.instance;
    final loggedIn = api.isLoggedIn;
    final user = api.currentUser;

    if (loggedIn) {
      return Container(
        margin: const EdgeInsets.fromLTRB(14, 2, 14, 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF334155), width: .8),
        ),
        child: Row(
          children: [
            const Icon(Icons.cloud_done_rounded, size: 14, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Cloud Sync Active (${user?.email ?? "User"}) · Bookmarks & progress synced automatically',
                style: GoogleFonts.inter(fontSize: 10, color: AppColors.text, fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.surfaceHigh, width: .8),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, size: 16, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Automatic Cloud Sync',
                  style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700),
                ),
                Text(
                  'Bookmarks & history save directly to the database. Access anywhere across devices without manual backups.',
                  style: GoogleFonts.inter(fontSize: 9, color: AppColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          FilledButton(
            onPressed: () => showAuthModal(context),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.onPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: const Size(0, 26),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: Text('Sign In', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    if (_userLibrary.isEmpty) {
      return const EmptyState(
        icon: Icons.collections_bookmark_outlined,
        title: 'Your library is empty',
        message: 'Open any title in Browse and tap "In Library" to bookmark it.',
      );
    }
    return const EmptyState(
      icon: Icons.filter_alt_off_outlined,
      title: 'Nothing in this category',
      message: 'Long-press any manga cover to assign it to this category.',
    );
  }

  void _openManga(MangaItem manga) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => DetailScreen(manga: manga)))
      .then((_) => _loadUserLibrary());

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
        return CoverCard(
          title: manga.title,
          imageUrl: manga.cover,
          mode: s.mode,
          onTap: () => _openManga(manga),
          onLongPress: () => _showMangaCategoryDialog(manga),
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
        return InkWell(
          onTap: () => _openManga(manga),
          onLongPress: () => _showMangaCategoryDialog(manga),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 42,
                  height: 56,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: CoverImage(imageUrl: manga.cover, saturation: .6),
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
                        style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        manga.authors.isNotEmpty ? manga.authors.first : manga.type.toUpperCase(),
                        style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.label_outline_rounded, size: 18, color: AppColors.muted),
                  tooltip: 'Set categories',
                  onPressed: () => _showMangaCategoryDialog(manga),
                ),
              ],
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
      height: 44,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surface)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(left: 4),
              children: [
                for (final (key, label) in categories)
                  InkWell(
                    onTap: () => onSelect(key),
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: Alignment.center,
                      child: Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          Text(
                            '$label ${counts[key] ?? 0}',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: key == selected ? FontWeight.w600 : FontWeight.w400,
                              color: key == selected ? AppColors.primary : AppColors.muted,
                            ),
                          ),
                          if (key == selected)
                            Positioned(
                              left: -2,
                              right: -2,
                              bottom: -14,
                              child: Container(height: 2, color: AppColors.primary),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.playlist_add_rounded, size: 20, color: AppColors.primary),
            tooltip: 'Manage Categories',
            onPressed: onManageCategories,
          ),
        ],
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
    this.onTap,
    this.onLongPress,
  });

  final String title;
  final DisplayMode mode;
  final String? imageUrl;
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
          CoverImage(imageUrl: imageUrl, saturation: .62),
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
                      colors: [Colors.transparent, Color.fromRGBO(5, 6, 9, .94)],
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
                style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500, height: 16 / 12),
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
                  style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500, height: 1.2),
                ),
              ],
            )
          : cover,
    );
  }
}
