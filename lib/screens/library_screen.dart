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

/// Library category tabs, keyed by [MangaItem.type]. `null` means "All".
const _categories = <(String?, String)>[
  (null, 'All'),
  ('manhwa', 'Manhwa'),
  ('manga', 'Manga'),
  ('manhua', 'Manhua'),
];

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
    ApiService.instance.addListener(_loadUserLibrary);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ApiService.instance.removeListener(_loadUserLibrary);
    super.dispose();
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
    final items = _category == null
        ? [..._userLibrary]
        : _userLibrary.where((m) => m.type == _category).toList();
    if (s.sort == LibrarySort.alphabetical) {
      items.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: displaySettings,
      builder: (context, _) {
        final s = displaySettings;
        final items = _visibleItems(s);
        return Column(
          children: [
            AppTopBar(
              title: 'Library',
              branded: true,
              actions: [
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
                selected: _category,
                counts: {
                  for (final (key, _) in _categories)
                    key: key == null
                        ? _userLibrary.length
                        : _userLibrary.where((m) => m.type == key).length,
                },
                onSelect: (c) => setState(() => _category = c),
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
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.surfaceHigh),
        ),
        child: Row(
          children: [
            const Icon(Icons.cloud_done_rounded, size: 14, color: Colors.greenAccent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Cloud Synced with ${user?.displayName.isNotEmpty == true ? user!.displayName : user!.email}',
                style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              'Online',
              style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.primary),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withValues(alpha: .3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_sync_rounded, size: 18, color: AppColors.primary),
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
                      if (manga.lastChapter?.isNotEmpty == true) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Latest: Ch. ${manga.lastChapter}',
                          style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                        ),
                      ],
                    ],
                  ),
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
  const _Tabs({required this.selected, required this.counts, required this.onSelect});
  final String? selected;
  final Map<String?, int> counts;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surface)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(left: 4),
        children: [
          for (final (key, label) in _categories)
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
  });

  final String title;
  final DisplayMode mode;
  final String? imageUrl;
  final VoidCallback? onTap;

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
