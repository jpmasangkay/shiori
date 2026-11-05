import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/extension_service.dart';
import '../services/source_manager.dart';
import '../services/source_resolver.dart';
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

  static const Map<String, String> _langNames = {
    'EN': 'ENGLISH',
    'ALL': 'MULTI-LANGUAGE',
    'JA': 'JAPANESE',
    'KO': 'KOREAN',
    'ZH': 'CHINESE',
    'ES': 'SPANISH',
    'FR': 'FRENCH',
    'ID': 'INDONESIAN',
    'PT': 'PORTUGUESE',
    'PT-BR': 'PORTUGUESE (BR)',
    'RU': 'RUSSIAN',
    'DE': 'GERMAN',
    'IT': 'ITALIAN',
    'AR': 'ARABIC',
    'TR': 'TURKISH',
    'VI': 'VIETNAMESE',
    'TH': 'THAI',
    'PL': 'POLISH',
  };

  String _languageGroupTitle(String langCode) {
    final upper = langCode.toUpperCase();
    final name = _langNames[upper];
    return name != null ? '$name ($upper)' : upper;
  }

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

  List<String> _resolveTargetSourceIds() {
    if (SourceManager.isIOSPlatform) {
      return [
        for (final ds in SourceManager.directSources)
          if (_selectedSourceFilter == 'ALL' || _selectedSourceFilter == ds.id) ds.id,
      ];
    }
    if (_selectedSourceFilter == 'ALL') {
      final targets = <String>[];
      for (final ext in _extService.installedExtensions) {
        if (ext.subSources.isNotEmpty) {
          final allSubsSameName = ext.subSources.every((s) {
            final sName = (s['name'] ?? '').trim().toLowerCase();
            final eName = ext.name.trim().toLowerCase();
            return sName == eName ||
                sName.isEmpty ||
                DuplicateDetector.normalize(sName) == DuplicateDetector.normalize(eName);
          });

          if (allSubsSameName) {
            final enSub = ext.subSources.where((s) => (s['lang'] ?? '').toUpperCase() == 'EN').firstOrNull;
            if (enSub != null && (enSub['id'] ?? '').trim().isNotEmpty) {
              targets.add('${ext.pkg}@${(enSub['id'] ?? '').trim()}');
            } else {
              targets.add(ext.pkg);
            }
          } else {
            final seenNames = <String>{};
            for (final sub in ext.subSources) {
              final subId = (sub['id'] ?? '').trim();
              final subName = (sub['name'] ?? '').trim();
              if (seenNames.add(subName.toLowerCase())) {
                if (subId.isNotEmpty) {
                  targets.add('${ext.pkg}@$subId');
                } else if (subName.isNotEmpty) {
                  targets.add('${ext.pkg}@$subName');
                }
              }
            }
          }
        } else {
          targets.add(ext.pkg);
        }
      }
      for (final ds in SourceManager.directSources) {
        targets.add(ds.id);
      }
      return targets.where((s) => s.trim().isNotEmpty).toSet().toList();
    } else {
      if (!_selectedSourceFilter.contains('@')) {
        final ext = _extService.getExtensionByPkg(_selectedSourceFilter);
        if (ext != null && ext.subSources.isNotEmpty) {
          final subs = <String>[];
          for (final sub in ext.subSources) {
            final subId = (sub['id'] ?? '').trim();
            final subName = (sub['name'] ?? '').trim();
            if (subId.isNotEmpty) {
              subs.add('${ext.pkg}@$subId');
            } else if (subName.isNotEmpty) {
              subs.add('${ext.pkg}@$subName');
            }
          }
          if (subs.isNotEmpty) return subs.toSet().toList();
        }
      }
      return [_selectedSourceFilter];
    }
  }

  int _matchingSourcesCount() => _resolveTargetSourceIds().length;

  @visibleForTesting
  List<String> resolveTargetSourceIdsForTesting() => _resolveTargetSourceIds();

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

    final cacheKey = '${SourceManager.isIOSPlatform ? "ios" : "android"}|$_selectedSourceFilter|${q.toLowerCase()}';
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

    setState(() {
      _searchQuery = q;
      _searching = true;
      _pendingSourcesCount = _matchingSourcesCount();
      _searchResults = {};
    });

    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) {
        _runGlobalSearch(q, bypassCache: false);
      }
    });
  }

  Future<void> _runGlobalSearch(String query, {bool bypassCache = false}) async {
    final q = query.trim();
    if (q.isEmpty) return;

    final cacheKey = '${SourceManager.isIOSPlatform ? "ios" : "android"}|$_selectedSourceFilter|${q.toLowerCase()}';
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
    final List<String> targetIds = _resolveTargetSourceIds();

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
          .timeout(const Duration(seconds: 25), onTimeout: () => <MangaItem>[])
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
                    expiresAt: DateTime.now().add(const Duration(seconds: 30)),
                  );
                }
              }
            });
          });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (SourceManager.isIOSPlatform) {
      return Column(
        children: [
          const AppTopBar(
            title: 'Browse',
            branded: true,
          ),
          Expanded(
            child: _buildIOSSourcesView(),
          ),
        ],
      );
    }

    final updatesCount = _extService.updatesAvailableExtensions.length;

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
            labelStyle: AppText.bodySemiBold.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.5),
            unselectedLabelStyle: AppText.bodyMedium,
            tabs: [
              const Tab(text: 'SOURCES'),
              Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Flexible(
                      child: Text(
                        'EXTENSIONS',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (updatesCount > 0) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$updatesCount',
                          style: AppText.badge.copyWith(color: AppColors.onPrimary),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildAndroidSourcesTab(),
              const ExtensionsScreen(isEmbedded: true),
            ],
          ),
        ),
      ],
    );
  }

  /// iOS Browse view: ONLY built-in direct sources (SourceManager.directSources).
  /// No extension UI on iOS.
  Widget _buildIOSSourcesView() {
    final directSources = SourceManager.directSources;
    final pinnedDirect = directSources.where((s) => _sourceManager.isPinned(s.id)).toList();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        _buildGlobalSearchBar(),
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
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_searchQuery.isNotEmpty) ...[
          _buildSearchResults(),
        ] else ...[
          if (pinnedDirect.isNotEmpty) ...[
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
            const SizedBox(height: 14),
          ],
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
          const SizedBox(height: 24),
        ],
      ],
    );
  }

  /// Android "Sources" tab: ONLY installed Tachiyomi/Keiyoushi extension sources,
  /// grouped by language, with pinned sources on top and Popular/Latest/Search per source.
  Widget _buildAndroidSourcesTab() {
    final installedExts = _extService.installedExtensions.toList();
    final pinnedExts = installedExts.where((e) => _sourceManager.isPinned(e.pkg)).toList();

    // Group installed extensions by language (Mihon-style)
    final Map<String, List<MangaExtension>> groupedByLang = {};
    for (final ext in installedExts) {
      final langKey = ext.lang.toUpperCase();
      groupedByLang.putIfAbsent(langKey, () => []).add(ext);
    }
    final sortedLangKeys = groupedByLang.keys.toList()
      ..sort((a, b) {
        if (a == 'EN' && b != 'EN') return -1;
        if (b == 'EN' && a != 'EN') return 1;
        if (a == 'ALL' && b != 'ALL') return -1;
        if (b == 'ALL' && a != 'ALL') return 1;
        return a.compareTo(b);
      });

    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      onRefresh: () async {
        await _extService.refreshDeviceExtensions();
        await _extService.fetchExtensions(force: true);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
        _buildGlobalSearchBar(),
        if (installedExts.isNotEmpty) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,

            child: Row(
              children: [
                _buildSourceFilterChip('ALL', 'All Sources'),
                for (final ext in installedExts) ...[
                  const SizedBox(width: 6),
                  _buildSourceFilterChip(ext.pkg, ext.name),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (_searchQuery.isNotEmpty) ...[
          _buildSearchResults(),
        ] else ...[
          if (pinnedExts.isNotEmpty) ...[
            _sectionHeaderWithBadge(
              title: 'PINNED',
              badgeText: '${pinnedExts.length}',
              badgeColor: Colors.amber,
              icon: Icons.push_pin_rounded,
            ),
            for (final ext in pinnedExts)
              _buildExtensionSourceCard(ext, isPinned: true),
            const SizedBox(height: 14),
          ],
          if (installedExts.isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              margin: const EdgeInsets.only(top: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.outline),
              ),
              child: Column(
                children: [
                  const Icon(Icons.extension_off_rounded, color: AppColors.muted, size: 40),
                  const SizedBox(height: 10),
                  Text(
                    'No installed extension sources',
                    style: AppText.cardTitle,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Install Tachiyomi / Keiyoushi extensions from the Extensions tab to browse sources.',
                    textAlign: TextAlign.center,
                    style: AppText.caption,
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: () => _tabController.animateTo(1),
                    icon: const Icon(Icons.extension_rounded, size: 16),
                    label: Text('Browse Extensions', style: AppText.bodySemiBold.copyWith(color: AppColors.onPrimary)),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.onPrimary,
                      minimumSize: const Size(0, 44),
                    ),
                  ),
                ],
              ),
            )
          else
            for (final langKey in sortedLangKeys) ...[
              _sectionHeaderWithBadge(
                title: _languageGroupTitle(langKey),
                badgeText: '${groupedByLang[langKey]!.length}',
                badgeColor: const Color(0xFF10B981),
                icon: Icons.language_rounded,
              ),
              for (final ext in groupedByLang[langKey]!)
                _buildExtensionSourceCard(
                  ext,
                  isPinned: _sourceManager.isPinned(ext.pkg),
                ),
              const SizedBox(height: 10),
            ],
          const SizedBox(height: 24),
        ],
      ],
      ),
    );
  }

  Widget _buildGlobalSearchBar() {
    return Container(
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
              onChanged: _onSearchChanged,
              style: AppText.body,
              textInputAction: TextInputAction.search,
              onSubmitted: (val) {
                _searchDebounce?.cancel();
                _runGlobalSearch(val.trim(), bypassCache: true);
              },
              decoration: InputDecoration(
                hintText: () {
                  if (_selectedSourceFilter != 'ALL') {
                    if (SourceManager.isIOSPlatform) {
                      final ds = _sourceManager.getDirectSource(_selectedSourceFilter);
                      if (ds != null) return 'Search ${ds.name}...';
                    }
                    final ext = _extService.getExtensionByPkg(_selectedSourceFilter);
                    return 'Search ${ext?.name ?? _selectedSourceFilter}...';
                  }
                  return 'Search across all sources...';
                }(),
                hintStyle: AppText.body.copyWith(color: AppColors.muted),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          if (_searchController.text.isNotEmpty)
            IconButton(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              padding: EdgeInsets.zero,
              onPressed: () {
                _searchController.clear();
                _onSearchChanged('');
              },
              icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.muted),
            ),
        ],
      ),
    );
  }

  Widget _buildExtensionSourceCard(MangaExtension ext, {required bool isPinned}) {
    final versionLabel = ext.hasUpdate && ext.repoVersion != null
        ? 'v${ext.version} → v${ext.repoVersion}'
        : 'v${ext.version}';
    final descParts = <String>[
      if (ext.sourceNames.isNotEmpty) ext.sourceNames.join(', ') else ext.name,
      versionLabel,
    ];
    return _buildSourceCard(
      id: ext.pkg,
      name: ext.name,
      lang: ext.lang,
      badge: ext.lang,
      description: descParts.join(' • '),
      iconLetter: ext.name.isNotEmpty ? ext.name[0].toUpperCase() : 'E',
      iconColor: const Color(0xFF10B981),
      iconUrl: ext.iconUrl,
      iconBytes: ext.iconBytes,
      isCommunity: true,
      isPinned: isPinned,
      isCompatible: ext.isCompatible,
      isNsfw: ext.isNsfw,
      hasUpdate: ext.hasUpdate,
      isUpdating: _extService.isDownloading(ext.pkg),
      updateProgress: _extService.getProgress(ext.pkg),
      onUpdate: ext.hasUpdate
          ? () async {
              final ok = await _extService.downloadAndInstallExtension(ext);
              if (mounted) {
                final updatedVer = _extService.getExtensionByPkg(ext.pkg)?.version ?? ext.repoVersion ?? ext.version;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(ok
                        ? 'Updated ${ext.name} to v$updatedVer'
                        : (_extService.lastInstallError ?? 'Failed to update ${ext.name}.')),
                    duration: const Duration(seconds: 3),
                  ),
                );
              }
            }
          : null,
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
      labelStyle: AppText.chip.copyWith(
        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
        color: isSelected ? AppColors.onPrimary : AppColors.muted,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: isSelected ? AppColors.primary : AppColors.outline),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      showCheckmark: false,
    );
  }

  String _resolveSourceName(String sourceId) {
    final ds = _sourceManager.getDirectSource(sourceId) ??
        SourceManager.allDirectSources.where((s) => s.id == sourceId).firstOrNull;
    final ext = _extService.getExtensionByPkg(sourceId);
    String sourceName = ds?.name ?? ext?.name ?? SourceResolver.displayName(sourceId);
    if (sourceId.contains('@') && ext != null && ext.subSources.isNotEmpty) {
      final subSelector = sourceId.split('@').last.toLowerCase();
      final matchSub = ext.subSources.where((s) =>
        (s['id'] ?? '').toLowerCase() == subSelector ||
        (s['name'] ?? '').toLowerCase() == subSelector
      ).firstOrNull;
      if (matchSub != null && (matchSub['name'] ?? '').isNotEmpty) {
        final subName = matchSub['name']!.trim();
        if (subName.toLowerCase() != ext.name.toLowerCase()) {
          sourceName = '${ext.name} ($subName)';
        } else if ((matchSub['lang'] ?? '').isNotEmpty && matchSub['lang']!.toUpperCase() != 'ALL') {
          sourceName = '${ext.name} (${matchSub['lang']!.toUpperCase()})';
        } else {
          sourceName = ext.name;
        }
      }
    }
    return sourceName;
  }

  Widget _buildSearchResults() {
    final Map<String, List<MangaItem>> mergedResults = {};
    final Map<String, String> primarySourceIdForName = {};
    for (final e in _searchResults.entries) {
      if (e.value.isEmpty) continue;
      final name = _resolveSourceName(e.key);
      if (!mergedResults.containsKey(name)) {
        mergedResults[name] = [...e.value];
        primarySourceIdForName[name] = e.key;
      } else {
        final existing = mergedResults[name]!;
        for (final item in e.value) {
          if (!existing.any((m) => m.id == item.id)) {
            existing.add(item);
          }
        }
      }
    }
    final entriesWithResults = [
      for (final entry in mergedResults.entries)
        MapEntry(primarySourceIdForName[entry.key] ?? entry.key, entry.value),
    ];
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
                  Expanded(
                    child: Text(
                      _selectedSourceFilter == 'ALL'
                          ? 'Searching across sources...'
                          : 'Searching source...',
                      style: AppText.caption.copyWith(fontWeight: FontWeight.w500),
                    ),
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
          : ' on ${(SourceManager.isIOSPlatform ? _sourceManager.getDirectSource(_selectedSourceFilter)?.name : null) ?? _extService.getExtensionByPkg(_selectedSourceFilter)?.name ?? _selectedSourceFilter}';

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
                  style: AppText.cardTitle.copyWith(color: AppColors.muted, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _runGlobalSearch(_searchQuery, bypassCache: true),
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: Text('Retry Search', style: AppText.bodySemiBold),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.surfaceHigh,
                        foregroundColor: AppColors.text,
                        minimumSize: const Size(0, 44),
                      ),
                    ),
                    if (!SourceManager.isIOSPlatform)
                      OutlinedButton.icon(
                        onPressed: () => _tabController.animateTo(1),
                        icon: const Icon(Icons.extension_rounded, size: 16),
                        label: Text('Browse Extensions', style: AppText.bodySemiBold.copyWith(color: AppColors.primary)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.primary),
                          minimumSize: const Size(0, 44),
                        ),
                      ),
                  ],
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
                Expanded(
                  child: Text(
                    'Searching $_pendingSourcesCount more source${_pendingSourcesCount == 1 ? '' : 's'}...',
                    style: AppText.caption.copyWith(fontWeight: FontWeight.w500),
                  ),
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
    final ds = _sourceManager.getDirectSource(sourceId) ??
        SourceManager.allDirectSources.where((s) => s.id == sourceId).firstOrNull;
    final sourceName = _resolveSourceName(sourceId);
    final badgeColor = ds != null ? Color(ds.colorValue) : const Color(0xFF10B981);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: .2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  sourceName.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.badge.copyWith(color: badgeColor),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${items.length} titles found',
              style: AppText.caption,
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 194,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,

            addRepaintBoundaries: true,
            addAutomaticKeepAlives: false,
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
                  width: 108,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CoverImage(
                                imageUrl: manga.cover,
                                mangaId: manga.id,
                                memCacheWidth: 160,
                                memCacheHeight: 240,
                              ),
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
                                      style: AppText.badge.copyWith(color: Colors.white),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        manga.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(
                          color: AppColors.text,
                          fontWeight: FontWeight.w600,
                        ),
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
              style: AppText.sectionHeader,
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
                style: AppText.badge.copyWith(color: badgeColor),
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
    Uint8List? iconBytes,
    bool isCommunity = false,
    bool isPinned = false,
    bool isCompatible = true,
    bool isNsfw = false,
    bool hasUpdate = false,
    bool isUpdating = false,
    double updateProgress = 0.0,
    VoidCallback? onUpdate,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                    child: iconBytes != null && iconBytes.isNotEmpty
                        ? Image.memory(
                            iconBytes,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Center(
                              child: Text(
                                iconLetter,
                                style: AppText.title.copyWith(color: iconColor),
                              ),
                            ),
                          )
                        : iconUrl != null && iconUrl.isNotEmpty
                            ? RetryingNetworkImage(
                                url: iconUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (context, retry) => Center(
                                  child: Text(
                                    iconLetter,
                                    style: AppText.title.copyWith(color: iconColor),
                                  ),
                                ),
                              )
                            : Center(
                                child: Text(
                                  iconLetter,
                                  style: AppText.title.copyWith(color: iconColor),
                                ),
                              ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.cardTitle,
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceHigh,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              badge,
                              style: AppText.badge.copyWith(color: AppColors.primary),
                            ),
                          ),
                          if (isNsfw)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.redAccent.withValues(alpha: .2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '18+',
                                style: AppText.badge.copyWith(color: Colors.redAccent),
                              ),
                            ),
                          if (!isCompatible)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.orangeAccent.withValues(alpha: .2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'Incompatible lib version',
                                style: AppText.badge.copyWith(color: Colors.orangeAccent),
                              ),
                            ),
                          if (isUpdating)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.primary.withValues(alpha: .2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 10,
                                    height: 10,
                                    child: CircularProgressIndicator(
                                      value: updateProgress > 0.05 ? updateProgress : null,
                                      strokeWidth: 1.8,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    updateProgress > 0 ? '${(updateProgress * 100).toInt()}%' : 'Updating...',
                                    style: AppText.badge.copyWith(color: AppColors.primary),
                                  ),
                                ],
                              ),
                            )
                          else if (hasUpdate)
                            InkWell(
                              borderRadius: BorderRadius.circular(4),
                              onTap: onUpdate,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.primary.withValues(alpha: .2),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: AppColors.primary.withValues(alpha: .5)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.system_update_rounded, size: 11, color: AppColors.primary),
                                    const SizedBox(width: 3),
                                    Text(
                                      'Update',
                                      style: AppText.badge.copyWith(color: AppColors.primary),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(height: 1.3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                    color: isPinned ? Colors.amber : AppColors.muted,
                    size: 18,
                  ),
                  tooltip: isPinned ? 'Unpin source' : 'Pin to top',
                  onPressed: () => _sourceManager.togglePin(id),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: !isCompatible
                        ? null
                        : () {
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
                    icon: const Icon(Icons.local_fire_department_rounded, size: 15),
                    label: Text(
                      'Popular',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.chip.copyWith(
                        color: AppColors.onPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.onPrimary,
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: !isCompatible
                        ? null
                        : () {
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
                    icon: const Icon(Icons.schedule_rounded, size: 15),
                    label: Text(
                      'Latest',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.chip.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      side: const BorderSide(color: AppColors.outline),
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                if (hasUpdate || isUpdating) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: isUpdating ? null : onUpdate,
                      icon: isUpdating
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                value: updateProgress > 0.05 ? updateProgress : null,
                                strokeWidth: 2,
                                color: AppColors.primary,
                              ),
                            )
                          : const Icon(Icons.system_update_rounded, size: 15),
                      label: Text(
                        isUpdating
                            ? (updateProgress > 0 ? '${(updateProgress * 100).toInt()}%' : 'Updating')
                            : 'Update',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.chip.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: const BorderSide(color: AppColors.primary),
                        minimumSize: const Size(0, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
