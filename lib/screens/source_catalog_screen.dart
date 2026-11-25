import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/extension_bridge.dart';
import '../services/extension_service.dart';
import '../services/local_source_service.dart';
import '../services/platform_bridge.dart';
import '../services/source_resolver.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/extension_sheets.dart';
import '../widgets/skeleton.dart';
import 'detail_screen.dart';

class SourceCatalogScreen extends StatefulWidget {
  const SourceCatalogScreen({
    super.key,
    required this.sourceId,
    required this.sourceName,
    this.sourceLang = 'EN',
    this.initialOrder = 'popular',
    this.initialQuery,
    this.autofocusSearch = false,
  });

  final String sourceId;
  final String sourceName;
  final String sourceLang;
  final String initialOrder;
  final String? initialQuery;
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
  List<Map<String, dynamic>>? _activeExtensionFilters;

  bool get _isLocalSource => widget.sourceId == 'local';
  bool get _isAndroidExtension =>
      !_isLocalSource &&
      !SourceResolver.isBuiltIn(widget.sourceId) &&
      ExtensionBridge.instance.isAndroidSupported;

  static const _types = [
    ('all', 'All'),
    ('manhwa', '🇰🇷 Manhwa'),
    ('manga', '🇯🇵 Manga'),
    ('manhua', '🇨🇳 Manhua'),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery != null && widget.initialQuery!.trim().isNotEmpty) {
      _searchController.text = widget.initialQuery!.trim();
    }
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
    // Keep existing grid visible under top progress bar instead of flashing skeletons mid-word
    setState(() {
      _isTyping = true;
      if (_items.isEmpty) {
        _loading = true;
      } else {
        _refreshing = true;
      }
      _error = null;
    });
    _debounce = Timer(const Duration(milliseconds: 260), () {
      if (!mounted) return;
      _fetch(isRefresh: _items.isNotEmpty);
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
      List<MangaItem> results;
      if (_isAndroidExtension &&
          _activeExtensionFilters != null &&
          _activeExtensionFilters!.isNotEmpty) {
        final rawList = await PlatformBridge.instance.searchExtensionWithFilters(
          pkg: widget.sourceId,
          query: query,
          page: 1,
          filters: _activeExtensionFilters!,
        );
        results = _mapFilteredResults(rawList);
      } else {
        results = await ApiService.instance.searchManga(
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
      List<MangaItem> results;
      if (_isAndroidExtension &&
          _activeExtensionFilters != null &&
          _activeExtensionFilters!.isNotEmpty) {
        final rawList = await PlatformBridge.instance.searchExtensionWithFilters(
          pkg: widget.sourceId,
          query: query,
          page: nextPage,
          filters: _activeExtensionFilters!,
        );
        results = _mapFilteredResults(rawList);
      } else {
        results = await ApiService.instance.searchManga(
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

  List<MangaItem> _mapFilteredResults(List<Map<String, dynamic>> rawList) {
    final pkg = widget.sourceId;
    return rawList.map((m) {
      final rawUrl = m['url']?.toString() ?? '';
      final id = rawUrl.startsWith('ext:')
          ? rawUrl
          : 'ext:$pkg:${Uri.encodeComponent(rawUrl)}';
      return MangaItem(
        id: id,
        title: m['title']?.toString() ?? 'Untitled',
        cover: m['cover']?.toString() ?? m['thumbnail_url']?.toString() ?? '',
        description: m['description']?.toString() ?? '',
        status: m['status']?.toString() ?? '',
        type: 'manga',
        source: pkg,
      );
    }).toList();
  }

  Future<void> _openExtensionFilters() async {
    final result = await showExtensionFiltersSheet(
      context,
      pkg: widget.sourceId,
      name: widget.sourceName,
      initialFilters: _activeExtensionFilters,
    );
    if (result != null && mounted) {
      setState(() => _activeExtensionFilters = result);
      _fetch();
    }
  }

  Future<void> _openExtensionSettings() async {
    final changed = await showExtensionPreferencesSheet(
      context,
      pkg: widget.sourceId,
      name: widget.sourceName,
    );
    if (changed && mounted) {
      _fetch(isRefresh: true);
    }
  }

  Future<void> _importLocalCbz() async {
    final picked = await PlatformBridge.instance.pickFile(
      mimeTypes: const ['application/zip', 'application/x-cbz', 'application/octet-stream', '*/*'],
    );
    if (picked == null || !mounted) return;
    try {
      final manga = await LocalSourceService.instance.importCbzArchive(
        fileName: picked.name,
        bytes: picked.bytes,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported "${manga.title}" into Local Source!')),
      );
      _fetch(isRefresh: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
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
          if (_isLocalSource)
            IconButton(
              icon: const Icon(Icons.file_upload_outlined, size: 22),
              tooltip: 'Import .cbz / .zip',
              onPressed: _importLocalCbz,
            ),
          if (_isAndroidExtension) ...[
            IconButton(
              icon: Icon(
                Icons.filter_list_rounded,
                size: 21,
                color: _activeExtensionFilters != null ? AppColors.primary : null,
              ),
              tooltip: 'Source Filters',
              onPressed: _openExtensionFilters,
            ),
            IconButton(
              icon: const Icon(Icons.tune_rounded, size: 20),
              tooltip: 'Source Settings',
              onPressed: _openExtensionSettings,
            ),
          ],
          if (!_isLocalSource)
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
                  Icon(Icons.search_rounded, size: 20, color: AppColors.muted),
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
                      icon: Icon(Icons.close_rounded, size: 18, color: AppColors.muted),
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

          if (_activeExtensionFilters != null && _activeExtensionFilters!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.filter_list_rounded, size: 16, color: AppColors.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Source filters active',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() => _activeExtensionFilters = null);
                        _fetch();
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        'Clear',
                        style: AppText.chip.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: (_isTyping || _refreshing) ? 2 : 0,
            margin: const EdgeInsets.only(top: 4),
            child: (_isTyping || _refreshing)
                ? LinearProgressIndicator(
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
              Icon(Icons.cloud_off_rounded, size: 44, color: AppColors.muted),
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
              Icon(Icons.search_off_rounded, size: 48, color: AppColors.muted),
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
            final inLibrary = ApiService.instance.isInLibrary(manga.id);
            return InkWell(
              onTap: () {
                Navigator.of(context).push(
                  smoothRoute(DetailScreen(manga: manga)),
                );
              },
              onLongPress: () async {
                HapticFeedback.mediumImpact();
                final wasInLib = ApiService.instance.isInLibrary(manga.id);
                if (wasInLib) {
                  await ApiService.instance.removeFromLibrary(manga.id);
                } else {
                  await ApiService.instance.addToLibrary(manga);
                }
                if (!mounted) return;
                ScaffoldMessenger.of(context).clearSnackBars();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      wasInLib
                          ? 'Removed "${manga.displayTitle}" from library'
                          : 'Added "${manga.displayTitle}" to library',
                    ),
                    duration: const Duration(seconds: 3),
                    action: SnackBarAction(
                      label: 'Undo',
                      textColor: AppColors.primary,
                      onPressed: () {
                        if (wasInLib) {
                          ApiService.instance.addToLibrary(manga);
                        } else {
                          ApiService.instance.removeFromLibrary(manga.id);
                        }
                      },
                    ),
                  ),
                );
              },
              borderRadius: BorderRadius.circular(6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: AppColors.surfaceHigh),
                    CoverImage(
                      imageUrl: manga.cover,
                      mangaId: manga.id,
                      saturation: inLibrary ? .35 : .75,
                    ),
                    if (inLibrary)
                      ColoredBox(
                        color: Colors.black.withValues(alpha: .32),
                      ),
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
                    if (inLibrary)
                      Positioned(
                        top: 5,
                        right: 5,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'IN LIBRARY',
                            style: AppText.badge.copyWith(
                              color: AppColors.onPrimary,
                              fontWeight: FontWeight.w700,
                            ),
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
