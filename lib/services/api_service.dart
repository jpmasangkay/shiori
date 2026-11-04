import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/app_logger.dart';
import 'package:manga_reader/services/auth_service.dart';
import 'package:manga_reader/services/extension_service.dart';
import 'package:manga_reader/services/history_repository.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/library_repository.dart';
import 'package:manga_reader/services/manga_catalog_service.dart';
import 'package:manga_reader/services/scrapers/asura_scraper.dart';
import 'package:manga_reader/services/scrapers/flame_scraper.dart';
import 'package:manga_reader/services/scrapers/mangadex_service.dart';
import 'package:manga_reader/services/scrapers/mangakatana_scraper.dart';
import 'package:manga_reader/services/scrapers/mangapill_scraper.dart';
import 'package:manga_reader/services/scrapers/mangaread_scraper.dart';
import 'package:manga_reader/services/scrapers/web_extension_scraper.dart';
import 'package:manga_reader/services/scrapers/weeb_scraper.dart';
import 'package:manga_reader/widgets/common.dart';

enum SyncStatus { idle, syncing, success, error }

class SyncState {
  final SyncStatus status;
  final String? message;
  final DateTime? lastSyncedAt;

  const SyncState({
    this.status = SyncStatus.idle,
    this.message,
    this.lastSyncedAt,
  });

  bool get isSyncing => status == SyncStatus.syncing;
}

/// Central API Service facade coordinating modular sub-services (#1)
/// Preserves complete backwards compatibility for existing screens and tests.
class ApiService extends ChangeNotifier {
  ApiService._() {
    _wireUpDependencies();
  }
  static final ApiService instance = ApiService._();

  late HttpManager httpManager;
  late AuthService auth;
  late LibraryRepository libraryRepo;
  late HistoryRepository historyRepo;
  late MangaCatalogService catalog;

  late MangaDexService _mangadex;
  late AsuraScraper _asura;
  late FlameScraper _flame;
  late WeebScraper _weeb;
  late MangaPillScraper _mangapill;
  late MangaKatanaScraper _mangakatana;
  late MangaReadScraper _mangaread;
  late WebExtensionScraper _webExtension;

  String _baseUrl = 'https://shiori-n5hd.onrender.com/api';
  bool _mongoConnected = false;
  bool _initialized = false;
  SharedPreferences? _cachedPrefs;

  final ValueNotifier<SyncState> syncState = ValueNotifier<SyncState>(const SyncState());

  String get baseUrl => _baseUrl;
  String? get token => auth.token;
  UserAccount? get currentUser => auth.currentUser;
  bool get isLoggedIn => auth.isLoggedIn;
  bool get isMongoConnected => _mongoConnected;
  bool get isSessionExpired => auth.isSessionExpired;

  void _wireUpDependencies() {
    httpManager = HttpManager(
      tokenProvider: () => auth.token,
      onUnauthorized: () {
        auth.handleUnauthorized();
        notifyListeners();
      },
    );

    auth = AuthService(
      clientProvider: () => httpManager.client,
      baseUrlProvider: () => _baseUrl,
    );
    auth.addListener(notifyListeners);

    libraryRepo = LibraryRepository();
    libraryRepo.addListener(notifyListeners);

    historyRepo = HistoryRepository();
    historyRepo.addListener(notifyListeners);

    _mangadex = MangaDexService(
      clientProvider: () => httpManager.client,
      cache: httpManager.cache,
      baseUrlProvider: () => _baseUrl,
    );
    _asura = AsuraScraper(
      clientProvider: () => httpManager.client,
      cache: httpManager.cache,
    );
    _flame = FlameScraper(
      clientProvider: () => httpManager.client,
      cache: httpManager.cache,
    );
    _weeb = WeebScraper(
      clientProvider: () => httpManager.client,
      cache: httpManager.cache,
    );
    _mangapill = MangaPillScraper(
      clientProvider: () => httpManager.client,
      cache: httpManager.cache,
    );
    _mangakatana = MangaKatanaScraper(
      clientProvider: () => httpManager.client,
      cache: httpManager.cache,
    );
    _mangaread = MangaReadScraper(
      clientProvider: () => httpManager.client,
      cache: httpManager.cache,
    );
    _webExtension = WebExtensionScraper(
      clientProvider: () => httpManager.client,
      cache: httpManager.cache,
    );

    catalog = MangaCatalogService(
      mangadex: _mangadex,
      asura: _asura,
      flame: _flame,
      weeb: _weeb,
      mangapill: _mangapill,
      mangakatana: _mangakatana,
      mangaread: _mangaread,
      webExtension: _webExtension,
      clientProvider: () => httpManager.client,
      baseUrlProvider: () => _baseUrl,
    );
  }

  void setHttpClient(http.Client? client) {
    httpManager.setClient(client);
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _cachedPrefs = prefs;
    final savedBase = prefs.getString('api_base_url');
    if (savedBase != null && savedBase.isNotEmpty) {
      _baseUrl = savedBase;
    }

    await auth.init(prefs);
    await libraryRepo.init(prefs);
    await historyRepo.init(prefs);

    final firstInit = !_initialized;
    _initialized = true;

    if (firstInit) {
      unawaited(checkHealth());
      if (isLoggedIn) {
        unawaited(syncAllCloudData());
      }
    }
  }

  Future<void> setBaseUrl(String url) async {
    var cleaned = url.trim();
    if (cleaned.endsWith('/')) cleaned = cleaned.substring(0, cleaned.length - 1);
    if (!cleaned.endsWith('/api')) cleaned = '$cleaned/api';
    _baseUrl = cleaned;
    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', _baseUrl);
    await checkHealth();
    notifyListeners();
  }

  Future<bool> checkHealth() async {
    try {
      final res = await httpManager.client.get(Uri.parse('$_baseUrl/health')).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        _mongoConnected = data['database'] == 'connected' || data['mongo'] == 'connected';
        notifyListeners();
        return true;
      }
    } catch (_) {
      _mongoConnected = false;
      notifyListeners();
    }
    return false;
  }

  // ---- Auth Methods ----

  Future<void> register(String email, String password, {String? displayName}) async {
    await auth.register(email, password, displayName: displayName);
    await syncAllCloudData();
  }

  Future<void> login(String email, String password) async {
    await auth.login(email, password);
    await syncAllCloudData();
  }

  Future<void> logout({bool clearLocalData = false}) async {
    await auth.logout(
      clearLocalData: clearLocalData,
      onClearLocalData: () async {
        await libraryRepo.clearLocalData();
        await historyRepo.clearLocalData();
      },
    );
  }

  void setMockClient(http.Client? client) {
    httpManager.setClient(client);
  }

  Future<bool> syncNow() async {
    try {
      await syncAllCloudData();
      return syncState.value.status == SyncStatus.success;
    } catch (_) {
      return false;
    }
  }

  Future<CategoryItem> addCategory(String name) => createCategory(name);

  void clearSessionExpiredBanner() {
    auth.clearSessionExpiredBanner();
  }

  // ---- Cloud Sync Coordination (#11, #31-#37) ----

  Future<void> syncAllCloudData() async {
    if (!isLoggedIn) return;

    syncState.value = SyncState(
      status: SyncStatus.syncing,
      message: 'Syncing library and reading progress...',
      lastSyncedAt: syncState.value.lastSyncedAt,
    );

    try {
      final h = auth.headers(withAuth: true);

      // 1. Parallel uploads of bookmarks & categories
      await libraryRepo.uploadLibraryBookmarks(httpManager.client, _baseUrl, h);
      await libraryRepo.syncCategoriesWithCloud(httpManager.client, _baseUrl, h);

      // 2. Parallel upload of progress, history, and read marks
      await historyRepo.uploadProgressAndHistory(httpManager.client, _baseUrl, h);

      // 3. Download cloud bookmarks
      await libraryRepo.downloadLibraryBookmarks(httpManager.client, _baseUrl, h);

      // 4. Download and merge reading history with timestamp checks (#31)
      await historyRepo.downloadAndMergeSyncData(httpManager.client, _baseUrl, h);

      syncState.value = SyncState(
        status: SyncStatus.success,
        message: 'Sync complete',
        lastSyncedAt: DateTime.now(),
      );
      notifyListeners();
    } catch (e, st) {
      AppLogger.warn('syncAllCloudData failed', e, st);
      syncState.value = SyncState(
        status: SyncStatus.error,
        message: 'Sync failed: $e',
        lastSyncedAt: syncState.value.lastSyncedAt,
      );
      notifyListeners();
    }
  }

  // ---- Library Methods ----

  bool isInLibrary(String mangaId) => libraryRepo.isInLibrary(mangaId);

  void cacheKnownManga(MangaItem manga) => libraryRepo.cacheKnownManga(manga);

  Future<List<MangaItem>> getLibrary({String? type}) async {
    if (isLoggedIn) {
      try {
        await libraryRepo.downloadLibraryBookmarks(httpManager.client, _baseUrl, auth.headers(withAuth: true));
      } catch (_) {}
    }
    return libraryRepo.getLibraryItems(type: type);
  }

  Future<bool> checkInLibrary(String mangaId) async {
    if (libraryRepo.isInLibrary(mangaId)) return true;
    if (!isLoggedIn) return false;
    try {
      final res = await httpManager.client
          .get(Uri.parse('$_baseUrl/library/check/$mangaId'), headers: auth.headers(withAuth: true))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final inLib = data['inLibrary'] == true;
        if (inLib && !libraryRepo.isInLibrary(mangaId)) {
          final m = await getManga(mangaId);
          await libraryRepo.addToLibrary(m);
        }
        return inLib;
      }
    } catch (_) {}
    return false;
  }

  Future<void> addToLibrary(MangaItem manga) async {
    await libraryRepo.addToLibrary(
      manga,
      client: isLoggedIn ? httpManager.client : null,
      baseUrl: _baseUrl,
      headers: auth.headers(withAuth: true),
    );
  }

  Future<void> updateCachedMangaMetadata(MangaItem updated) async {
    await libraryRepo.updateCachedMangaMetadata(updated);
  }

  Future<void> removeFromLibrary(String mangaId) async {
    await libraryRepo.removeFromLibrary(
      mangaId,
      client: isLoggedIn ? httpManager.client : null,
      baseUrl: _baseUrl,
      headers: auth.headers(withAuth: true),
    );
  }

  // ---- Category Methods (#35) ----

  List<CategoryItem> getCategories() => libraryRepo.getCategories();

  Future<CategoryItem> createCategory(String name) => libraryRepo.createCategory(name);

  Future<void> renameCategory(String id, String newName) => libraryRepo.renameCategory(id, newName);

  Future<void> deleteCategory(String id) => libraryRepo.deleteCategory(id);

  List<String> getMangaCategoryIds(String mangaId) => libraryRepo.getMangaCategoryIds(mangaId);

  Future<void> setMangaCategories(
    String mangaId,
    List<String> categoryIds, {
    MangaItem? manga,
  }) =>
      libraryRepo.setMangaCategories(mangaId, categoryIds, manga: manga);

  Future<void> toggleMangaCategory(
    String mangaId,
    String categoryId, {
    MangaItem? manga,
  }) =>
      libraryRepo.toggleMangaCategory(mangaId, categoryId, manga: manga);

  // ---- Reading Progress & History Methods (#6, #18, #31, #33) ----

  Future<void> saveProgress({
    required String mangaId,
    required String chapterId,
    String? mangaTitle,
    String? cover,
    String? source,
    String? chapterNumber,
    String? chapterTitle,
    int page = 1,
    int totalPages = 0,
    bool completed = false,
  }) async {
    await historyRepo.saveProgress(
      mangaId: mangaId,
      chapterId: chapterId,
      mangaTitle: mangaTitle,
      cover: cover,
      source: source,
      chapterNumber: chapterNumber,
      chapterTitle: chapterTitle,
      page: page,
      totalPages: totalPages,
      completed: completed,
      client: isLoggedIn ? httpManager.client : null,
      baseUrl: _baseUrl,
      headers: auth.headers(withAuth: true),
    );
  }

  Future<Map<String, dynamic>> getMangaProgress(String mangaId) async {
    final base = historyRepo.getMangaProgress(mangaId);
    if (!isLoggedIn) return base;
    try {
      final res = await httpManager.client
          .get(Uri.parse('$_baseUrl/progress/manga/$mangaId'), headers: auth.headers(withAuth: true))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final completed = (data['completedChapters'] ?? data['completedChapterIds']) as List?;
        if (completed != null) {
          final cloudCompleted = completed.map((e) => e.toString()).toList();
          await historyRepo.markChaptersRead(mangaId, cloudCompleted, read: true);
        }
        return historyRepo.getMangaProgress(mangaId);
      }
    } catch (_) {}
    return base;
  }

  bool isChapterRead(String mangaId, String chapterId) => historyRepo.isChapterRead(mangaId, chapterId);

  Set<String> getReadChapterIds(String mangaId) => historyRepo.getReadChapterIds(mangaId);

  Future<void> markChapterRead(String mangaId, String chapterId, {bool read = true}) =>
      historyRepo.markChapterRead(mangaId, chapterId, read: read);

  Future<void> markChaptersRead(String mangaId, List<String> chapterIds, {bool read = true}) =>
      historyRepo.markChaptersRead(mangaId, chapterIds, read: read);

  void recordChapterCount(String mangaId, int count) => historyRepo.recordChapterCount(mangaId, count);

  int getUnreadCount(String mangaId) => historyRepo.getUnreadCount(mangaId);

  bool isChapterBookmarked(String chapterId) => historyRepo.isChapterBookmarked(chapterId);

  Future<bool> toggleChapterBookmark(String chapterId) => historyRepo.toggleChapterBookmark(
        chapterId,
        client: isLoggedIn ? httpManager.client : null,
        baseUrl: _baseUrl,
        headers: auth.headers(withAuth: true),
      );

  Future<void> setChapterBookmarked(String chapterId, bool bookmarked) =>
      historyRepo.setChapterBookmarked(chapterId, bookmarked);

  Set<String> getBookmarkedChapterIds() => historyRepo.getBookmarkedChapterIds();

  Future<List<Map<String, dynamic>>> getHistory() async {
    if (isLoggedIn) {
      try {
        await historyRepo.downloadAndMergeSyncData(httpManager.client, _baseUrl, auth.headers(withAuth: true));
      } catch (_) {}
    }
    return historyRepo.getHistoryAsMaps();
  }

  List<ReadHistoryEntry> getHistoryEntries() => historyRepo.getHistoryEntries();

  Future<void> removeHistoryEntry(String chapterId) => historyRepo.removeHistoryEntry(
        chapterId,
        client: isLoggedIn ? httpManager.client : null,
        baseUrl: _baseUrl,
        headers: auth.headers(withAuth: true),
      );

  Future<void> clearHistory() => historyRepo.clearHistory(
        client: isLoggedIn ? httpManager.client : null,
        baseUrl: _baseUrl,
        headers: auth.headers(withAuth: true),
      );

  // ---- Catalog Queries & Updates ----

  Future<List<MangaItem>> searchManga({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
    String source = 'mangadex',
  }) =>
      catalog.searchManga(
        query: query,
        type: type,
        order: order,
        page: page,
        limit: limit,
        source: source,
      );

  Future<MangaItem> getManga(String id) => catalog.getManga(id);

  Future<List<ChapterItem>> getChapters(String mangaId, {String lang = 'en'}) =>
      catalog.getChapters(mangaId, lang: lang, onChapterCount: recordChapterCount);

  Future<ChapterPages> getChapterPages(String chapterId, {bool forceRefresh = false}) =>
      catalog.getChapterPages(chapterId, forceRefresh: forceRefresh);

  Future<Map<String, dynamic>> getUpdates() async {
    final bookmarked = libraryRepo.getLibraryItems();
    return catalog.getUpdates(
      bookmarked: bookmarked,
      authHeaders: isLoggedIn ? auth.headers(withAuth: true) : null,
    );
  }

  Future<int> checkForLibraryUpdates() async {
    final library = libraryRepo.getLibraryItems();
    if (library.isEmpty) return 0;

    int newChaptersCount = 0;
    for (var i = 0; i < library.length; i += 4) {
      final chunk = library.skip(i).take(4);
      await Future.wait(chunk.map((manga) async {
        try {
          final oldCount = historyRepo.getUnreadCount(manga.id);
          final chapters = await getChapters(manga.id);
          if (oldCount > 0 && chapters.length > oldCount) {
            newChaptersCount += (chapters.length - oldCount);
          }
        } catch (_) {}
      }));
    }
    notifyListeners();
    return newChaptersCount;
  }

  bool _isAutoRefreshing = false;
  bool get isAutoRefreshing => _isAutoRefreshing;
  DateTime? _lastAutoRefresh;

  /// High-performance automated refresh:
  /// Synchronizes cloud state, checks library for new chapters, updates extensions,
  /// and updates all screens. Throttled (min 20s between runs) and non-blocking
  /// to ensure buttery performance even on budget phones.
  Future<void> autoRefreshEverything({bool force = false}) async {
    final now = DateTime.now();
    if (_isAutoRefreshing) return;
    if (!force && _lastAutoRefresh != null && now.difference(_lastAutoRefresh!) < const Duration(seconds: 20)) {
      return;
    }

    _isAutoRefreshing = true;
    _lastAutoRefresh = now;
    notifyListeners();

    try {
      // 1. Silent cloud synchronization if signed in
      if (isLoggedIn) {
        await syncAllCloudData();
      }

      // 2. Automatic background library chapter update check (4 at a time to prevent UI lag)
      await checkForLibraryUpdates();

      // 3. Silent extension status check
      try {
        await ExtensionService.instance.refreshDeviceExtensions();
      } catch (_) {}
    } catch (e, st) {
      AppLogger.warn('autoRefreshEverything failed: $e', e, st);
    } finally {
      _isAutoRefreshing = false;
      notifyListeners();
    }
  }

  // ---- Backup & Restore ----

  Future<String> exportBackupJson() async {
    final installed = ExtensionService.instance.installedPackages.toList();
    final backup = {
      'version': 1,
      'app': 'Shiori',
      'exportedAt': DateTime.now().toIso8601String(),
      'bookmarksCount': libraryRepo.localLibrary.length,
      'historyCount': historyRepo.localHistory.length,
      'library': libraryRepo.localLibrary.values.map((e) => e.toJson()).toList(),
      'history': historyRepo.getHistoryAsMaps(),
      'progress': {for (final e in historyRepo.localProgress.entries) e.key: e.value.toMap()},
      'installedSources': installed,
    };
    return const JsonEncoder.withIndent('  ').convert(backup);
  }

  Future<Map<String, int>> restoreBackupJson(String jsonString) async {
    final Map<String, dynamic> data = jsonDecode(jsonString.trim()) as Map<String, dynamic>;
    int restoredBookmarks = 0;
    int restoredHistory = 0;

    if (data['library'] is List) {
      for (final item in data['library'] as List) {
        if (item is Map) {
          final m = MangaItem.fromJson(Map<String, dynamic>.from(item));
          if (m.id.isNotEmpty) {
            await libraryRepo.addToLibrary(m);
            restoredBookmarks++;
          }
        }
      }
    }

    if (data['history'] is List) {
      for (final item in data['history'] as List) {
        if (item is Map) {
          final entry = ReadProgress.fromMap(Map<String, dynamic>.from(item));
          if (entry.mangaId.isNotEmpty) {
            await historyRepo.saveProgress(
              mangaId: entry.mangaId,
              chapterId: entry.chapterId,
              mangaTitle: entry.mangaTitle,
              cover: entry.cover,
              chapterNumber: entry.chapterNumber,
              chapterTitle: entry.chapterTitle,
              page: entry.page,
              totalPages: entry.totalPages,
              completed: entry.completed,
            );
            restoredHistory++;
          }
        }
      }
    }

    if (data['installedSources'] is List) {
      final exts = (data['installedSources'] as List).map((e) => e.toString()).toList();
      for (final pkg in exts) {
        await ExtensionService.instance.installPackageByNameOrId(pkg);
      }
    }

    if (isLoggedIn) {
      unawaited(syncAllCloudData());
    }

    notifyListeners();
    return {
      'bookmarks': restoredBookmarks,
      'history': restoredHistory,
    };
  }

  // ---- Cache Eviction (#10) ----

  Future<void> clearAllCaches() async {
    // 1. Clear In-memory HTTP cache & Flame series cache
    httpManager.clearCache();
    _flame.clearCache();

    // 2. Clear Flutter Painting image cache
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    // 3. Clear DefaultCacheManager (cached network images on disk)
    try {
      await DefaultCacheManager().emptyCache().timeout(const Duration(milliseconds: 600));
    } catch (e) {
      AppLogger.warn('DefaultCacheManager emptyCache error', e);
    }

    AppLogger.info('Cleared all image, network, and in-memory caches');
  }

  Map<String, String> getHeadersForUrl(String url) => imageHeadersForUrl(url);
}
