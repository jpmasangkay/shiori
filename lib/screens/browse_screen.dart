import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/extension_service.dart';
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

  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  String _searchQuery = '';
  String _selectedSourceFilter = 'ALL';
  bool _searching = false;
  List<MangaItem> _asuraResults = [];
  List<MangaItem> _mangaDexResults = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _extService.addListener(_onServiceUpdate);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _extService.removeListener(_onServiceUpdate);
    _tabController.dispose();
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
  }

  void _onSearchChanged(String val) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      final q = val.trim();
      setState(() => _searchQuery = q);
      if (q.isNotEmpty) {
        _runGlobalSearch(q);
      }
    });
  }

  Future<void> _runGlobalSearch(String query) async {
    setState(() => _searching = true);
    final hasAsura = _extService.hasAsura;
    final hasMangaDex = _extService.hasMangaDex;

    final shouldSearchAsura = hasAsura && (_selectedSourceFilter == 'ALL' || _selectedSourceFilter == 'asura');
    final shouldSearchMangaDex = hasMangaDex && (_selectedSourceFilter == 'ALL' || _selectedSourceFilter == 'mangadex');

    List<MangaItem> asuraList = [];
    List<MangaItem> mangaDexList = [];

    await Future.wait([
      if (shouldSearchAsura)
        ApiService.instance
            .searchManga(query: query, source: 'asura')
            .then((res) => asuraList = res)
            .catchError((_) => <MangaItem>[]),
      if (shouldSearchMangaDex)
        ApiService.instance
            .searchManga(query: query, source: 'mangadex')
            .then((res) => mangaDexList = res)
            .catchError((_) => <MangaItem>[]),
    ]);

    if (mounted) {
      setState(() {
        _asuraResults = asuraList;
        _mangaDexResults = mangaDexList;
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
    // Detect which active sources are actually installed by user
    final hasMangaDex = _extService.hasMangaDex;
    final hasAsura = _extService.hasAsura;

    // Zero extensions installed state
    if (!hasMangaDex && !hasAsura) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: AppColors.surfaceHigh,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.extension_off_rounded, size: 36, color: AppColors.muted),
              ),
              const SizedBox(height: 20),
              Text(
                'No sources installed',
                style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Shiori comes with zero pre-installed extensions. Go to the Extensions tab to install your preferred sources.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(fontSize: 13, color: AppColors.muted, height: 1.45),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => _tabController.animateTo(1),
                icon: const Icon(Icons.extension_rounded, size: 18),
                label: const Text('Browse Extensions'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.onPrimary,
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final installedExts = _extService.installedExtensions;
    final extraExts = installedExts.where((e) =>
        !e.pkg.toLowerCase().contains('mangadex') &&
        !e.pkg.toLowerCase().contains('asura') &&
        !e.name.toLowerCase().contains('mangadex') &&
        !e.name.toLowerCase().contains('asura')).toList();
    final allInstalledCount = (hasMangaDex ? 1 : 0) + (hasAsura ? 1 : 0) + extraExts.length;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        // Global Multi-Source Search Bar
        Container(
          height: 42,
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
                    hintText: _selectedSourceFilter == 'asura'
                        ? 'Search Asura Scans...'
                        : _selectedSourceFilter == 'mangadex'
                            ? 'Search MangaDex...'
                            : (hasMangaDex && hasAsura)
                                ? 'Search across installed sources...'
                                : hasAsura
                                    ? 'Search Asura Scans...'
                                    : 'Search MangaDex...',
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

        if (allInstalledCount > 1) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildSourceFilterChip('ALL', 'All Sources'),
                if (hasAsura) ...[
                  const SizedBox(width: 6),
                  _buildSourceFilterChip('asura', 'Asura Scans'),
                ],
                if (hasMangaDex) ...[
                  const SizedBox(width: 6),
                  _buildSourceFilterChip('mangadex', 'MangaDex'),
                ],
                for (final ext in extraExts) ...[
                  const SizedBox(width: 6),
                  _buildSourceFilterChip(ext.pkg, ext.name),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
        ] else
          const SizedBox(height: 12),

        // If currently in search mode, display multi-source results
        if (_searchQuery.isNotEmpty) ...[
          _buildSearchResults(),
        ] else ...[
          _sectionHeader('ACTIVE SOURCES ($allInstalledCount)'),

          // MangaDex Source Card (ONLY if installed)
          if (hasMangaDex)
            _buildSourceCard(
              id: 'mangadex',
              name: 'MangaDex',
              lang: 'ALL',
              description: 'Official API • 100,000+ Manga, Manhwa & Manhua in 40+ languages',
              iconLetter: 'M',
              iconColor: const Color(0xFFFF6740),
            ),

          // Asura Scans Source Card (ONLY if installed)
          if (hasAsura)
            _buildSourceCard(
              id: 'asura',
              name: 'Asura Scans',
              lang: 'EN',
              description: 'Direct API • Solo Leveling, Mount Hua, Disaster-Class Hero & action manhwa',
              iconLetter: 'A',
              iconColor: const Color(0xFF6366F1),
            ),

          // All other installed community extensions
          for (final ext in extraExts)
            _buildSourceCard(
              id: ext.pkg,
              name: ext.name,
              lang: ext.lang,
              description: ext.sourceNames.isNotEmpty
                  ? 'Sources: ${ext.sourceNames.join(', ')}'
                  : 'Installed Community Extension (${ext.lang})',
              iconLetter: ext.name.isNotEmpty ? ext.name[0].toUpperCase() : 'E',
              iconColor: const Color(0xFF10B981),
              iconUrl: ext.iconUrl,
            ),

          if (allInstalledCount == 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'No sources active yet. Go to Extensions to install.',
                  style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
                ),
              ),
            ),

          const SizedBox(height: 16),
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
                      Text('Want more sources?', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        'Browse 1,400+ community extensions in the Extensions tab above.',
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
          setState(() => _selectedSourceFilter = filterId);
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
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: MangaGridSkeleton(count: 6),
      );
    }

    final showAsura = (_selectedSourceFilter == 'ALL' || _selectedSourceFilter == 'asura') && _asuraResults.isNotEmpty;
    final showMangaDex = (_selectedSourceFilter == 'ALL' || _selectedSourceFilter == 'mangadex') && _mangaDexResults.isNotEmpty;

    if (!showAsura && !showMangaDex) {
      final filterName = _selectedSourceFilter == 'asura'
          ? ' on Asura Scans'
          : _selectedSourceFilter == 'mangadex'
              ? ' on MangaDex'
              : '';
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search_off_rounded, size: 40, color: AppColors.muted),
              const SizedBox(height: 10),
              Text(
                'No titles found for "$_searchQuery"$filterName',
                style: GoogleFonts.inter(fontSize: 14, color: AppColors.muted),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showAsura) ...[
          _sourceResultSection(
            sourceName: 'Asura Scans',
            badgeColor: const Color(0xFF6366F1),
            items: _asuraResults,
          ),
          const SizedBox(height: 16),
        ],
        if (showMangaDex) ...[
          _sourceResultSection(
            sourceName: 'MangaDex',
            badgeColor: const Color(0xFFFF6740),
            items: _mangaDexResults,
          ),
        ],
      ],
    );
  }

  Widget _sourceResultSection({
    required String sourceName,
    required Color badgeColor,
    required List<MangaItem> items,
  }) {
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
                    MaterialPageRoute(builder: (_) => DetailScreen(manga: manga)),
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

  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: AppColors.muted,
        ),
      ),
    );
  }

  Widget _buildSourceCard({
    required String id,
    required String name,
    required String lang,
    required String description,
    required String iconLetter,
    required Color iconColor,
    String? iconUrl,
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
                        ? CachedNetworkImage(
                            imageUrl: iconUrl,
                            fit: BoxFit.cover,
                            errorWidget: (context, url, error) => Center(
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
                              lang,
                              style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w600, color: AppColors.primary),
                            ),
                          ),
                          const Spacer(),
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
                        MaterialPageRoute(
                          builder: (_) => SourceCatalogScreen(
                            sourceId: id,
                            sourceName: name,
                            sourceLang: lang,
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
                      MaterialPageRoute(
                        builder: (_) => SourceCatalogScreen(
                          sourceId: id,
                          sourceName: name,
                          sourceLang: lang,
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
