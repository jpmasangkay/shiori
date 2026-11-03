import 'dart:async';
import 'package:flutter/material.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/source_resolver.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/skeleton.dart';
import 'detail_screen.dart';
import 'reader_screen.dart';

class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key});

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen>
    with WidgetsBindingObserver {
  Map<String, dynamic> _groups = {};
  bool _loading = false;
  Timer? _realtimeTimer;

  String? _selectedSource;
  String? _selectedCategory;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetch();
    ApiService.instance.addListener(_fetch);
    // Real-time silent background refresh every 45 seconds
    _realtimeTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => _fetch(silent: true),
    );
  }

  @override
  void dispose() {
    _realtimeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    ApiService.instance.removeListener(_fetch);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _fetch(silent: true);
    }
  }

  Future<void> _fetch({bool silent = false}) async {
    if (!silent && _groups.isEmpty) {
      setState(() => _loading = true);
    }
    try {
      final res = await ApiService.instance.getUpdates();
      if (mounted) {
        setState(() {
          _groups = (res['groups'] as Map<String, dynamic>?) ?? {};
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onRefresh() async {
    final newCount = await ApiService.instance.checkForLibraryUpdates();
    await _fetch();
    if (mounted && newCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Checked library: $newCount new chapters found!'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  String _itemSource(Map<String, dynamic> item) {
    final rawSource = item['source']?.toString();
    if (rawSource != null && rawSource.isNotEmpty) {
      return SourceResolver.displayName(rawSource);
    }
    final group = item['group']?.toString();
    if (group != null && group.isNotEmpty && group != 'Update') {
      return SourceResolver.displayName(group);
    }
    final mangaId = item['mangaId']?.toString() ?? '';
    return SourceResolver.displayName(SourceResolver.resolveSource(mangaId));
  }

  Map<String, Set<String>> _buildMangaCategoryMap() {
    final library = ApiService.instance.libraryRepo.localLibrary;
    final map = <String, Set<String>>{};
    for (final manga in library.values) {
      final catIds = ApiService.instance.libraryRepo.getMangaCategoryIds(manga.id);
      final set = <String>{};
      if (catIds.isNotEmpty) set.addAll(catIds);
      if (set.isEmpty) set.add('Default');
      map[manga.id] = set;
    }
    return map;
  }

  Map<String, List<Map<String, dynamic>>> _filteredGroups() {
    final categoryMap = _buildMangaCategoryMap();
    final result = <String, List<Map<String, dynamic>>>{};

    for (final entry in _groups.entries) {
      final list = entry.value as List? ?? const [];
      final filteredList = <Map<String, dynamic>>[];

      for (final raw in list) {
        if (raw is! Map<String, dynamic>) continue;
        final src = _itemSource(raw);
        if (_selectedSource != null && src != _selectedSource) continue;

        if (_selectedCategory != null) {
          final mangaId = raw['mangaId']?.toString() ?? '';
          final cats = categoryMap[mangaId] ?? {'Default'};
          if (!cats.contains(_selectedCategory)) continue;
        }

        filteredList.add(raw);
      }

      if (filteredList.isNotEmpty) {
        result[entry.key] = filteredList;
      }
    }

    return result;
  }

  Set<String> _extractAvailableSources() {
    final sources = <String>{};
    for (final list in _groups.values) {
      if (list is List) {
        for (final raw in list) {
          if (raw is Map<String, dynamic>) {
            sources.add(_itemSource(raw));
          }
        }
      }
    }
    return sources;
  }

  @override
  Widget build(BuildContext context) {
    final hasRawUpdates = _groups.values.any((list) => (list as List).isNotEmpty);
    final filtered = _filteredGroups();
    final hasFilteredUpdates = filtered.values.any((list) => list.isNotEmpty);
    final availableSources = _extractAvailableSources().toList()..sort();
    final userCategories = ApiService.instance.getCategories();

    return Column(
      children: [
        AppTopBar(
          title: 'Updates',
          actions: [
            BarIcon(
              Icons.sync_rounded,
              label: 'Check updates',
              onTap: _onRefresh,
            ),
          ],
        ),
        if (hasRawUpdates && (availableSources.length > 1 || userCategories.length > 1))
          _buildFilterBar(availableSources, userCategories),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.primary,
            backgroundColor: AppColors.surface,
            onRefresh: _onRefresh,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _loading && !hasRawUpdates
                  ? ListView(
                      key: const ValueKey('updates_loading'),
                      padding: const EdgeInsets.only(top: 8, bottom: 16),
                      children: const [
                        _DateHeader('Checking for new chapters...'),
                        UpdateRowSkeleton(),
                        UpdateRowSkeleton(),
                        UpdateRowSkeleton(),
                        UpdateRowSkeleton(),
                        UpdateRowSkeleton(),
                      ],
                    )
                  : ListView(
                      key: const ValueKey('updates_content'),
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        if (hasFilteredUpdates) ...[
                          for (final entry in filtered.entries) ...[
                            _DateHeader(entry.key),
                            for (final item in entry.value)
                              _ApiUpdateRow(
                                item: item,
                                onTap: () {
                                  final mId = item['mangaId']?.toString() ?? '';
                                  final known = ApiService.instance.libraryRepo.knownManga[mId] ??
                                      ApiService.instance.libraryRepo.localLibrary[mId];
                                  Navigator.of(context).push(
                                    smoothRoute(
                                      ReaderScreen(
                                        chapterId: item['id']?.toString() ?? '',
                                        mangaId: mId,
                                        mangaTitle: item['mangaTitle'] ?? 'Untitled',
                                        chapterTitle: item['chapterTitle'],
                                        coverUrl: item['cover'],
                                        chapterNumber: item['chapterNumber']?.toString(),
                                        mangaType: known?.type ?? item['type']?.toString(),
                                        tags: known?.tags,
                                      ),
                                    ),
                                  );
                                },
                                onCoverTap: () {
                                  Navigator.of(context).push(
                                    smoothRoute(
                                      DetailScreen(
                                        manga: MangaItem(
                                          id: item['mangaId'] ?? '',
                                          title: item['mangaTitle'] ?? '',
                                          cover: item['cover'] ?? '',
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ] else if (hasRawUpdates) ...[
                          LayoutBuilder(
                            builder: (_, _) => SizedBox(
                              height: 360,
                              child: EmptyState(
                                icon: Icons.filter_list_off_rounded,
                                title: 'No matching updates',
                                message: 'No chapters match the selected source or category filters.',
                                action: OutlinedButton(
                                  onPressed: () {
                                    setState(() {
                                      _selectedSource = null;
                                      _selectedCategory = null;
                                    });
                                  },
                                  child: const Text('Clear Filters'),
                                ),
                              ),
                            ),
                          ),
                        ] else ...[
                          LayoutBuilder(
                            builder: (_, _) => const SizedBox(
                              height: 400,
                              child: EmptyState(
                                icon: Icons.new_releases_outlined,
                                title: 'No recent updates',
                                message:
                                    'Only new chapters for titles bookmarked in your library will appear here. Pull down to refresh.',
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterBar(List<String> sources, List<CategoryItem> categories) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(bottom: BorderSide(color: AppColors.outline)),
      ),
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Source filter chips
          if (sources.length > 1)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _filterChip(
                    label: 'All Sources',
                    isSelected: _selectedSource == null,
                    onSelected: () => setState(() => _selectedSource = null),
                  ),
                  for (final src in sources) ...[
                    const SizedBox(width: 6),
                    _filterChip(
                      label: src,
                      isSelected: _selectedSource == src,
                      onSelected: () => setState(() => _selectedSource = src),
                    ),
                  ],
                ],
              ),
            ),
          // Category filter chips
          if (categories.length > 1) ...[
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _filterChip(
                    label: 'All Categories',
                    isSelected: _selectedCategory == null,
                    onSelected: () => setState(() => _selectedCategory = null),
                  ),
                  for (final cat in categories) ...[
                    const SizedBox(width: 6),
                    _filterChip(
                      label: cat.name,
                      isSelected: _selectedCategory == cat.name,
                      onSelected: () => setState(() => _selectedCategory = cat.name),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _filterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onSelected,
  }) {
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onSelected(),
      backgroundColor: AppColors.surface,
      selectedColor: AppColors.active,
      labelStyle: TextStyle(
        color: isSelected ? AppColors.primary : AppColors.muted,
        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        fontSize: 11.5,
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: isSelected ? AppColors.primary : AppColors.outline),
      ),
    );
  }
}

class _DateHeader extends StatelessWidget {
  const _DateHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
    child: Text(
      text,
      style: AppText.sectionHeader.copyWith(color: AppColors.primary),
    ),
  );
}

class _ApiUpdateRow extends StatelessWidget {
  const _ApiUpdateRow({
    required this.item,
    required this.onTap,
    required this.onCoverTap,
  });

  final Map<String, dynamic> item;
  final VoidCallback onTap;
  final VoidCallback onCoverTap;

  @override
  Widget build(BuildContext context) {
    final mangaTitle = item['mangaTitle'] ?? 'Untitled';
    final chNum = item['chapterNumber'] != null
        ? 'Chapter ${item['chapterNumber']}'
        : 'New Chapter';
    final group = item['group'] ?? item['source'] ?? 'Update';
    final subtitle = '$chNum · $group';

    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 62),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            GestureDetector(
              onTap: onCoverTap,
              child: SizedBox(
                width: 44,
                height: 56,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CoverImage(
                    imageUrl: item['cover']?.toString(),
                    mangaId: item['mangaId']?.toString(),
                    saturation: .6,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mangaTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
