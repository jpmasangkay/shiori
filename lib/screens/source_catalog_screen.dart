import 'dart:async';
import 'package:flutter/material.dart';
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
    this.initialOrder = 'popular',
    this.autofocusSearch = false,
  });

  final String sourceId;
  final String sourceName;
  final String sourceLang;
  final String initialOrder;
  final bool autofocusSearch;

  @override
  State<SourceCatalogScreen> createState() => _SourceCatalogScreenState();
}

class _SourceCatalogScreenState extends State<SourceCatalogScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _debounce;
  String _selectedType = 'all';
  late String _selectedOrder = widget.initialOrder;
  List<MangaItem> _items = [];
  bool _loading = true;
  bool _refreshing = false;
  bool _isTyping = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _page = 1;
  int _fetchToken = 0;
  int _contentGeneration = 0;

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
    ApiService.instance.addListener(_onLibraryChanged);
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
    if (_selectedType == typeKey && !_loading) return;
    _debounce?.cancel();
    setState(() {
      _selectedType = typeKey;
      _isTyping = false;
      _page = 1;
    });
    SharedPreferences.getInstance().then((p) {
      p.setString('catalog_type_${widget.sourceId}', typeKey);
      p.setString('default_catalog_type', typeKey);
    });
    _fetch();
  }

  void _changeOrder(String order) {
    if (_selectedOrder == order && !_loading) return;
    _debounce?.cancel();
    setState(() {
      _selectedOrder = order;
      _isTyping = false;
      _page = 1;
    });
    _fetch();
  }

  @override
  void dispose() {
    ApiService.instance.removeListener(_onLibraryChanged);
    _debounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onLibraryChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 350) {
      if (!_loading && !_isTyping && !_loadingMore && _hasMore) {
        _loadMore();
      }
    }
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    // Show skeleton immediately so typing feels instant and never freezes on stale results
    setState(() {
      _isTyping = true;
      _loading = true;
      _error = null;
    });
    _debounce = Timer(const Duration(milliseconds: 140), () {
      if (!mounted) return;
      _fetch();
    });
  }

  Future<void> _fetch({bool isRefresh = false}) async {
    final token = ++_fetchToken;
    setState(() {
      _isTyping = false;
      if (isRefresh && _items.isNotEmpty) {
        _refreshing = true;
      } else {
        _loading = true;
      }
      _loadingMore = false;
      _error = null;
      _page = 1;
      _hasMore = true;
    });

    try {
      final query = _searchController.text.trim();
      var results = await ApiService.instance.searchManga(
        query: query,
        type: _selectedType == 'all' ? null : _selectedType,
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

      if (!mounted || token != _fetchToken) return;
      if (!isRefresh && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
      setState(() {
        _items = results;
        _loading = false;
        _refreshing = false;
        _contentGeneration++;
        _hasMore = results.length >= 8;
      });
    } catch (err) {
      if (!mounted || token != _fetchToken) return;
      setState(() {
        _error = err.toString().replaceFirst('Exception: ', '');
        _loading = false;
        _refreshing = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    final token = _fetchToken;
    setState(() => _loadingMore = true);
    final nextPage = _page + 1;

    try {
      final query = _searchController.text.trim();
      var results = await ApiService.instance.searchManga(
        query: query,
        type: _selectedType == 'all' ? null : _selectedType,
        order: _selectedOrder,
        page: nextPage,
        limit: 24,
        source: widget.sourceId,
      );
      if (results.isEmpty && query.isNotEmpty && _selectedType != 'all') {
        final allResults = await ApiService.instance.searchManga(
          query: query,
          type: null,
          order: _selectedOrder,
          page: nextPage,
          limit: 24,
          source: widget.sourceId,
        );
        if (allResults.isNotEmpty) {
          results = allResults;
        }
      }
      if (mounted && token == _fetchToken) {
        setState(() {
          _page = nextPage;
          final existingIds = _items.map((e) => e.id).toSet();
          final newItems = results.where((e) => !existingIds.contains(e.id)).toList();
          _items.addAll(newItems);
          _loadingMore = false;
          _hasMore = newItems.isNotEmpty && results.length >= 8;
        });
      }
    } catch (_) {
      if (mounted && token == _fetchToken) {
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
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.title,
            ),
            Text(
              '${widget.sourceLang} • Catalog',
              style: AppText.caption.copyWith(color: AppColors.muted),
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
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.outline),
              ),
              child: Row(
                children: [
                  const Icon(Icons.search_rounded, size: 20, color: AppColors.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      autofocus: widget.autofocusSearch,
                      onChanged: _onSearchChanged,
                      style: AppText.body,
                      decoration: InputDecoration(
                        hintText: 'Search ${widget.sourceName}...',
                        hintStyle: AppText.body.copyWith(color: AppColors.muted),
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  if (_searchController.text.isNotEmpty)
                    IconButton(
                      onPressed: () {
                        _debounce?.cancel();
                        _searchController.clear();
                        _fetch();
                      },
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.muted),
                    ),
                ],
              ),
            ),
          ),

          // Sort + Types
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final (orderKey, orderLabel, orderIcon) in const [
                  ('popular', 'Popular', Icons.local_fire_department_rounded),
                  ('latest', 'Latest', Icons.schedule_rounded),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6, bottom: 2),
                    child: ChoiceChip(
                      avatar: Icon(
                        orderIcon,
                        size: 14,
                        color: _selectedOrder == orderKey ? AppColors.primary : AppColors.muted,
                      ),
                      label: Text(orderLabel),
                      selected: _selectedOrder == orderKey,
                      onSelected: (sel) {
                        if (sel) _changeOrder(orderKey);
                      },
                      showCheckmark: false,
                      backgroundColor: AppColors.surface,
                      selectedColor: AppColors.active,
                      labelStyle: AppText.chip.copyWith(
                        color: _selectedOrder == orderKey ? AppColors.primary : AppColors.muted,
                        fontWeight: _selectedOrder == orderKey ? FontWeight.w600 : FontWeight.w500,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: BorderSide(
                          color: _selectedOrder == orderKey ? AppColors.primary : AppColors.outline,
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  child: Container(width: 1, height: 22, color: AppColors.outline),
                ),
                for (final (typeKey, typeLabel) in _types)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, bottom: 2),
                    child: ChoiceChip(
                      label: Text(typeLabel),
                      selected: _selectedType == typeKey,
                      onSelected: (sel) {
                        if (sel) _changeType(typeKey);
                      },
                      showCheckmark: false,
                      backgroundColor: AppColors.surface,
                      selectedColor: AppColors.active,
                      labelStyle: AppText.chip.copyWith(
                        color: _selectedType == typeKey ? AppColors.primary : AppColors.muted,
                        fontWeight: _selectedType == typeKey ? FontWeight.w600 : FontWeight.w500,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: BorderSide(
                          color: _selectedType == typeKey ? AppColors.primary : AppColors.outline,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: (_isTyping || _refreshing) ? 2 : 0,
            margin: const EdgeInsets.only(top: 4),
            child: (_isTyping || _refreshing)
                ? const LinearProgressIndicator(
                    minHeight: 2,
                    color: AppColors.primary,
                    backgroundColor: Colors.transparent,
                  )
                : const SizedBox.shrink(),
          ),

          const SizedBox(height: 4),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: _buildGrid(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    if (_loading && !_refreshing) {
      return const CatalogGridSkeleton(key: ValueKey('catalog_skeleton'), count: 12);
    }

    if (_error != null && (_items.isEmpty || !_refreshing)) {
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
        key: const ValueKey('catalog_error'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 44, color: AppColors.muted),
              const SizedBox(height: 12),
              Text(
                'Could not load ${widget.sourceName} catalog',
                style: AppText.cardTitle,
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: AppColors.muted),
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
                    minimumSize: const Size(0, 44),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              FilledButton.icon(
                onPressed: _fetch,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try Again'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.surfaceHigh,
                  minimumSize: const Size(0, 44),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      final typeLabel = _types.firstWhere((t) => t.$1 == _selectedType, orElse: () => ('all', 'titles')).$2;
      return Center(
        key: const ValueKey('catalog_empty'),
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
                style: AppText.cardTitle,
              ),
              const SizedBox(height: 6),
              Text(
                _selectedType != 'all'
                    ? '${widget.sourceName} may not carry $typeLabel or specializes in other comic categories. Try selecting "All" or a different category.'
                    : 'This source returned no results for this query. Try another search or pull to refresh.',
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: AppColors.muted, height: 1.4),
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
                    minimumSize: const Size(0, 44),
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
                    minimumSize: const Size(0, 44),
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

    return FadeSlideIn(
      key: ValueKey('grid_$_contentGeneration'),
      child: RefreshIndicator(
        color: AppColors.primary,
        backgroundColor: AppColors.surface,
        onRefresh: () => _fetch(isRefresh: true),
        child: GridView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 20),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 2 / 3,
          ),
          itemCount: _items.length + (_loadingMore ? cols : 0),
          itemBuilder: (_, i) {
            if (i >= _items.length) {
              return const MangaCardSkeleton();
            }
            final manga = _items[i];
            return InkWell(
              onTap: () {
                Navigator.of(context).push(
                  smoothRoute(DetailScreen(manga: manga)),
                );
              },
              borderRadius: BorderRadius.circular(6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: AppColors.surfaceHigh),
                    CoverImage(imageUrl: manga.cover, mangaId: manga.id, saturation: .75),
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
                          style: AppText.badge.copyWith(color: AppColors.primary),
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
                        style: AppText.bodyMedium.copyWith(height: 16 / 13),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
