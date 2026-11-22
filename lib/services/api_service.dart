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
import 'package:manga_reader/services/connectivity_service.dart';
import 'package:manga_reader/services/download_service.dart';
import 'package:manga_reader/services/extension_bridge.dart';
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
import 'package:manga_reader/services/scrapers/manganato_scraper.dart';
import 'package:manga_reader/services/scrapers/mangafox_scraper.dart';
import 'package:manga_reader/services/scrapers/mangademon_scraper.dart';
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
  late MangaNatoScraper _manganato;
  late MangaFoxScraper _mangafox;
  late MangaDemonScraper _mangademon;
  late WebExtensionScraper _webExtension;

  String _baseUrl = 'https://shiori-n5hd.onrender.com/api';
  bool _mongoConnected = false;
  bool _initialized = false;
  bool _wasOffline = false;
  SharedPreferences? _cachedPrefs;

  final ValueNotifier<SyncState> syncState = ValueNotifier<SyncState>(
    const SyncState(),
  );

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

    ConnectivityService.instance.addListener(_onConnectivityChanged);

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
    _manganato = MangaNatoScraper(
      clientProvider: () => httpManager.client,
      cache: httpManager.cache,
    );
    _mangafox = MangaFoxScraper(
      clientProvider: () => httpManager.client,
      cache: httpManager.cache,
    );
    _mangademon = MangaDemonScraper(
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
      manganato: _manganato,
      mangafox: _mangafox,
      mangademon: _mangademon,
      webExtension: _webExtension,
      clientProvider: () => httpManager.client,
      baseUrlProvider: () => _baseUrl,
    );
  }

  void _onConnectivityChanged() {
    final nowOffline = ConnectivityService.instance.isOffline;
    if (_wasOffline && !nowOffline) {
      // Automatically flush and sync all offline changes as soon as internet reconnects
      if (isLoggedIn) {
        unawaited(syncAllCloudData());
      }
    }
    _wasOffline = nowOffline;
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

    // Wire up automatic cover lookup for missing or failed manga covers (#11, #32)
    ImageReferers.coverLookup = (String mangaId) async {
      final localDownloadedCover = DownloadService.instance
          .getLocalCoverForManga(mangaId);
      if (localDownloadedCover != null && localDownloadedCover.isNotEmpty) {
        return localDownloadedCover;
      }
      if (ConnectivityService.instance.isOffline) return null;
      try {
        final manga = await getManga(mangaId);
        if (manga.cover.isNotEmpty && !manga.cover.startsWith('file://')) {
          await updateCachedMangaMetadata(manga);
          return manga.cover;
        }
      } catch (e) {
        AppLogger.warn('ImageReferers coverLookup failed for $mangaId', e);
      }
      return null;
    };

    ImageReferers.nativeLoaderProvider = (String url, String? mangaId) {
      final uri = Uri.tryParse(url);
      final host = uri?.host.toLowerCase() ?? '';
      if (host.contains('mangadex')) {
        return null;
      }
      if (mangaId != null && mangaId.startsWith('ext:')) {
        final pkg = mangaId.substring(4).split(':').first;
        return (targetUrl) =>
            ExtensionBridge.instance.fetchImageBytes(pkg: pkg, url: targetUrl);
      }
      return null;
    };

    ImageReferers.refererProvider = (String url, String? mangaId) {
      if (mangaId != null && mangaId.startsWith('ext:')) {
        final pkg = mangaId.substring(4).split(':').first;
        final ext = ExtensionService.instance.getExtensionByPkg(pkg);
        if (ext != null && ext.homeUrl.isNotEmpty) {
          return ext.homeUrl;
        }
      }
      return null;
    };

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
    if (cleaned.endsWith('/'))
      cleaned = cleaned.substring(0, cleaned.length - 1);
    if (!cleaned.endsWith('/api')) cleaned = '$cleaned/api';
    _baseUrl = cleaned;
    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', _baseUrl);
    await checkHealth();
    notifyListeners();
  }

  Future<bool> checkHealth() async {
    if (ConnectivityService.instance.isOffline) {
      _mongoConnected = false;
      return false;
    }
    try {
      final res = await httpManager.client
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        _mongoConnected =
            data['database'] == 'connected' || data['mongo'] == 'connected';
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

  Future<void> register(
    String email,
    String password, {
    String? displayName,
  }) async {
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

  Future<void>? _activeSyncFuture;

  Future<void> syncAllCloudData() async {
    if (!isLoggedIn || ConnectivityService.instance.isOffline) return;
    if (_activeSyncFuture != null) {
      return _activeSyncFuture!;
    }
    final future = _performSyncAllCloudData();
    _activeSyncFuture = future;
    try {
      await future;
    } finally {
      if (identical(_activeSyncFuture, future)) {
        _activeSyncFuture = null;
      }
    }
  }

  Future<void> _performSyncAllCloudData() async {
    syncState.value = SyncState(
      status: SyncStatus.syncing,
      message: 'Syncing library and reading progress...',
      lastSyncedAt: syncState.value.lastSyncedAt,
    );

    try {
      final h = auth.headers(withAuth: true);

      // 1. Parallel uploads of bookmarks & categories
      await libraryRepo.uploadLibraryBookmarks(httpManager.client, _baseUrl, h);
      await libraryRepo.syncCategoriesWithCloud(
        httpManager.client,
        _baseUrl,
        h,
      );

      // 2. Parallel upload of progress, history, and read marks
      await historyRepo.uploadProgressAndHistory(
        httpManager.client,
        _baseUrl,
        h,
      );

      // 3. Download cloud bookmarks
      await libraryRepo.downloadLibraryBookmarks(
        httpManager.client,
        _baseUrl,
        h,
        coverFallback: (id) => historyRepo.localProgress[id]?.cover,
      );

      // 4. Download and merge reading history with timestamp checks (#31)
      await historyRepo.downloadAndMergeSyncData(
        httpManager.client,
        _baseUrl,
        h,
      );

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

  // ---- Library Methods (True Local-First Stale-While-Revalidate) ----

  bool isInLibrary(String mangaId) => libraryRepo.isInLibrary(mangaId);

  void cacheKnownManga(MangaItem manga) => libraryRepo.cacheKnownManga(manga);

  /// Local-first library fetch:
  /// - UI screens render `libraryRepo.getLibraryItems()` synchronously on Frame 0 (0ms).
  /// - When `getLibrary()` is awaited, it waits up to 1.2s for the cloud response on fast
  ///   connections so callers always receive fresh cloud items, while on slow/stalled
  ///   connections (>1.2s) it returns local items immediately and finishes cloud sync in background!
  Future<List<MangaItem>> getLibrary({
    String? type,
    bool forceCloudSync = false,
  }) async {
    final localItems = libraryRepo.getLibraryItems(type: type);
    if (isLoggedIn && !ConnectivityService.instance.isOffline) {
      Future<void> pullCloud() async {
        try {
          await libraryRepo.downloadLibraryBookmarks(
            httpManager.client,
            _baseUrl,
            auth.headers(withAuth: true),
            coverFallback: (id) => historyRepo.localProgress[id]?.cover,
          );
        } catch (_) {}
      }

      if (localItems.isEmpty || forceCloudSync) {
        await pullCloud();
        return libraryRepo.getLibraryItems(type: type);
      }
      unawaited(pullCloud());
    }
    return localItems;
  }

  Future<bool> checkInLibrary(String mangaId) async {
    if (libraryRepo.isInLibrary(mangaId)) return true;
    if (!isLoggedIn || ConnectivityService.instance.isOffline) return false;
    try {
      final res = await httpManager.client
          .get(
            Uri.parse('$_baseUrl/library/check/$mangaId'),
            headers: auth.headers(withAuth: true),
          )
          .timeout(const Duration(seconds: 6));
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
      client: (isLoggedIn && !ConnectivityService.instance.isOffline)
          ? httpManager.client
          : null,
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
      client: (isLoggedIn && !ConnectivityService.instance.isOffline)
          ? httpManager.client
          : null,
      baseUrl: _baseUrl,
      headers: auth.headers(withAuth: true),
    );
  }

  // ---- Category Methods (#35) ----

  List<CategoryItem> getCategories() => libraryRepo.getCategories();

  Future<CategoryItem> createCategory(String name) =>
      libraryRepo.createCategory(
        name,
        client: (isLoggedIn && !ConnectivityService.instance.isOffline)
            ? httpManager.client
            : null,
        baseUrl: _baseUrl,
        headers: auth.headers(withAuth: true),
      );

  Future<void> renameCategory(String id, String newName) =>
      libraryRepo.renameCategory(
        id,
        newName,
        client: (isLoggedIn && !ConnectivityService.instance.isOffline)
            ? httpManager.client
            : null,
        baseUrl: _baseUrl,
        headers: auth.headers(withAuth: true),
      );

  Future<void> deleteCategory(String id) => libraryRepo.deleteCategory(
    id,
    client: (isLoggedIn && !ConnectivityService.instance.isOffline)
        ? httpManager.client
        : null,
    baseUrl: _baseUrl,
    headers: auth.headers(withAuth: true),
  );

  List<String> getMangaCategoryIds(String mangaId) =>
      libraryRepo.getMangaCategoryIds(mangaId);

  Future<void> setMangaCategories(
    String mangaId,
    List<String> categoryIds, {
    MangaItem? manga,
  }) => libraryRepo.setMangaCategories(
    mangaId,
    categoryIds,
    manga: manga,
    client: (isLoggedIn && !ConnectivityService.instance.isOffline)
        ? httpManager.client
        : null,
    baseUrl: _baseUrl,
    headers: auth.headers(withAuth: true),
  );

  Future<void> toggleMangaCategory(
    String mangaId,
    String categoryId, {
    MangaItem? manga,
  }) => libraryRepo.toggleMangaCategory(
    mangaId,
    categoryId,
    manga: manga,
    client: (isLoggedIn && !ConnectivityService.instance.isOffline)
        ? httpManager.client
        : null,
    baseUrl: _baseUrl,
    headers: auth.headers(withAuth: true),
  );

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
      client: (isLoggedIn && !ConnectivityService.instance.isOffline)
          ? httpManager.client
          : null,
      baseUrl: _baseUrl,
      headers: auth.headers(withAuth: true),
    );
  }

  /// Local-first progress lookup: merges both `completedChapters` and `lastRead`
  /// (with timestamp comparison) from the cloud, bounding foreground wait to 1.2s
  /// when local progress already exists.
  Future<Map<String, dynamic>> getMangaProgress(
    String mangaId, {
    bool forceCloudSync = false,
  }) async {
    final base = historyRepo.getMangaProgress(mangaId);
    if (!isLoggedIn || ConnectivityService.instance.isOffline) return base;

    Future<Map<String, dynamic>> fetchCloudProgress() async {
      try {
        final res = await httpManager.client
            .get(
              Uri.parse('$_baseUrl/progress/manga/$mangaId'),
              headers: auth.headers(withAuth: true),
            )
            .timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final rawCompleted = data['completedChapterIds'] is List
              ? data['completedChapterIds'] as List
              : (data['completedChapters'] is List
                    ? data['completedChapters'] as List
                    : null);
          if (rawCompleted != null) {
            final cloudCompleted = rawCompleted
                .map((e) => e.toString())
                .toList();
            await historyRepo.markChaptersRead(
              mangaId,
              cloudCompleted,
              read: true,
            );
          }
          if (data['lastRead'] is Map) {
            historyRepo.mergeRemoteHistory([data['lastRead']]);
          }
          return historyRepo.getMangaProgress(mangaId);
        }
      } catch (_) {}
      return historyRepo.getMangaProgress(mangaId);
    }

    final hasLocalProgress =
        base['lastRead'] != null ||
        ((base['completedChapters'] as List?)?.isNotEmpty ?? false);
    if (hasLocalProgress && !forceCloudSync) {
      await fetchCloudProgress().timeout(
        const Duration(milliseconds: 1200),
        onTimeout: () => historyRepo.getMangaProgress(mangaId),
      );
      return historyRepo.getMangaProgress(mangaId);
    }
    return fetchCloudProgress();
  }

  bool isChapterRead(String mangaId, String chapterId) =>
      historyRepo.isChapterRead(mangaId, chapterId);

  Set<String> getReadChapterIds(String mangaId) =>
      historyRepo.getReadChapterIds(mangaId);

  Future<void> markChapterRead(
    String mangaId,
    String chapterId, {
    bool read = true,
  }) => historyRepo.markChapterRead(
    mangaId,
    chapterId,
    read: read,
    client: (isLoggedIn && !ConnectivityService.instance.isOffline)
        ? httpManager.client
        : null,
    baseUrl: _baseUrl,
    headers: auth.headers(withAuth: true),
  );

  Future<void> markChaptersRead(
    String mangaId,
    List<String> chapterIds, {
    bool read = true,
  }) => historyRepo.markChaptersRead(
    mangaId,
    chapterIds,
    read: read,
    client: (isLoggedIn && !ConnectivityService.instance.isOffline)
        ? httpManager.client
        : null,
    baseUrl: _baseUrl,
    headers: auth.headers(withAuth: true),
  );

  void recordChapterCount(String mangaId, int count) =>
      historyRepo.recordChapterCount(mangaId, count);

  int getChapterCount(String mangaId) {
    final recorded = historyRepo.getChapterCount(mangaId);
    if (recorded > 0) return recorded;
    final cachedLen = libraryRepo.getCachedChapters(mangaId).length;
    if (cachedLen > 0) return cachedLen;
    return DownloadService.instance.getDownloadedCountForManga(mangaId);
  }

  int getUnreadCount(String mangaId) => historyRepo.getUnreadCount(mangaId);

  bool isChapterBookmarked(String chapterId) =>
      historyRepo.isChapterBookmarked(chapterId);

  Future<bool> toggleChapterBookmark(String chapterId) =>
      historyRepo.toggleChapterBookmark(
        chapterId,
        client: (isLoggedIn && !ConnectivityService.instance.isOffline)
            ? httpManager.client
            : null,
        baseUrl: _baseUrl,
        headers: auth.headers(withAuth: true),
      );

  Future<void> setChapterBookmarked(String chapterId, bool bookmarked) =>
      historyRepo.setChapterBookmarked(
        chapterId,
        bookmarked,
        client: (isLoggedIn && !ConnectivityService.instance.isOffline)
            ? httpManager.client
            : null,
        baseUrl: _baseUrl,
        headers: auth.headers(withAuth: true),
      );

  Future<void> migrateOrCopyReadingProgress({
    required String sourceMangaId,
    required MangaItem targetManga,
    List<ChapterItem> targetChapters = const [],
  }) async {
    final sourceProgress = historyRepo.localProgress[sourceMangaId];
    final sourceReadSet = historyRepo.readChapters[sourceMangaId];

    var chs = targetChapters;
    if (chs.isEmpty) {
      try {
        chs = await getChapters(targetManga.id);
      } catch (_) {}
    }

    double? parseNum(String? raw) {
      if (raw == null) return null;
      final trimmed = raw.trim();
      final direct = double.tryParse(trimmed);
      if (direct != null) return direct;
      final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(trimmed);
      if (match != null) return double.tryParse(match.group(1)!);
      return null;
    }

    final readChapterNumbers = <String>{};
    double? maxReadNum;

    if (sourceProgress != null) {
      final sNum = parseNum(sourceProgress.chapterNumber);
      if (sNum != null) maxReadNum = sNum;
      if (sourceProgress.chapterNumber.isNotEmpty) {
        readChapterNumbers.add(sourceProgress.chapterNumber.trim());
      }
    }

    for (final entry in historyRepo.localHistory) {
      if (entry.mangaId == sourceMangaId) {
        final numStr = entry.chapterNumber.trim();
        if (numStr.isNotEmpty) {
          readChapterNumbers.add(numStr);
          final parsed = parseNum(numStr);
          if (parsed != null && (maxReadNum == null || parsed > maxReadNum)) {
            maxReadNum = parsed;
          }
        }
      }
    }

    if (sourceReadSet != null && sourceReadSet.isNotEmpty) {
      try {
        final srcChs = await getChapters(sourceMangaId);
        for (final sc in srcChs) {
          if (sourceReadSet.contains(sc.id)) {
            final scNum = sc.number?.trim() ?? '';
            if (scNum.isNotEmpty) {
              readChapterNumbers.add(scNum);
              final parsed = parseNum(scNum);
              if (parsed != null &&
                  (maxReadNum == null || parsed > maxReadNum)) {
                maxReadNum = parsed;
              }
            }
          }
        }
      } catch (_) {}
    }

    if (chs.isNotEmpty) {
      final targetIdsToMark = <String>[];
      ChapterItem? bestMatchedProgressChapter;

      for (final ch in chs) {
        final chNum = ch.number?.trim() ?? '';
        final curNum = parseNum(chNum);

        final isRead =
            (curNum != null && maxReadNum != null && curNum <= maxReadNum) ||
            (chNum.isNotEmpty && readChapterNumbers.contains(chNum));

        if (isRead) {
          targetIdsToMark.add(ch.id);
        }

        if (sourceProgress != null) {
          final targetNum = parseNum(chNum);
          final progNum = parseNum(sourceProgress.chapterNumber);
          if (chNum == sourceProgress.chapterNumber ||
              (targetNum != null && progNum != null && targetNum == progNum)) {
            bestMatchedProgressChapter = ch;
          }
        }
      }

      if (targetIdsToMark.isEmpty &&
          sourceReadSet != null &&
          sourceReadSet.isNotEmpty) {
        targetIdsToMark.addAll(sourceReadSet);
      }

      if (targetIdsToMark.isNotEmpty) {
        await markChaptersRead(targetManga.id, targetIdsToMark, read: true);
      }

      if (sourceProgress != null) {
        final targetCh = bestMatchedProgressChapter;
        await saveProgress(
          mangaId: targetManga.id,
          chapterId: targetCh?.id ?? sourceProgress.chapterId,
          mangaTitle: targetManga.title,
          cover: targetManga.cover,
          chapterNumber: targetCh?.number ?? sourceProgress.chapterNumber,
          chapterTitle: targetCh?.title ?? sourceProgress.chapterTitle,
          page: sourceProgress.page,
          totalPages: sourceProgress.totalPages,
          completed: sourceProgress.completed,
        );
      }
    } else {
      if (sourceReadSet != null && sourceReadSet.isNotEmpty) {
        await markChaptersRead(
          targetManga.id,
          sourceReadSet.toList(),
          read: true,
        );
      }
      if (sourceProgress != null) {
        await saveProgress(
          mangaId: targetManga.id,
          chapterId: sourceProgress.chapterId,
          mangaTitle: targetManga.title,
          cover: targetManga.cover,
          chapterNumber: sourceProgress.chapterNumber,
          chapterTitle: sourceProgress.chapterTitle,
          page: sourceProgress.page,
          totalPages: sourceProgress.totalPages,
          completed: sourceProgress.completed,
        );
      }
    }
  }

  Set<String> getBookmarkedChapterIds() =>
      historyRepo.getBookmarkedChapterIds();

  /// Local-first history retrieval:
  /// - HistoryScreen renders `historyRepo.getHistoryEntries()` synchronously on Frame 0 (0ms).
  /// - When `getHistory()` is awaited, it waits up to 1.2s for cloud merge on fast connections
  ///   and falls back to local history immediately if the network is slow (>1.2s), completing
  ///   the cloud merge in the background!
  Future<List<Map<String, dynamic>>> getHistory({
    bool forceCloudSync = false,
  }) async {
    final localMaps = historyRepo.getHistoryAsMaps();
    if (isLoggedIn && !ConnectivityService.instance.isOffline) {
      Future<void> pullCloudHistory() async {
        try {
          await historyRepo.downloadAndMergeSyncData(
            httpManager.client,
            _baseUrl,
            auth.headers(withAuth: true),
          );
        } catch (_) {}
      }

      if (localMaps.isEmpty || forceCloudSync) {
        await pullCloudHistory();
      } else {
        await pullCloudHistory().timeout(
          const Duration(milliseconds: 1200),
          onTimeout: () {},
        );
      }
      return historyRepo.getHistoryAsMaps();
    }
    return localMaps;
  }

  List<ReadHistoryEntry> getHistoryEntries() => historyRepo.getHistoryEntries();

  Future<void> removeHistoryEntry(String chapterId) =>
      historyRepo.removeHistoryEntry(
        chapterId,
        client: (isLoggedIn && !ConnectivityService.instance.isOffline)
            ? httpManager.client
            : null,
        baseUrl: _baseUrl,
        headers: auth.headers(withAuth: true),
      );

  Future<void> clearHistory() => historyRepo.clearHistory(
    client: (isLoggedIn && !ConnectivityService.instance.isOffline)
        ? httpManager.client
        : null,
    baseUrl: _baseUrl,
    headers: auth.headers(withAuth: true),
  );

  // ---- Catalog Queries & Offline-Resilient Chapter / Metadata Caching ----

  Future<List<MangaItem>> searchManga({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
    String source = 'mangadex',
  }) => catalog.searchManga(
    query: query,
    type: type,
    order: order,
    page: page,
    limit: limit,
    source: source,
  );

  /// Fetches full manga details and persists them locally for library titles.
  /// If offline or network times out, gracefully returns cached local metadata if available.
  Future<MangaItem> getManga(String id) async {
    final localCached =
        libraryRepo.localLibrary[id] ?? libraryRepo.knownManga[id];
    if (ConnectivityService.instance.isOffline && localCached != null) {
      return localCached;
    }
    try {
      final fresh = await catalog.getManga(id);
      unawaited(libraryRepo.updateCachedMangaMetadata(fresh));
      return fresh;
    } catch (e) {
      if (localCached != null) {
        return localCached;
      }
      rethrow;
    }
  }

  /// Synchronously returns persisted local chapters for [mangaId], merged with any
  /// offline downloaded chapters from [DownloadService] so saved manga open in 0ms.
  List<ChapterItem> getCachedChapters(String mangaId) {
    final persisted = libraryRepo.getCachedChapters(mangaId);
    final downloaded = DownloadService.instance.getDownloadedChaptersForManga(
      mangaId,
    );
    if (persisted.isEmpty) return downloaded;
    if (downloaded.isEmpty) return persisted;

    final existingIds = persisted.map((c) => c.id).toSet();
    final merged = [...persisted];
    for (final d in downloaded) {
      if (!existingIds.contains(d.id)) {
        merged.add(d);
      }
    }
    return merged;
  }

  /// Fetches chapters for [mangaId], automatically persisting them to local storage
  /// and falling back to cached or downloaded chapters when offline or on slow/failed network.
  Future<List<ChapterItem>> getChapters(
    String mangaId, {
    String lang = 'en',
    bool forceRefresh = false,
  }) async {
    final cached = getCachedChapters(mangaId);
    if (!forceRefresh &&
        ConnectivityService.instance.isOffline &&
        cached.isNotEmpty) {
      return cached;
    }

    try {
      final chapters = await catalog.getChapters(
        mangaId,
        lang: lang,
        onChapterCount: recordChapterCount,
      );
      if (chapters.isNotEmpty) {
        unawaited(libraryRepo.cacheChapters(mangaId, chapters));
        return chapters;
      }
      if (cached.isNotEmpty) {
        return cached;
      }
      return chapters;
    } catch (e) {
      if (cached.isNotEmpty) {
        AppLogger.warn(
          'getChapters network failed for $mangaId; using ${cached.length} cached chapters',
          e,
        );
        return cached;
      }
      rethrow;
    }
  }

  Future<ChapterPages> getChapterPages(
    String chapterId, {
    bool forceRefresh = false,
  }) => catalog.getChapterPages(chapterId, forceRefresh: forceRefresh);

  /// Synchronously returns the last persisted updates feed for instant offline display.
  Map<String, dynamic> getCachedUpdates() =>
      libraryRepo.getCachedUpdatesPayload();

  Future<Map<String, dynamic>> getUpdates() async {
    final bookmarked = libraryRepo.getLibraryItems();
    if (bookmarked.isEmpty) {
      return {
        'groups': {'Today': [], 'Yesterday': [], 'Earlier': []},
        'items': [],
        'total': 0,
      };
    }

    final cached = libraryRepo.getCachedUpdatesPayload();
    if (ConnectivityService.instance.isOffline) {
      return cached;
    }

    try {
      final res = await catalog.getUpdates(
        bookmarked: bookmarked,
        authHeaders: isLoggedIn ? auth.headers(withAuth: true) : null,
      );
      final items = res['items'];
      if (items is List && items.isNotEmpty) {
        unawaited(libraryRepo.cacheUpdatesPayload(res));
        return res;
      }
    } catch (_) {}

    return cached;
  }

  Future<int> checkForLibraryUpdates() async {
    if (ConnectivityService.instance.isOffline) return 0;
    final library = libraryRepo.getLibraryItems();
    if (library.isEmpty) return 0;

    // Skip completed titles to save bandwidth on slow connections
    final activeLibrary = library.where((m) {
      final st = m.status.trim().toLowerCase();
      return !st.contains('completed') && !st.contains('complete');
    }).toList();

    final targets = activeLibrary.isNotEmpty ? activeLibrary : library;

    int newChaptersCount = 0;
    for (var i = 0; i < targets.length; i += 4) {
      final chunk = targets.skip(i).take(4);
      await Future.wait(
        chunk.map((manga) async {
          try {
            final oldCount = historyRepo.getChapterCount(manga.id);
            final chapters = await getChapters(manga.id);
            if (oldCount > 0 && chapters.length > oldCount) {
              newChaptersCount += (chapters.length - oldCount);
            }
          } catch (_) {}
        }),
      );
    }
    notifyListeners();
    return newChaptersCount;
  }

  bool _isAutoRefreshing = false;
  bool get isAutoRefreshing => _isAutoRefreshing;
  DateTime? _lastAutoRefresh;
  DateTime? _lastLibraryChapterCheck;

  /// High-performance automated refresh:
  /// - Immediately skips network polling when offline.
  /// - Synchronizes lightweight cloud state (throttled to min 45s).
  /// - Throttles heavy full-library chapter scraping to once every 15 minutes
  ///   (unless `force: true`) so slow internet connections are never saturated!
  Future<void> autoRefreshEverything({bool force = false}) async {
    if (ConnectivityService.instance.isOffline) return;
    final now = DateTime.now();
    if (_isAutoRefreshing) return;
    if (!force &&
        _lastAutoRefresh != null &&
        now.difference(_lastAutoRefresh!) < const Duration(seconds: 45)) {
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

      // 2. Heavy background library chapter update check only when forced or >= 15 mins elapsed
      final shouldScrapeChapters =
          force ||
          _lastLibraryChapterCheck == null ||
          now.difference(_lastLibraryChapterCheck!) >=
              const Duration(minutes: 15);
      if (shouldScrapeChapters) {
        _lastLibraryChapterCheck = now;
        await checkForLibraryUpdates();
      }

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

  // ---- Complete Backup & Restore (v2 with Categories, Read Marks, Bookmarks & Chapters) ----

  Future<String> exportBackupJson() async {
    final installed = ExtensionService.instance.installedPackages.toList();
    final backup = {
      'version': 2,
      'app': 'Shiori',
      'exportedAt': DateTime.now().toIso8601String(),
      'bookmarksCount': libraryRepo.localLibrary.length,
      'historyCount': historyRepo.localHistory.length,
      'library': libraryRepo.localLibrary.values
          .map((e) => e.toJson())
          .toList(),
      'categories': libraryRepo.userCategories.map((c) => c.toJson()).toList(),
      'mangaCategories': libraryRepo.mangaCategories,
      'history': historyRepo.getHistoryAsMaps(),
      'progress': {
        for (final e in historyRepo.localProgress.entries)
          e.key: e.value.toMap(),
      },
      'readChapters': {
        for (final e in historyRepo.readChapters.entries)
          e.key: e.value.toList(),
      },
      'chapterBookmarks': historyRepo.bookmarkedChapterIds.toList(),
      'cachedChapters': {
        for (final e in libraryRepo.localChapters.entries)
          if (libraryRepo.isInLibrary(e.key))
            e.key: e.value.map((c) => c.toJson()).toList(),
      },
      'installedSources': installed,
    };
    return const JsonEncoder.withIndent('  ').convert(backup);
  }

  Future<Map<String, int>> restoreBackupJson(String jsonString) async {
    final Map<String, dynamic> data =
        jsonDecode(jsonString.trim()) as Map<String, dynamic>;
    int restoredBookmarks = 0;
    int restoredHistory = 0;
    int restoredCategories = 0;

    if (data['categories'] is List) {
      final existingIds = libraryRepo.getCategories().map((c) => c.id).toSet();
      for (final item in data['categories'] as List) {
        if (item is Map) {
          final cat = CategoryItem.fromJson(Map<String, dynamic>.from(item));
          if (cat.name.isNotEmpty && !existingIds.contains(cat.id)) {
            final existingByName = libraryRepo
                .getCategories()
                .where((c) => c.name.toLowerCase() == cat.name.toLowerCase())
                .firstOrNull;
            if (existingByName == null) {
              await libraryRepo.createCategory(cat.name);
              restoredCategories++;
            }
          }
        }
      }
    }

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

    if (data['mangaCategories'] is Map) {
      final map = data['mangaCategories'] as Map;
      map.forEach((mangaId, cats) {
        if (mangaId is String && cats is List) {
          final catIds = cats.map((e) => e.toString()).toList();
          if (catIds.isNotEmpty) {
            unawaited(libraryRepo.setMangaCategories(mangaId, catIds));
          }
        }
      });
    }

    if (data['readChapters'] is Map) {
      final map = data['readChapters'] as Map;
      for (final entry in map.entries) {
        final mangaId = entry.key.toString();
        if (mangaId.isNotEmpty && entry.value is List) {
          final chIds = (entry.value as List).map((e) => e.toString()).toList();
          if (chIds.isNotEmpty) {
            await historyRepo.markChaptersRead(mangaId, chIds, read: true);
          }
        }
      }
    }

    if (data['chapterBookmarks'] is List) {
      for (final chId in data['chapterBookmarks'] as List) {
        final idStr = chId?.toString() ?? '';
        if (idStr.isNotEmpty) {
          await historyRepo.setChapterBookmarked(idStr, true);
        }
      }
    }

    if (data['cachedChapters'] is Map) {
      final map = data['cachedChapters'] as Map;
      for (final entry in map.entries) {
        final mangaId = entry.key.toString();
        if (mangaId.isNotEmpty && entry.value is List) {
          final chs = <ChapterItem>[];
          for (final raw in entry.value as List) {
            if (raw is Map) {
              final ch = ChapterItem.fromJson(Map<String, dynamic>.from(raw));
              if (ch.id.isNotEmpty) chs.add(ch);
            }
          }
          if (chs.isNotEmpty) {
            await libraryRepo.cacheChapters(mangaId, chs);
            recordChapterCount(mangaId, chs.length);
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
      final exts = (data['installedSources'] as List)
          .map((e) => e.toString())
          .toList();
      for (final pkg in exts) {
        await ExtensionService.instance.installPackageByNameOrId(pkg);
      }
    }

    if (isLoggedIn && !ConnectivityService.instance.isOffline) {
      unawaited(syncAllCloudData());
    }

    notifyListeners();
    return {
      'bookmarks': restoredBookmarks,
      'history': restoredHistory,
      'categories': restoredCategories,
    };
  }

  // ---- Cache Eviction (#10) ----

  Future<void> clearAllCaches() async {
    httpManager.clearCache();
    _flame.clearCache();

    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    try {
      await DefaultCacheManager().emptyCache().timeout(
        const Duration(milliseconds: 600),
      );
    } catch (e) {
      AppLogger.warn('DefaultCacheManager emptyCache error', e);
    }

    AppLogger.info('Cleared all image, network, and in-memory caches');
  }

  Map<String, String> getHeadersForUrl(String url) => imageHeadersForUrl(url);
}
