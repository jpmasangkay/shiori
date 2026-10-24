import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/extension_bridge.dart';
import '../services/extension_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/skeleton.dart';
import 'detail_screen.dart';

class SourceCatalogScreen extends StatefulWidget {
  const SourceCatalogScreen({
    super.key,
    required this.sourceId,
    required this.sourceName,
    this.sourceLang = 'EN',
  });

  final String sourceId;
  final String sourceName;
  final String sourceLang;

  @override
  State<SourceCatalogScreen> createState() => _SourceCatalogScreenState();
}

class _SourceCatalogScreenState extends State<SourceCatalogScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _debounce;
  String _selectedType = 'all';
  final _selectedOrder = 'popular';
  List<MangaItem> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _page = 1;

  static const _types = [
    ('all', 'All'),
    ('manhwa', '🇰🇷 Manhwa'),
    ('manga', '🇯🇵 Manga'),
    ('manhua', '🇨🇳 Manhua'),
  ];

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _initTypeAndFetch();
  }

  Future<void> _initTypeAndFetch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('catalog_type_${widget.sourceId}') ?? prefs.getString('default_catalog_type');
      if (saved != null && _types.any((t) => t.$1 == saved)) {
        if (mounted) _selectedType = saved;
      }
    } catch (_) {}
    if (mounted) _fetch();
  }

  void _changeType(String typeKey) {
    setState(() {
      _selectedType = typeKey;
      _page = 1;
    });
    SharedPreferences.getInstance().then((p) {
      p.setString('catalog_type_${widget.sourceId}', typeKey);
      p.setString('default_catalog_type', typeKey);
    });
    _fetch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 350) {
      if (!_loading && !_loadingMore && _hasMore) {
        _loadMore();
      }
    }
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _fetch();
    });
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
      _page = 1;
      _hasMore = true;
    });

    try {
      final query = _searchController.text.trim();
      var results = await ApiService.instance.searchManga(
        query: query,
        type: query.isNotEmpty ? null : (_selectedType == 'all' ? null : _selectedType),
        order: _selectedOrder,
        page: 1,
        limit: 24,
        source: widget.sourceId,
      );

      // If user searched for a keyword but the type filter caused 0 results,
      // fallback to searching all types so titles are never hidden or limited
      if (results.isEmpty && query.isNotEmpty && _selectedType != 'all') {
        final allResults = await ApiService.instance.searchManga(
          query: query,
          type: null,
          order: _selectedOrder,
          page: 1,
          limit: 24,
          source: widget.sourceId,
        );
        if (allResults.isNotEmpty) {
          results = allResults;
        }
      }

      if (mounted) {
        setState(() {
          _items = results;
          _loading = false;
          _hasMore = results.length >= 8;
        });
      }
    } catch (err) {
      if (mounted) {
        setState(() {
          _error = err.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    final nextPage = _page + 1;

    try {
      final query = _searchController.text.trim();
      final results = await ApiService.instance.searchManga(
        query: query,
        type: query.isNotEmpty ? null : (_selectedType == 'all' ? null : _selectedType),
        order: _selectedOrder,
        page: nextPage,
        limit: 24,
        source: widget.sourceId,
      );
      if (mounted) {
        setState(() {
          _page = nextPage;
          final existingIds = _items.map((e) => e.id).toSet();
          final newItems = results.where((e) => !existingIds.contains(e.id)).toList();
          _items.addAll(newItems);
          _loadingMore = false;
          _hasMore = results.isNotEmpty && results.length >= 8;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.sourceName,
              style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Text(
              '${widget.sourceLang} • Catalog',
              style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.public_rounded, size: 20),
            tooltip: 'Open in WebView',
            onPressed: () async {
              final baseUrl = await ExtensionBridge.instance.getSourceBaseUrl(pkg: widget.sourceId);
              final ext = ExtensionService.instance.getExtensionByPkg(widget.sourceId);
              final url = (baseUrl != null && baseUrl.isNotEmpty)
                  ? baseUrl
                  : (ext != null && ext.homeUrl.isNotEmpty ? ext.homeUrl : null);
              if (url != null && url.isNotEmpty) {
                await ExtensionBridge.instance.openInWebView(url: url, title: widget.sourceName);
                if (mounted) _fetch();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Search box
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
            child: Container(
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
                        hintText: 'Search ${widget.sourceName}...',
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
                        _fetch();
                      },
                      child: const Icon(Icons.close_rounded, size: 18, color: AppColors.muted),
                    ),
                ],
              ),
            ),
          ),

          // Types
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final (typeKey, typeLabel) in _types)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(typeLabel),
                      selected: _selectedType == typeKey,
                      onSelected: (sel) {
                        if (sel) _changeType(typeKey);
                      },
                      backgroundColor: AppColors.surface,
                      selectedColor: AppColors.active,
                      labelStyle: GoogleFonts.inter(
                        fontSize: 12,
                        color: _selectedType == typeKey ? AppColors.primary : AppColors.muted,
                        fontWeight: _selectedType == typeKey ? FontWeight.w600 : FontWeight.normal,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: BorderSide(
                          color: _selectedType == typeKey ? AppColors.primary : Colors.transparent,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 6),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _buildGrid(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    if (_loading && _items.isEmpty) {
      return const MangaGridSkeleton(key: ValueKey('catalog_skeleton'), count: 9);
    }

    if (_error != null && _items.isEmpty) {
      final errLower = _error!.toLowerCase();
      final isCloudflareOrWeb = errLower.contains('403') ||
          errLower.contains('503') ||
          errLower.contains('522') ||
          errLower.contains('cloudflare') ||
          errLower.contains('cookie') ||
          errLower.contains('webview') ||
          errLower.contains('challenge') ||
          errLower.contains('turnstile') ||
          errLower.contains('captcha');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 44, color: AppColors.muted),
              const SizedBox(height: 12),
              Text(
                'Could not load ${widget.sourceName} catalog',
                style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
              ),
              const SizedBox(height: 16),
              if (isCloudflareOrWeb) ...[
                FilledButton.icon(
                  onPressed: () async {
                    final baseUrl = await ExtensionBridge.instance.getSourceBaseUrl(pkg: widget.sourceId);
                    final ext = ExtensionService.instance.getExtensionByPkg(widget.sourceId);
                    final url = (baseUrl != null && baseUrl.isNotEmpty)
                        ? baseUrl
                        : (ext != null && ext.homeUrl.isNotEmpty ? ext.homeUrl : null);
                    if (url != null && url.isNotEmpty) {
                      await ExtensionBridge.instance.openInWebView(url: url, title: widget.sourceName);
                      if (mounted) _fetch();
                    }
                  },
                  icon: const Icon(Icons.shield_rounded, size: 18),
                  label: Text(errLower.contains('cloudflare') || errLower.contains('403')
                      ? 'Solve Cloudflare in WebView'
                      : 'Open in WebView'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimary,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              FilledButton.icon(
                onPressed: _fetch,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try Again'),
                style: FilledButton.styleFrom(backgroundColor: AppColors.surfaceHigh),
              ),
            ],
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      final typeLabel = _types.firstWhere((t) => t.$1 == _selectedType, orElse: () => ('all', 'titles')).$2;
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search_off_rounded, size: 48, color: AppColors.muted),
              const SizedBox(height: 12),
              Text(
                'No $typeLabel found on ${widget.sourceName}',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.text),
              ),
              const SizedBox(height: 6),
              Text(
                _selectedType != 'all'
                    ? '${widget.sourceName} may not carry $typeLabel or specializes in other comic categories. Try selecting "All" or a different category.'
                    : 'This source returned no results for this query. Try another search or pull to refresh.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted, height: 1.4),
              ),
              const SizedBox(height: 18),
              if (_selectedType != 'all')
                FilledButton.icon(
                  onPressed: () => _changeType('all'),
                  icon: const Icon(Icons.filter_alt_off_rounded, size: 16),
                  label: const Text('Show All Titles'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimary,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                )
              else
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back_rounded, size: 16),
                  label: const Text('Back to Sources'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimary,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final cols = (width / 115).clamp(2, 6).floor();

    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      onRefresh: _fetch,
      child: GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 20),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 2 / 3,
        ),
        itemCount: _items.length + (_loadingMore ? 1 : 0),
        itemBuilder: (_, i) {
          if (i >= _items.length) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                ),
              ),
            );
          }
          final manga = _items[i];
          return InkWell(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => DetailScreen(manga: manga)),
              );
            },
            borderRadius: BorderRadius.circular(6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: AppColors.surfaceHigh),
                  CoverImage(imageUrl: manga.cover, saturation: .75),
                  const Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: .55,
                      widthFactor: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Color.fromRGBO(5, 6, 9, .95)],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 5,
                    left: 5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceHigh.withValues(alpha: .9),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        manga.type.toUpperCase(),
                        style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.primary),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 7,
                    right: 7,
                    bottom: 7,
                    child: Text(
                      manga.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        height: 16 / 12,
                      ),
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
}
