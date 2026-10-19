import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data.dart';
import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';
import 'display_sheet.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String _tab = libraryTabs.first;
  List<MangaItem> _userLibrary = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadUserLibrary();
    ApiService.instance.addListener(_loadUserLibrary);
  }

  @override
  void dispose() {
    ApiService.instance.removeListener(_loadUserLibrary);
    super.dispose();
  }

  Future<void> _loadUserLibrary() async {
    if (!ApiService.instance.isLoggedIn) {
      if (mounted) setState(() => _userLibrary = []);
      return;
    }
    setState(() => _loading = true);
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: displaySettings,
      builder: (context, _) {
        final s = displaySettings;
        return Column(
          children: [
            AppTopBar(
              title: 'Library',
              branded: true,
              actions: [
                const BarIcon(Icons.search_rounded, label: 'Search'),
                BarIcon(
                  Icons.filter_list_rounded,
                  label: 'Filter, sort and display',
                  onTap: () => showDisplaySheet(context),
                ),
                const BarIcon(Icons.more_vert_rounded, label: 'More'),
              ],
            ),
            if (s.categoryTabs) _Tabs(selected: _tab, onSelect: (t) => setState(() => _tab = t)),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
                  : s.mode == DisplayMode.list
                      ? _list(s)
                      : _grid(s),
            ),
          ],
        );
      },
    );
  }

  void _openMock(int i) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DetailScreen(cover: i)),
      );

  void _openManga(MangaItem manga) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DetailScreen(manga: manga)),
      );

  Widget _grid(DisplaySettings s) {
    final comfortable = s.mode == DisplayMode.comfortableGrid;
    final hasRealItems = _userLibrary.isNotEmpty;
    final count = hasRealItems ? _userLibrary.length : 12;

    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      onRefresh: _loadUserLibrary,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: s.columns,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: comfortable ? 2 / 3.55 : 2 / 3,
        ),
        itemCount: count,
        itemBuilder: (_, i) {
          if (hasRealItems) {
            final manga = _userLibrary[i];
            return CoverCard(
              index: i,
              title: manga.title,
              imageUrl: manga.cover,
              mode: s.mode,
              onTap: () => _openManga(manga),
            );
          }
          return CoverCard(
            index: i,
            title: titleAt(i),
            mode: s.mode,
            onTap: () => _openMock(i),
          );
        },
      ),
    );
  }

  Widget _list(DisplaySettings s) {
    final hasRealItems = _userLibrary.isNotEmpty;
    final count = hasRealItems ? _userLibrary.length : 12;

    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      onRefresh: _loadUserLibrary,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
        itemCount: count,
        itemBuilder: (_, i) {
          final title = hasRealItems ? _userLibrary[i].title : titleAt(i);
          final coverUrl = hasRealItems ? _userLibrary[i].cover : null;
          final callback = hasRealItems ? () => _openManga(_userLibrary[i]) : () => _openMock(i);

          return InkWell(
            onTap: callback,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 42,
                    height: 56,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: CoverImage(i, imageUrl: coverUrl, saturation: .6),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                  if (s.unreadCount)
                    CoverBadge(left: '${i + 2}', right: '${i % 3 + 1}', showLeft: s.downloaded),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.selected, required this.onSelect});
  final String selected;
  final ValueChanged<String> onSelect;

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
          for (final t in libraryTabs)
            InkWell(
              onTap: () => onSelect(t),
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    Text(
                      t,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: t == selected ? AppColors.primary : AppColors.muted,
                      ),
                    ),
                    if (t == selected)
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
    required this.index,
    required this.mode,
    this.title,
    this.imageUrl,
    this.onTap,
  });

  final int index;
  final DisplayMode mode;
  final String? title;
  final String? imageUrl;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = displaySettings;
    final coverOnly = mode == DisplayMode.coverOnlyGrid;
    final comfortable = mode == DisplayMode.comfortableGrid;
    final displayTitle = title ?? titleAt(index);

    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: AppColors.surfaceHigh),
          CoverImage(index, imageUrl: imageUrl, saturation: .62),
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
          if (s.unreadCount || s.downloaded)
            Positioned(
              top: 5,
              left: 5,
              child: CoverBadge(
                left: '${index + 2}',
                right: '${index % 3 + 1}',
                showLeft: s.downloaded,
                showRight: s.unreadCount,
              ),
            ),
          if (s.localBadge)
            Positioned(
              top: 5,
              right: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('Local', style: GoogleFonts.inter(fontSize: 9)),
              ),
            ),
          if (!comfortable && !coverOnly)
            Positioned(
              left: 7,
              right: 7,
              bottom: 7,
              child: Text(
                displayTitle,
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
                  displayTitle,
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
