import 'package:flutter/material.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/source_resolver.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/skeleton.dart';
import 'detail_screen.dart';
import 'reader_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.isActive = true});

  final bool isActive;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<ReadHistoryEntry> _history = [];
  bool _loading = true;
  bool _dirty = false;
  String _searchQuery = '';
  String? _selectedSource;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetch();
    ApiService.instance.addListener(_onServiceChanged);
  }

  @override
  void didUpdateWidget(covariant HistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive && _dirty) {
      _dirty = false;
      _fetch(silent: true);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    ApiService.instance.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (!widget.isActive) {
      _dirty = true;
      return;
    }
    _fetch(silent: true);
  }

  Future<void> _fetch({bool silent = false}) async {
    if (!silent && _history.isEmpty) {
      setState(() => _loading = true);
    }
    try {
      await ApiService.instance.getHistory();
      if (mounted) {
        setState(() {
          _history = ApiService.instance.getHistoryEntries();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<ReadHistoryEntry> get _filteredHistory {
    return _history.where((item) {
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        if (!item.mangaTitle.toLowerCase().contains(q) &&
            !item.chapterTitle.toLowerCase().contains(q)) {
          return false;
        }
      }
      if (_selectedSource != null && _selectedSource!.isNotEmpty) {
        if (item.source.toLowerCase() != _selectedSource!.toLowerCase()) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  Set<String> get _availableSources {
    return _history.map((e) => e.source).where((s) => s.isNotEmpty).toSet();
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Clear History', style: AppText.sheetTitle),
        content: Text(
          'Are you sure you want to clear your entire reading history? This cannot be undone.',
          style: AppText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: AppText.bodyMedium.copyWith(color: AppColors.muted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: Text('Clear All', style: AppText.bodySemiBold.copyWith(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ApiService.instance.clearHistory();
      if (mounted) {
        setState(() {
          _history = [];
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Reading history cleared'),
            backgroundColor: AppColors.surfaceHigh,
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _removeEntry(ReadHistoryEntry entry) async {
    final idx = _history.indexOf(entry);
    setState(() {
      _history.remove(entry);
    });
    await ApiService.instance.removeHistoryEntry(entry.chapterId);

    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Removed "${entry.mangaTitle}" from history'),
        backgroundColor: AppColors.surfaceHigh,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Undo',
          textColor: AppColors.primary,
          onPressed: () async {
            await ApiService.instance.saveProgress(
              mangaId: entry.mangaId,
              chapterId: entry.chapterId,
              mangaTitle: entry.mangaTitle,
              cover: entry.cover,
              source: entry.source,
              chapterNumber: entry.chapterNumber,
              chapterTitle: entry.chapterTitle,
              page: entry.page,
              totalPages: entry.totalPages,
              completed: entry.completed,
            );
            if (mounted) {
              setState(() {
                if (idx >= 0 && idx <= _history.length) {
                  _history.insert(idx, entry);
                } else {
                  _history.add(entry);
                }
              });
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredHistory;
    final sources = _availableSources;

    return Column(
      children: [
        AppTopBar(
          title: 'History',
          branded: true,
          actions: [
            if (_history.isNotEmpty)
              BarIcon(
                Icons.delete_sweep_outlined,
                label: 'Clear history',
                onTap: _confirmClearAll,
              ),
          ],
        ),

        // Search Bar & Filter Chips (#17)
        if (_history.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
            child: SizedBox(
              height: 42,
              child: TextField(
                controller: _searchController,
                style: AppText.body,
                decoration: InputDecoration(
                  hintText: 'Search history by title...',
                  hintStyle: AppText.caption,
                  prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppColors.muted),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 16, color: AppColors.muted),
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
          if (sources.length > 1)
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text('All', style: AppText.chip),
                      selected: _selectedSource == null,
                      onSelected: (_) => setState(() => _selectedSource = null),
                      backgroundColor: AppColors.surface,
                      selectedColor: AppColors.primary.withValues(alpha: .2),
                      side: BorderSide(
                        color: _selectedSource == null ? AppColors.primary : AppColors.outline,
                      ),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  for (final src in sources)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: Text(SourceResolver.displayName(src), style: AppText.chip),
                        selected: _selectedSource?.toLowerCase() == src.toLowerCase(),
                        onSelected: (sel) =>
                            setState(() => _selectedSource = sel ? src : null),
                        backgroundColor: AppColors.surface,
                        selectedColor: AppColors.primary.withValues(alpha: .2),
                        side: BorderSide(
                          color: _selectedSource?.toLowerCase() == src.toLowerCase()
                              ? AppColors.primary
                              : AppColors.outline,
                        ),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 6),
        ],

        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: _loading && _history.isEmpty
                ? ListView.builder(
                    key: const ValueKey('history_skeleton'),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: 8,
                    itemBuilder: (_, _) => const HistoryRowSkeleton(),
                  )
                : _history.isEmpty
                    ? _buildEmptyState()
                    : filtered.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                'No matching history entries',
                                style: TextStyle(color: AppColors.muted),
                              ),
                            ),
                          )
                        : FadeSlideIn(
                            key: const ValueKey('history_content'),
                            child: RefreshIndicator(
                              color: AppColors.primary,
                              backgroundColor: AppColors.surface,
                              onRefresh: () => _fetch(silent: true),
                              child: ListView.builder(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                itemCount: filtered.length,
                                itemBuilder: (_, i) => _buildHistoryRow(filtered[i]),
                              ),
                            ),
                          ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    final loggedIn = ApiService.instance.isLoggedIn;
    return EmptyState(
      icon: Icons.history_toggle_off_rounded,
      title: loggedIn ? 'No reading history yet' : 'No reading history',
      message: loggedIn
          ? 'Chapters you read will appear here so you can pick up where you left off.'
          : 'Sign in from the More tab to keep your reading history across devices.',
    );
  }

  Widget _buildHistoryRow(ReadHistoryEntry item) {
    final mangaId = item.mangaId;
    final title = item.mangaTitle.isNotEmpty ? item.mangaTitle : 'Untitled';
    final cover = item.cover;
    final chNum = item.chapterNumber;
    final page = item.page;
    final total = item.totalPages;
    final subtitle = 'Chapter $chNum · Page $page${total > 0 ? ' / $total' : ''}';

    return Dismissible(
      key: ValueKey('hist_dismiss_${item.chapterId}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Colors.red.shade900,
        child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
      ),
      onDismissed: (_) => _removeEntry(item),
      child: InkWell(
        onTap: () {
          final known = ApiService.instance.libraryRepo.knownManga[mangaId] ??
              ApiService.instance.libraryRepo.localLibrary[mangaId];
          Navigator.of(context).push(
            smoothRoute(
              ReaderScreen(
                chapterId: item.chapterId,
                mangaId: mangaId,
                mangaTitle: title,
                coverUrl: cover,
                chapterNumber: chNum,
                mangaType: known?.type,
                tags: known?.tags,
              ),
            ),
          ).then((_) => _fetch(silent: true));
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 66),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              GestureDetector(
                onTap: mangaId.isEmpty
                    ? null
                    : () {
                        Navigator.of(context)
                            .push(
                              smoothRoute(
                                DetailScreen(
                                  manga: MangaItem(
                                    id: mangaId,
                                    title: title,
                                    cover: cover,
                                    source: item.source,
                                  ),
                                ),
                              ),
                            )
                            .then((_) => _fetch(silent: true));
                      },
                child: SizedBox(
                  width: 44,
                  height: 56,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: CoverImage(imageUrl: cover, mangaId: mangaId, saturation: .7),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyMedium,
                    ),
                    const SizedBox(height: 4),
                    Text.rich(
                      TextSpan(
                        text: subtitle,
                        style: AppText.caption.copyWith(color: AppColors.primary),
                        children: [
                          if (item.source.isNotEmpty)
                            TextSpan(
                              text: ' · ${SourceResolver.displayName(item.source)}',
                              style: AppText.caption.copyWith(color: AppColors.muted),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 16, color: AppColors.muted),
                tooltip: 'Remove from history',
                onPressed: () => _removeEntry(item),
              ),
              const SizedBox(
                width: 36,
                height: 44,
                child: Center(
                  child: Icon(Icons.play_circle_outline_rounded, color: AppColors.primary, size: 26),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
