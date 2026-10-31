import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/extension_service.dart';
import '../services/source_manager.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/skeleton.dart';
import 'detail_screen.dart';
import 'extensions_screen.dart';
import 'source_catalog_screen.dart';

class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key});

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _extService = ExtensionService.instance;
  final _sourceManager = SourceManager.instance;

  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  String _searchQuery = '';
  String _selectedSourceFilter = 'ALL';
  bool _searching = false;
  int _searchToken = 0;
  int _pendingSourcesCount = 0;
  Map<String, List<MangaItem>> _searchResults = {};
  final Map<String, ({Map<String, List<MangaItem>> results, DateTime expiresAt})> _queryCache = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _extService.addListener(_onServiceUpdate);
    _sourceManager.addListener(_onServiceUpdate);

    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('browse_selected_source_filter');
      if (saved != null && mounted) {
        setState(() => _selectedSourceFilter = saved);
      }
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _extService.removeListener(_onServiceUpdate);
    _sourceManager.removeListener(_onServiceUpdate);
    _tabController.dispose();
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
  }

  int _matchingSourcesCount() {
    final directSources = SourceManager.directSources;
    final installedExts = Platform.isIOS
        ? <MangaExtension>[]
        : _extService.installedExtensions.toList();
    int count = 0;
    for (final ds in directSources) {
      if (_selectedSourceFilter == 'ALL' || _selectedSourceFilter == ds.id) count++;
    }
    for (final ext in installedExts) {
      if (_selectedSourceFilter == 'ALL' || _selectedSourceFilter == ext.pkg) count++;
    }
    return count;
  }

  void _onSearchChanged(String val) {
    _searchDebounce?.cancel();
    final q = val.trim();
    if (q.isEmpty) {
      _searchToken++;
      setState(() {
        _searchQuery = '';
        _searching = false;
        _pendingSourcesCount = 0;
        _searchResults = {};
      });
      return;
    }

    final cacheKey = '$_selectedSourceFilter|${q.toLowerCase()}';
    final cached = _queryCache[cacheKey];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      _searchToken++;
      setState(() {
        _searchQuery = q;
        _searching = false;
        _pendingSourcesCount = 0;
        _searchResults = Map<String, List<MangaItem>>.from(cached.results);
      });
      return;
    }

    // Immediately show skeleton rows on the very first keystroke frame
    setState(() {
      _searchQuery = q;
      _searching = true;
      _pendingSourcesCount = _matchingSourcesCount();
      _searchResults = {};
    });

    _searchDebounce = Timer(const Duration(milliseconds: 240), () {
      if (mounted) {
        _runGlobalSearch(q, bypassCache: false);
      }
    });
  }

  Future<void> _runGlobalSearch(String query, {bool bypassCache = false}) async {
    final q = query.trim();
    if (q.isEmpty) return;

    final cacheKey = '$_selectedSourceFilter|${q.toLowerCase()}';
    if (!bypassCache) {
      final cached = _queryCache[cacheKey];
      if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
        _searchToken++;
        if (mounted) {
          setState(() {
            _searchQuery = q;
            _searching = false;
            _pendingSourcesCount = 0;
            _searchResults = Map<String, List<MangaItem>>.from(cached.results);
          });
        }
        return;
      }
    }

    final token = ++_searchToken;
    final directSources = SourceManager.directSources;
    final installedExts = Platform.isIOS
        ? <MangaExtension>[]
        : _extService.installedExtensions.toList();

    final List<String> targetIds = [
      for (final ds in directSources)
        if (_selectedSourceFilter == 'ALL' || _selectedSourceFilter == ds.id) ds.id,
      for (final ext in installedExts)
        if (_selectedSourceFilter == 'ALL' || _selectedSourceFilter == ext.pkg) ext.pkg,
    ];

    if (mounted) {
      setState(() {
        _searchQuery = q;
        _searching = targetIds.isNotEmpty;
        _pendingSourcesCount = targetIds.length;
        _searchResults = {};
      });
    }

    if (targetIds.isEmpty) return;

    final Map<String, List<MangaItem>> accumulated = {};
    int remaining = targetIds.length;

    for (final sourceId in targetIds) {
      ApiService.instance
          .searchManga(query: q, source: sourceId)
          .timeout(const Duration(seconds: 9), onTimeout: () => <MangaItem>[])
          .then((res) {
            if (!mounted || token != _searchToken) return;
            if (res.isNotEmpty) {
              accumulated[sourceId] = res;
              setState(() {
                _searchResults = Map<String, List<MangaItem>>.from(accumulated);
              });
            }
          })
          .catchError((_) {})
          .whenComplete(() {
            if (!mounted || token != _searchToken) return;
            remaining--;
            setState(() {
              _pendingSourcesCount = remaining < 0 ? 0 : remaining;
              if (remaining <= 0) {
                _searching = false;
                if (accumulated.isNotEmpty) {
                  _queryCache[cacheKey] = (
                    results: Map<String, List<MangaItem>>.from(accumulated),
                    expiresAt: DateTime.now().add(const Duration(minutes: 2)),
                  );
                }
              }
            });
          });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) {
      return Column(
        children: [
          const AppTopBar(
            title: 'Browse',
            branded: true,
          ),
          Expanded(
            child: _buildSourcesTab(),
          ),
        ],
      );
    }

    return Column(
      children: [
        AppTopBar(
          title: 'Browse',
          branded: true,
          bottom: TabBar(
            controller: _tabController,
            indicatorColor: AppColors.primary,
            indicatorWeight: 3,
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.muted,
            labelStyle: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.5),
            unselectedLabelStyle: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
            tabs: const [
              Tab(text: 'SOURCES'),
              Tab(text: 'EXTENSIONS'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildSourcesTab(),
              const ExtensionsScreen(isEmbedded: true),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSourcesTab() {
    final directSources = SourceManager.directSources;
    final installedExts = Platform.isIOS
        ? <MangaExtension>[]
        : _extService.installedExtensions.toList();

    // Collect all source IDs that are currently pinned
    final pinnedDirect = directSources.where((s) => _sourceManager.isPinned(s.id)).toList();
    final pinnedExts = installedExts.where((e) => _sourceManager.isPinned(e.pkg)).toList();
    final hasPinned = pinnedDirect.isNotEmpty || pinnedExts.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        // Global Multi-Source Search Bar
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.surfaceHigh),
          ),
          child: Row(
            children: [
              const Icon(Icons.search_rounded, size: 20, color: AppColors.muted),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  style: GoogleFonts.inter(fontSize: 13, color: AppColors.text),
                  decoration: InputDecoration(
                    hintText: () {
                      if (_selectedSourceFilter != 'ALL') {
                        final ds = _sourceManager.getDirectSource(_selectedSourceFilter);
                        if (ds != null) return 'Search ${ds.name}...';
                        final ext = _extService.getExtensionByPkg(_selectedSourceFilter);
                        return 'Search ${ext?.name ?? _selectedSourceFilter}...';
                      }
                      return 'Search across all sources...';
                    }(),
                    hintStyle: const TextStyle(color: AppColors.muted, fontSize: 13),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              if (_searchController.text.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                  child: const Icon(Icons.close_rounded, size: 18, color: AppColors.muted),
                ),
            ],
          ),
        ),

        // Source Filter Chips
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildSourceFilterChip('ALL', 'All Sources'),
              for (final ds in directSources) ...[
                const SizedBox(width: 6),
                _buildSourceFilterChip(ds.id, ds.name),
              ],
              for (final ext in installedExts) ...[
                const SizedBox(width: 6),
                _buildSourceFilterChip(ext.pkg, ext.name),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        // If currently in search mode, display multi-source results
        if (_searchQuery.isNotEmpty) ...[
          _buildSearchResults(),
        ] else ...[
          // SECTION 1: PINNED / FAVORITE SOURCES
          if (hasPinned) ...[
            _sectionHeaderWithBadge(
              title: 'PINNED SOURCES',
              badgeColor: Colors.amber,
              icon: Icons.push_pin_rounded,
            ),
            for (final ds in pinnedDirect)
              _buildSourceCard(
                id: ds.id,
                name: ds.name,
                lang: ds.lang,
                badge: ds.badge,
                description: ds.description,
                iconLetter: ds.iconLetter,
                iconColor: Color(ds.colorValue),
                isPinned: true,
              ),
            for (final ext in pinnedExts)
              _buildSourceCard(
                id: ext.pkg,
                name: ext.name,
                lang: ext.lang,
                badge: ext.lang,
                description: ext.sourceNames.isNotEmpty
                    ? ext.sourceNames.join(', ')
                    : ext.name,
                iconLetter: ext.name.isNotEmpty ? ext.name[0].toUpperCase() : 'E',
                iconColor: const Color(0xFF10B981),
                iconUrl: ext.iconUrl,
                isCommunity: true,
                isPinned: true,
              ),
            const SizedBox(height: 14),
          ],

          // SECTION 2: DIRECT SOURCES (iOS only)
          if (directSources.isNotEmpty) ...[
            _sectionHeaderWithBadge(
              title: 'DIRECT SOURCES',
              badgeText: 'iOS',
              badgeColor: AppColors.primary,
              icon: Icons.bolt_rounded,
            ),
            for (final ds in directSources)
              _buildSourceCard(
                id: ds.id,
                name: ds.name,
                lang: ds.lang,
                badge: ds.badge,
                description: ds.description,
                iconLetter: ds.iconLetter,
                iconColor: Color(ds.colorValue),
                isPinned: _sourceManager.isPinned(ds.id),
              ),
          ],

          if (Platform.isIOS) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.surfaceHigh),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: .15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.apple_rounded, color: AppColors.primary, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Direct Built-in Sources',
                          style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'MangaDex, MangaPill, Asura Scans, Flame Comics, Weeb Central, MangaKatana, MangaRead and more run natively on iOS with offline reading, continuous scroll, and categories.',
                          style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted, height: 1.35),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 14),

            // SECTION 3: COMMUNITY EXTENSIONS
            _sectionHeaderWithBadge(
              title: 'COMMUNITY EXTENSIONS',
              badgeColor: const Color(0xFF10B981),
              icon: Icons.extension_rounded,
            ),

            if (installedExts.isNotEmpty)
              for (final ext in installedExts)
                _buildSourceCard(
                  id: ext.pkg,
                  name: ext.name,
                  lang: ext.lang,
                  badge: ext.lang,
                  description: ext.sourceNames.isNotEmpty
                      ? ext.sourceNames.join(', ')
                      : ext.name,
                  iconLetter: ext.name.isNotEmpty ? ext.name[0].toUpperCase() : 'E',
                  iconColor: const Color(0xFF10B981),
                  iconUrl: ext.iconUrl,
                  isCommunity: true,
                  isPinned: _sourceManager.isPinned(ext.pkg),
                )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No community extensions installed. Explore extensions below.',
                  style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
                ),
              ),

            // Explore More Banner
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.surfaceHigh),
              ),
              child: Row(
                children: [
                  const Icon(Icons.explore_outlined, color: AppColors.primary, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Explore Community Catalog', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                          'Browse 1,400+ online extensions across 40+ languages.',
                          style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _tabController.animateTo(1),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.surfaceHigh,
                      foregroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      minimumSize: const Size(0, 32),
                    ),
                    child: Text('Explore', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ],
    );
  }

  Widget _buildSourceFilterChip(String filterId, String label) {
    final isSelected = _selectedSourceFilter == filterId;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (val) {
        if (val) {
          _searchDebounce?.cancel();
          setState(() => _selectedSourceFilter = filterId);
          SharedPreferences.getInstance().then((p) => p.setString('browse_selected_source_filter', filterId));
          if (_searchQuery.isNotEmpty) {
            _runGlobalSearch(_searchQuery);
          }
        }
      },
      selectedColor: AppColors.primary,
      backgroundColor: AppColors.surface,
      labelStyle: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
        color: isSelected ? AppColors.onPrimary : AppColors.muted,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: isSelected ? AppColors.primary : AppColors.surfaceHigh),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      showCheckmark: false,
    );
  }

  Widget _buildSearchResults() {
    final entriesWithResults = _searchResults.entries.where((e) => e.value.isNotEmpty).toList();
    final stillSearching = _searching || _pendingSourcesCount > 0;

    if (entriesWithResults.isEmpty && stillSearching) {
      final skeletonCount = _selectedSourceFilter == 'ALL' ? 3 : 2;
      return FadeSlideIn(
        key: ValueKey('search_skeleton_${_searchQuery}_$_selectedSourceFilter'),
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _selectedSourceFilter == 'ALL'
                        ? 'Searching across sources...'
                        : 'Searching source...',
                    style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (int i = 0; i < skeletonCount; i++) const MangaRowSkeleton(),
            ],
          ),
        ),
      );
    }

    if (entriesWithResults.isEmpty) {
      final filterLabel = _selectedSourceFilter == 'ALL'
          ? ''
          : ' on ${_sourceManager.getDirectSource(_selectedSourceFilter)?.name ?? _extService.getExtensionByPkg(_selectedSourceFilter)?.name ?? _selectedSourceFilter}';

      return FadeSlideIn(
        key: ValueKey('search_empty_${_searchQuery}_$_selectedSourceFilter'),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.search_off_rounded, size: 40, color: AppColors.muted),
                const SizedBox(height: 10),
                Text(
                  'No titles found for "$_searchQuery"$filterLabel',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(fontSize: 14, color: AppColors.muted),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () => _runGlobalSearch(_searchQuery, bypassCache: true),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Retry Search'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.surfaceHigh,
                    foregroundColor: AppColors.text,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in entriesWithResults) ...[
          FadeSlideIn(
            key: ValueKey('sec_${_searchQuery}_${_selectedSourceFilter}_${entry.key}'),
            child: _buildSourceResultSection(
              sourceId: entry.key,
              items: entry.value,
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (stillSearching) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                ),
                const SizedBox(width: 8),
                Text(
                  'Searching $_pendingSourcesCount more source${_pendingSourcesCount == 1 ? '' : 's'}...',
                  style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          const MangaRowSkeleton(count: 4),
        ],
      ],
    );
  }

  Widget _buildSourceResultSection({
    required String sourceId,
    required List<MangaItem> items,
  }) {
    final ds = _sourceManager.getDirectSource(sourceId);
    final ext = _extService.getExtensionByPkg(sourceId);
    final sourceName = ds?.name ?? ext?.name ?? sourceId;
    final badgeColor = ds != null ? Color(ds.colorValue) : const Color(0xFF10B981);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: badgeColor.withValues(alpha: .2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                sourceName.toUpperCase(),
                style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: badgeColor),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${items.length} titles found',
              style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 180,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final manga = items[i];
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  Navigator.of(context).push(
                    smoothRoute(DetailScreen(manga: manga)),
                  );
                },
                child: SizedBox(
                  width: 105,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CoverImage(imageUrl: manga.cover, saturation: .75),
                              if (manga.lastChapter != null && manga.lastChapter!.isNotEmpty)
                                Positioned(
                                  bottom: 4,
                                  right: 4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: .8),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'Ch. ${manga.lastChapter}',
                                      style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w600, color: Colors.white),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        manga.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _sectionHeaderWithBadge({
    required String title,
    String? badgeText,
    required Color badgeColor,
    required IconData icon,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8, top: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: badgeColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
                color: AppColors.muted,
              ),
            ),
          ),
          if (badgeText != null && badgeText.isNotEmpty) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: badgeColor.withValues(alpha: .15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                badgeText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: badgeColor,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSourceCard({
    required String id,
    required String name,
    required String lang,
    required String badge,
    required String description,
    required String iconLetter,
    required Color iconColor,
    String? iconUrl,
    bool isCommunity = false,
    bool isPinned = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.surfaceHigh),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Source Icon
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: iconColor.withValues(alpha: .4)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: iconUrl != null && iconUrl.isNotEmpty
                        ? RetryingNetworkImage(
                            url: iconUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (context, retry) => Center(
                              child: Text(
                                iconLetter,
                                style: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w700, color: iconColor),
                              ),
                            ),
                          )
                        : Center(
                            child: Text(
                              iconLetter,
                              style: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w700, color: iconColor),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceHigh,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              badge,
                              style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w600, color: AppColors.primary),
                            ),
                          ),
                          const Spacer(),
                          // Pin / Favorite Button
                          IconButton(
                            icon: Icon(
                              isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                              color: isPinned ? Colors.amber : AppColors.muted,
                              size: 18,
                            ),
                            tooltip: isPinned ? 'Unpin source' : 'Pin to top',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => _sourceManager.togglePin(id),
                          ),
                          if (isCommunity) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 18),
                              tooltip: 'Uninstall $name',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () {
                                _extService.uninstallPackage(id);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Uninstalled $name'),
                                    duration: const Duration(seconds: 1),
                                  ),
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted, height: 1.3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        smoothRoute(
                          SourceCatalogScreen(
                            sourceId: id,
                            sourceName: name,
                            sourceLang: lang,
                            initialOrder: 'latest',
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.grid_view_rounded, size: 16),
                    label: const Text('Browse Catalog'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      side: const BorderSide(color: AppColors.surfaceHigh),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      smoothRoute(
                        SourceCatalogScreen(
                          sourceId: id,
                          sourceName: name,
                          sourceLang: lang,
                          initialOrder: 'popular',
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.trending_up_rounded, size: 16),
                  label: const Text('Popular'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimary,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
