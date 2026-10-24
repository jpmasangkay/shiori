import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga_models.dart';
import '../widgets/common.dart';
import 'download_service.dart';
import 'extension_bridge.dart';
import 'extension_service.dart';

class ApiService extends ChangeNotifier {
  static final ApiService instance = ApiService._();
  ApiService._();

  String _baseUrl = '';
  String? _token;
  UserAccount? _currentUser;
  bool _initialized = false;
  bool _mongoConnected = false;
  final Map<String, MangaItem> _localLibrary = {};
  final List<Map<String, dynamic>> _localHistory = [];
  final Map<String, Map<String, dynamic>> _localProgress = {};
  final Map<String, Set<String>> _readChapters = {};
  final Set<String> _bookmarkedChapterIds = {};
  final List<CategoryItem> _userCategories = [];
  final Map<String, List<String>> _mangaCategories = {};
  final Map<String, int> _mangaChapterCounts = {};

  String get baseUrl => _baseUrl;
  String? get token => _token;
  UserAccount? get currentUser => _currentUser;
  bool get isLoggedIn => _token != null && _currentUser != null;
  bool get isMongoConnected => _mongoConnected;

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static String _inferSourceFromId(String id, [String? explicitSource]) {
    if (explicitSource != null && explicitSource.isNotEmpty) return explicitSource;
    if (id.startsWith('asura:')) return 'asura';
    if (id.startsWith('flame:')) return 'flamecomics';
    if (id.startsWith('weeb:')) return 'weebcentral';
    if (id.startsWith('pill:')) return 'mangapill';
    if (id.startsWith('katana:')) return 'mangakatana';
    if (id.startsWith('mread:')) return 'mangaread';
    if (id.startsWith('ext:')) {
      final parts = id.split(':');
      return parts.length > 1 ? parts[1] : 'extension';
    }
    if (id.startsWith('mangadex:') || _uuidPattern.hasMatch(id)) return 'mangadex';
    return 'unknown';
  }

  String _determineDefaultHost() {
    return 'https://shiori-n5hd.onrender.com/api';
  }

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final savedBase = prefs.getString('api_base_url');
    _baseUrl = savedBase ?? _determineDefaultHost();

    _token = prefs.getString('auth_token');
    final userJson = prefs.getString('auth_user');
    if (userJson != null) {
      try {
        _currentUser = UserAccount.fromJson(jsonDecode(userJson) as Map<String, dynamic>);
      } catch (_) {}
    }

    // Load local library / bookmarks
    final libJson = prefs.getString('shiori_local_library');
    if (libJson != null && libJson.isNotEmpty) {
      try {
        final List<dynamic> list = jsonDecode(libJson);
        for (final item in list) {
          final m = MangaItem.fromJson(item as Map<String, dynamic>);
          _localLibrary[m.id] = m;
        }
      } catch (_) {}
    }

    // Load local history
    final histJson = prefs.getString('shiori_local_history');
    if (histJson != null && histJson.isNotEmpty) {
      try {
        final List<dynamic> list = jsonDecode(histJson);
        _localHistory.clear();
        for (final item in list) {
          if (item is Map) _localHistory.add(Map<String, dynamic>.from(item));
        }
      } catch (_) {}
    }

    // Load local progress
    final progJson = prefs.getString('shiori_local_progress');
    if (progJson != null && progJson.isNotEmpty) {
      try {
        final Map<String, dynamic> map = jsonDecode(progJson);
        _localProgress.clear();
        map.forEach((k, v) {
          if (v is Map) _localProgress[k] = Map<String, dynamic>.from(v);
        });
      } catch (_) {}
    }

    // Load read chapters
    final readJson = prefs.getString('shiori_read_chapters');
    if (readJson != null && readJson.isNotEmpty) {
      try {
        final Map<String, dynamic> map = jsonDecode(readJson);
        _readChapters.clear();
        map.forEach((k, v) {
          if (v is List) {
            _readChapters[k] = v.map((e) => e.toString()).toSet();
          }
        });
      } catch (_) {}
    }

    // Load chapter bookmarks
    final bmJson = prefs.getString('shiori_chapter_bookmarks');
    if (bmJson != null && bmJson.isNotEmpty) {
      try {
        final List<dynamic> list = jsonDecode(bmJson);
        _bookmarkedChapterIds.clear();
        for (final item in list) {
          _bookmarkedChapterIds.add(item.toString());
        }
      } catch (_) {}
    }

    // Load user categories
    final catJson = prefs.getString('shiori_user_categories');
    _userCategories.clear();
    if (catJson != null && catJson.isNotEmpty) {
      try {
        final List<dynamic> list = jsonDecode(catJson);
        for (final item in list) {
          if (item is Map) {
            _userCategories.add(CategoryItem.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      } catch (_) {}
    }
    if (_userCategories.isEmpty) {
      _userCategories.addAll(const [
        CategoryItem(id: 'reading', name: 'Reading', order: 0),
        CategoryItem(id: 'completed', name: 'Completed', order: 1),
        CategoryItem(id: 'plan_to_read', name: 'Plan to Read', order: 2),
        CategoryItem(id: 'favorites', name: 'Favorites', order: 3),
      ]);
    }

    // Load manga categories mapping
    final mangaCatJson = prefs.getString('shiori_manga_categories');
    if (mangaCatJson != null && mangaCatJson.isNotEmpty) {
      try {
        final Map<String, dynamic> map = jsonDecode(mangaCatJson);
        _mangaCategories.clear();
        map.forEach((k, v) {
          if (v is List) {
            _mangaCategories[k] = v.map((e) => e.toString()).toList();
          }
        });
      } catch (_) {}
    }

    // Load manga chapter counts for unread badges
    final chapterCountsJson = prefs.getString('shiori_manga_chapter_counts');
    if (chapterCountsJson != null && chapterCountsJson.isNotEmpty) {
      try {
        final Map<String, dynamic> map = jsonDecode(chapterCountsJson);
        _mangaChapterCounts.clear();
        map.forEach((k, v) {
          if (v is num) _mangaChapterCounts[k] = v.toInt();
        });
      } catch (_) {}
    }

    _initialized = true;
    checkHealth();
    if (isLoggedIn) {
      syncAllCloudData();
    }
  }

  Future<void> _persistLocalLibrary() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _localLibrary.values.map((e) => e.toJson()).toList();
      await prefs.setString('shiori_local_library', jsonEncode(list));
    } catch (_) {}
  }

  Future<void> _persistLocalHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('shiori_local_history', jsonEncode(_localHistory));
    } catch (_) {}
  }

  Future<void> _persistLocalProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('shiori_local_progress', jsonEncode(_localProgress));
    } catch (_) {}
  }

  Future<void> _persistReadChapters() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = <String, List<String>>{
        for (final entry in _readChapters.entries) entry.key: entry.value.toList(),
      };
      await prefs.setString('shiori_read_chapters', jsonEncode(map));
    } catch (_) {}
  }

  Future<void> _persistChapterBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('shiori_chapter_bookmarks', jsonEncode(_bookmarkedChapterIds.toList()));
    } catch (_) {}
  }

  Future<void> _persistUserCategories() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _userCategories.map((e) => e.toJson()).toList();
      await prefs.setString('shiori_user_categories', jsonEncode(list));
    } catch (_) {}
  }

  Future<void> _persistMangaCategories() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('shiori_manga_categories', jsonEncode(_mangaCategories));
    } catch (_) {}
  }

  Future<void> _persistChapterCounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('shiori_manga_chapter_counts', jsonEncode(_mangaChapterCounts));
    } catch (_) {}
  }

  void recordChapterCount(String mangaId, int count) {
    if (count > 0 && (_mangaChapterCounts[mangaId] ?? 0) < count) {
      _mangaChapterCounts[mangaId] = count;
      _persistChapterCounts();
      notifyListeners();
    }
  }

  int getUnreadCount(String mangaId) {
    final total = _mangaChapterCounts[mangaId] ?? 0;
    final read = _readChapters[mangaId]?.length ?? 0;
    final diff = total - read;
    return diff > 0 ? diff : 0;
  }

  Map<String, String> getHeadersForUrl(String url) => imageHeadersForUrl(url);

  Future<void> setBaseUrl(String url) async {
    var cleaned = url.trim();
    if (cleaned.endsWith('/')) cleaned = cleaned.substring(0, cleaned.length - 1);
    if (!cleaned.endsWith('/api')) cleaned = '$cleaned/api';
    _baseUrl = cleaned;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', _baseUrl);
    await checkHealth();
    notifyListeners();
  }

  Map<String, String> _headers({bool withAuth = true}) {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (withAuth && _token != null) {
      h['Authorization'] = 'Bearer $_token';
    }
    return h;
  }

  Future<bool> checkHealth() async {
    try {
      final res = await http.get(Uri.parse('$_baseUrl/health')).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        _mongoConnected = data['database'] == 'connected';
        notifyListeners();
        return true;
      }
    } catch (_) {
      _mongoConnected = false;
      notifyListeners();
    }
    return false;
  }

  // ---- Auth & Automatic Real-Time Cloud Sync ----

  Future<void> register(String email, String password, {String? displayName}) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/auth/register'),
      headers: _headers(withAuth: false),
      body: jsonEncode({
        'email': email,
        'password': password,
        if (displayName != null && displayName.isNotEmpty) 'displayName': displayName,
      }),
    );

    if (res.statusCode != 200 && res.statusCode != 201) {
      final err = jsonDecode(res.body);
      throw Exception(err['error'] ?? 'Registration failed');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    await _saveAuthData(data['token'] as String, UserAccount.fromJson(data['user']));
    // Automatically bi-directionally sync library and reading history with MongoDB
    await syncAllCloudData();
  }

  Future<void> login(String email, String password) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/auth/login'),
      headers: _headers(withAuth: false),
      body: jsonEncode({'email': email, 'password': password}),
    );

    if (res.statusCode != 200) {
      final err = jsonDecode(res.body);
      throw Exception(err['error'] ?? 'Login failed');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    await _saveAuthData(data['token'] as String, UserAccount.fromJson(data['user']));
    // Automatically bi-directionally sync library and reading history with MongoDB
    await syncAllCloudData();
  }

  Future<void> logout() async {
    _token = null;
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('auth_user');
    notifyListeners();
  }

  Future<void> _saveAuthData(String token, UserAccount user) async {
    _token = token;
    _currentUser = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
    await prefs.setString('auth_user', jsonEncode({'id': user.id, 'email': user.email, 'displayName': user.displayName}));
    notifyListeners();
  }

  /// Complete 2-way automatic cloud sync:
  /// 1. Uploads any local bookmarks or progress made in guest mode to MongoDB
  /// 2. Downloads all user bookmarks & progress from MongoDB so they appear seamlessly on this device/browser
  /// Zero manual backups or JSON file exports needed!
  Future<void> syncAllCloudData() async {
    if (!isLoggedIn) return;

    // 1. Upload any local library bookmarks to cloud
    for (final manga in _localLibrary.values) {
      try {
        await http.post(
          Uri.parse('$_baseUrl/library'),
          headers: _headers(withAuth: true),
          body: jsonEncode({
            'mangaId': manga.id,
            'title': manga.title,
            'cover': manga.cover,
            'type': manga.type,
            'status': manga.status,
            'latestChapter': manga.lastChapter ?? '',
          }),
        ).timeout(const Duration(seconds: 4));
      } catch (_) {}
    }

    // 2. Fetch all cloud bookmarks and merge into local library
    try {
      final res = await http.get(
        Uri.parse('$_baseUrl/library'),
        headers: _headers(withAuth: true),
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['items'] as List<dynamic>?) ?? [];
        for (final e in list) {
          final id = e['mangaId']?.toString() ?? e['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          final source = _inferSourceFromId(id, e['source']?.toString());
          final m = MangaItem(
            id: id,
            title: e['title']?.toString() ?? 'Untitled',
            cover: e['cover']?.toString() ?? '',
            type: e['type']?.toString() ?? 'manga',
            status: e['status']?.toString() ?? '',
            lastChapter: e['latestChapter']?.toString() ?? '',
            source: source,
          );
          _localLibrary[m.id] = m;
        }
        await _persistLocalLibrary();
      }
    } catch (_) {}

    // 3. Fetch cloud reading history & progress and merge into local state
    try {
      final res = await http.get(
        Uri.parse('$_baseUrl/progress/history'),
        headers: _headers(withAuth: true),
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = data['items'] as List<dynamic>? ?? [];
        for (final item in list) {
          if (item is Map) {
            final map = Map<String, dynamic>.from(item);
            final mangaId = map['mangaId'] as String? ?? '';
            if (mangaId.isNotEmpty) {
              _localProgress[mangaId] = map;
              if (!_localHistory.any((h) => h['mangaId'] == mangaId)) {
                _localHistory.add(map);
              }
            }
          }
        }
        await _persistLocalHistory();
        await _persistLocalProgress();
      }
    } catch (_) {}

    notifyListeners();
  }

  // ---- Multi-Source Manga Catalog (MangaDex & Asura Scans) ----

  Future<List<MangaItem>> searchManga({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
    String source = 'mangadex',
  }) async {
    final s = source.toLowerCase().trim();

    // 1. Built-in direct web scrapers (ONLY for explicit built-in sources)
    if (s == 'flamecomics' || s == 'flame') {
      return _searchFlameComics(query: query, type: type, page: page, limit: limit);
    }
    if (s == 'weebcentral' || s == 'weeb') {
      return _searchWeebCentral(query: query, type: type, page: page, limit: limit);
    }
    if (s == 'mangapill' || s == 'pill') {
      return _searchMangaPill(query: query, type: type, page: page, limit: limit);
    }
    if (s == 'mangakatana' || s == 'katana') {
      return _searchMangaKatana(query: query, type: type, page: page, limit: limit);
    }
    if (s == 'mangaread' || s == 'mread') {
      return _searchMangaRead(query: query, type: type, page: page, limit: limit);
    }
    if (s == 'asura') {
      return _searchAsura(query: query, type: type, page: page);
    }

    // 2. MangaDex API (ONLY if explicitly mangadex)
    if (s == 'mangadex') {
      return _searchMangaCatalog(
        query: query,
        type: type,
        order: order,
        page: page,
        limit: limit,
      );
    }

    // 3. Tachiyomi Extension (Plan A: Native Android Dex execution bridge)
    String pkg = source;
    if (pkg.startsWith('ext:')) {
      final parts = pkg.split(':');
      if (parts.length > 1 && parts[1].isNotEmpty) {
        pkg = parts[1];
      }
    }

    final ext = ExtensionService.instance.getExtensionByPkg(pkg);
    final effectivePkg = ext?.pkg ?? pkg;

    try {
      final results = (query != null && query.trim().isNotEmpty)
          ? await ExtensionBridge.instance.searchManga(
              pkg: effectivePkg,
              query: query.trim(),
              page: page,
              type: type,
            )
          : await ExtensionBridge.instance.fetchPopularManga(
              pkg: effectivePkg,
              page: page,
              type: type,
            );

      if (results.isNotEmpty) return results;
    } catch (e) {
      debugPrint('ExtensionBridge native execution for $effectivePkg encountered: $e');
      if (ext != null && ext.homeUrl.isNotEmpty) {
        final webResults = await _searchWebManga(ext, query: query, page: page, limit: limit);
        if (webResults.isNotEmpty) return webResults;
      }
      return [];
    }

    // Secondary fallback to web scraper ONLY if homeUrl is present
    if (ext != null && ext.homeUrl.isNotEmpty) {
      return _searchWebManga(ext, query: query, page: page, limit: limit);
    }

    // Never fallback to MangaDex or Asura! Return empty list.
    return [];
  }

  Future<MangaItem> getManga(String id) async {
    if (id.startsWith('asura:')) return _getAsuraManga(id);
    if (id.startsWith('flame:')) return _getFlameManga(id);
    if (id.startsWith('weeb:')) return _getWeebManga(id);
    if (id.startsWith('pill:')) return _getMangaPill(id);
    if (id.startsWith('katana:')) return _getMangaKatana(id);
    if (id.startsWith('mread:')) return _getMangaRead(id);

    if (id.startsWith('ext:')) {
      final firstColon = id.indexOf(':');
      final secondColon = id.indexOf(':', firstColon + 1);
      final pkg = secondColon != -1 ? id.substring(firstColon + 1, secondColon) : id.substring(firstColon + 1);
      final actualId = secondColon != -1 ? id.substring(secondColon + 1) : id;
      final rawUrl = Uri.decodeComponent(actualId);

      try {
        return await ExtensionBridge.instance.fetchMangaDetails(pkg: pkg, url: rawUrl);
      } catch (e) {
        debugPrint('ExtensionBridge fetchMangaDetails failed for $pkg ($rawUrl): $e');
        final ext = ExtensionService.instance.getExtensionByPkg(pkg);
        if (ext != null && ext.homeUrl.isNotEmpty) {
          return _getWebManga(pkg, actualId, ext: ext);
        }
        rethrow;
      }
    }

    if (id.startsWith('mangadex:')) {
      return _getMangaById(id.substring('mangadex:'.length));
    }
    if (_uuidPattern.hasMatch(id)) {
      return _getMangaById(id);
    }

    // Strict no-fallback policy: do NOT fallback to MangaDex or any other source!
    throw Exception('Unknown or unsupported manga source for ID: $id');
  }

  Future<List<ChapterItem>> getChapters(String mangaId, {String lang = 'en'}) async {
    final chapters = await _getChaptersInternal(mangaId, lang: lang);
    if (chapters.isNotEmpty) {
      recordChapterCount(mangaId, chapters.length);
    }
    return chapters;
  }

  Future<List<ChapterItem>> _getChaptersInternal(String mangaId, {String lang = 'en'}) async {
    if (mangaId.startsWith('asura:')) return _getAsuraChapters(mangaId);
    if (mangaId.startsWith('flame:')) return _getFlameChapters(mangaId);
    if (mangaId.startsWith('weeb:')) return _getWeebChapters(mangaId);
    if (mangaId.startsWith('pill:')) return _getMangaPillChapters(mangaId);
    if (mangaId.startsWith('katana:')) return _getMangaKatanaChapters(mangaId);
    if (mangaId.startsWith('mread:')) return _getMangaReadChapters(mangaId);

    if (mangaId.startsWith('ext:')) {
      final firstColon = mangaId.indexOf(':');
      final secondColon = mangaId.indexOf(':', firstColon + 1);
      final pkg = secondColon != -1 ? mangaId.substring(firstColon + 1, secondColon) : mangaId.substring(firstColon + 1);
      final actualId = secondColon != -1 ? mangaId.substring(secondColon + 1) : mangaId;
      final rawUrl = Uri.decodeComponent(actualId);

      try {
        final chapters = await ExtensionBridge.instance.fetchChapterList(pkg: pkg, url: rawUrl);
        if (chapters.isNotEmpty) return chapters;
      } catch (e) {
        debugPrint('ExtensionBridge fetchChapterList failed for $pkg ($rawUrl): $e');
        final ext = ExtensionService.instance.getExtensionByPkg(pkg);
        if (ext != null && ext.homeUrl.isNotEmpty) {
          return _getWebChapters(pkg, actualId, ext: ext);
        }
        return [];
      }

      final ext = ExtensionService.instance.getExtensionByPkg(pkg);
      if (ext != null && ext.homeUrl.isNotEmpty) {
        return _getWebChapters(pkg, actualId, ext: ext);
      }

      return [];
    }

    if (mangaId.startsWith('mangadex:')) {
      return _getChaptersById(mangaId.substring('mangadex:'.length), lang: lang);
    }
    if (_uuidPattern.hasMatch(mangaId)) {
      return _getChaptersById(mangaId, lang: lang);
    }

    // Strict no-fallback policy: return empty list rather than querying MangaDex.
    return [];
  }

  Future<ChapterPages> getChapterPages(String chapterId) async {
    // 1. Check offline downloaded pages first
    if (DownloadService.instance.isChapterDownloaded(chapterId)) {
      final files = await DownloadService.instance.getDownloadedPages(chapterId);
      if (files.isNotEmpty) {
        final localUrls = files.map((f) => 'file://${f.path}').toList();
        return ChapterPages(
          chapterId: chapterId,
          pages: localUrls,
          dataSaver: localUrls,
        );
      }
    }

    if (chapterId.startsWith('asura:')) return _getAsuraChapterPages(chapterId);
    if (chapterId.startsWith('flame:')) return _getFlameChapterPages(chapterId);
    if (chapterId.startsWith('weeb:')) return _getWeebChapterPages(chapterId);
    if (chapterId.startsWith('pill:')) return _getMangaPillChapterPages(chapterId);
    if (chapterId.startsWith('katana:')) return _getMangaKatanaChapterPages(chapterId);
    if (chapterId.startsWith('mread:')) return _getMangaReadChapterPages(chapterId);

    if (chapterId.startsWith('ext:')) {
      final firstColon = chapterId.indexOf(':');
      final secondColon = chapterId.indexOf(':', firstColon + 1);
      final pkg = secondColon != -1 ? chapterId.substring(firstColon + 1, secondColon) : '';
      final actualChapterId = secondColon != -1 ? chapterId.substring(secondColon + 1) : chapterId;
      final rawUrl = Uri.decodeComponent(actualChapterId);

      try {
        final pageUrls = await ExtensionBridge.instance.fetchPageList(pkg: pkg, chapterUrl: rawUrl);
        if (pageUrls.isNotEmpty) {
          return ChapterPages(
            chapterId: chapterId,
            pages: pageUrls,
            dataSaver: pageUrls,
          );
        }
      } catch (e) {
        debugPrint('ExtensionBridge fetchPageList failed for $pkg ($rawUrl): $e');
        final ext = ExtensionService.instance.getExtensionByPkg(pkg);
        if (ext != null && ext.homeUrl.isNotEmpty) {
          return _getWebChapterPages(pkg, actualChapterId, ext: ext);
        }
        rethrow;
      }

      final ext = ExtensionService.instance.getExtensionByPkg(pkg);
      if (ext != null && ext.homeUrl.isNotEmpty) {
        return _getWebChapterPages(pkg, actualChapterId, ext: ext);
      }

      throw Exception('Chapter reader not available for $pkg');
    }

    if (chapterId.startsWith('mangadex:')) {
      return _getChapterPagesById(chapterId.substring('mangadex:'.length));
    }
    if (_uuidPattern.hasMatch(chapterId)) {
      return _getChapterPagesById(chapterId);
    }

    // Strict no-fallback policy: throw Exception rather than querying MangaDex.
    throw Exception('Unknown or unsupported chapter source for ID: $chapterId');
  }

  Future<List<MangaItem>> _searchMangaCatalog({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
    String? lang,
  }) async {
    // 1. Try Backend
    try {
      final qParams = <String, String>{
        if (query != null && query.isNotEmpty) 'q': query,
        if (type != null && type.isNotEmpty && type != 'all') 'type': type,
        'order': order,
        'page': page.toString(),
        'limit': limit.toString(),
        if (lang != null && lang.isNotEmpty && lang.toLowerCase() != 'all') 'lang': lang.toLowerCase(),
      };
      final uri = Uri.parse('$_baseUrl/manga/search').replace(queryParameters: qParams);
      final res = await http.get(uri, headers: _headers(withAuth: false)).timeout(const Duration(seconds: 7));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['items'] as List<dynamic>?) ?? [];
        if (list.isNotEmpty) {
          return list.map((e) => MangaItem.fromJson(e as Map<String, dynamic>)).toList();
        }
      }
    } catch (_) {}

    // 2. Direct Fallback to MangaDex API with User-Agent
    try {
      final qParams = <String, String>{
        'limit': limit.clamp(1, 50).toString(),
        'offset': ((page - 1) * limit).toString(),
        'includes[]': 'cover_art',
        'hasAvailableChapters': 'true',
      };
      if (query != null && query.isNotEmpty) {
        qParams['title'] = query;
        qParams['order[relevance]'] = 'desc';
      } else if (order == 'popular') {
        qParams['order[followedCount]'] = 'desc';
      } else if (order == 'latest') {
        qParams['order[latestUploadedChapter]'] = 'desc';
      } else if (order == 'rating') {
        qParams['order[rating]'] = 'desc';
      } else {
        qParams['order[createdAt]'] = 'desc';
      }

      if (type == 'manhwa') {
        qParams['originalLanguage[]'] = 'ko';
      } else if (type == 'manhua') {
        qParams['originalLanguage[]'] = 'zh';
      } else if (type == 'manga') {
        qParams['originalLanguage[]'] = 'ja';
      }

      if (lang != null && lang.isNotEmpty && lang.toLowerCase() != 'all') {
        qParams['availableTranslatedLanguage[]'] = lang.toLowerCase();
      } else {
        qParams['availableTranslatedLanguage[]'] = 'en';
      }

      final uri = Uri.parse('https://api.mangadex.org/manga').replace(queryParameters: qParams);
      final res = await http.get(
        uri,
        headers: {'User-Agent': 'ShioriApp/1.0', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['data'] as List<dynamic>?) ?? [];
        return list.map((m) => _normalizeDirectManga(m as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      debugPrint('_searchMangaCatalog direct fallback error: $e');
    }

    return [];
  }

  Future<MangaItem> _getMangaById(String actualId) async {
    // 1. Try Backend
    try {
      final res = await http.get(Uri.parse('$_baseUrl/manga/$actualId'), headers: _headers(withAuth: false)).timeout(const Duration(seconds: 7));
      if (res.statusCode == 200) {
        return MangaItem.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
    } catch (_) {}

    // 2. Direct Fallback
    try {
      final res = await http.get(
        Uri.parse('https://api.mangadex.org/manga/$actualId?includes[]=cover_art&includes[]=author&includes[]=artist'),
        headers: {'User-Agent': 'ShioriApp/1.0', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final m = data['data'] as Map<String, dynamic>? ?? {};
        return _normalizeDirectManga(m);
      }
    } catch (_) {}

    throw Exception('Failed to load manga details');
  }

  Future<List<ChapterItem>> _getChaptersById(String actualId, {String lang = 'en'}) async {
    // 1. Try Backend
    try {
      final uri = Uri.parse('$_baseUrl/manga/$actualId/chapters').replace(queryParameters: {
        if (lang.isNotEmpty) 'lang': lang,
      });
      final res = await http.get(uri, headers: _headers(withAuth: false)).timeout(const Duration(seconds: 7));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['chapters'] as List<dynamic>?) ?? [];
        return list.map((e) => ChapterItem.fromJson(e as Map<String, dynamic>)).toList();
      }
    } catch (_) {}

    // 2. Direct Fallback
    try {
      final qParams = <String, String>{
        'limit': '100',
        'order[chapter]': 'desc',
        'contentRating[]': 'safe',
        'includes[]': 'scanlation_group',
      };
      if (lang.isNotEmpty && lang != 'all') {
        qParams['translatedLanguage[]'] = lang;
      }
      final uri = Uri.parse('https://api.mangadex.org/manga/$actualId/feed').replace(queryParameters: qParams);
      final res = await http.get(
        uri,
        headers: {'User-Agent': 'ShioriApp/1.0', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['data'] as List<dynamic>?) ?? [];
        return list.map((c) {
          final a = c['attributes'] as Map<String, dynamic>? ?? {};
          final rels = (c['relationships'] as List<dynamic>?) ?? [];
          final grpRel = rels.firstWhere((r) => r['type'] == 'scanlation_group', orElse: () => null);
          final groupName = grpRel != null && grpRel['attributes'] != null ? grpRel['attributes']['name']?.toString() ?? '' : '';
          return ChapterItem(
            id: c['id']?.toString() ?? '',
            number: a['chapter']?.toString(),
            volume: a['volume']?.toString(),
            title: a['title']?.toString() ?? '',
            pages: (a['pages'] as num?)?.toInt() ?? 0,
            group: groupName,
            publishAt: a['publishAt']?.toString() ?? a['readableAt']?.toString(),
            source: 'mangadex',
          );
        }).toList();
      }
    } catch (_) {}

    return [];
  }

  Future<ChapterPages> _getChapterPagesById(String actualChapterId) async {
    // 1. Try Backend
    try {
      final res = await http.get(Uri.parse('$_baseUrl/manga/chapter/$actualChapterId/pages'), headers: _headers(withAuth: false)).timeout(const Duration(seconds: 7));
      if (res.statusCode == 200) {
        return ChapterPages.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
    } catch (_) {}

    // 2. Direct Fallback
    try {
      final res = await http.get(
        Uri.parse('https://api.mangadex.org/at-home/server/$actualChapterId'),
        headers: {'User-Agent': 'ShioriApp/1.0', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final baseUrl = data['baseUrl']?.toString() ?? 'https://uploads.mangadex.org';
        final chapterObj = data['chapter'] as Map<String, dynamic>? ?? {};
        final hash = chapterObj['hash']?.toString() ?? '';
        final dataList = (chapterObj['data'] as List<dynamic>?) ?? [];
        final dataSaverList = (chapterObj['dataSaver'] as List<dynamic>?) ?? [];
        final pages = dataList.map((fn) => '$baseUrl/data/$hash/$fn').toList();
        final saver = dataSaverList.map((fn) => '$baseUrl/data-saver/$hash/$fn').toList();
        return ChapterPages(chapterId: actualChapterId, pages: pages, dataSaver: saver);
      }
    } catch (_) {}

    throw Exception('Failed to load chapter pages');
  }

  MangaItem _normalizeDirectManga(Map<String, dynamic> m) {
    final a = m['attributes'] as Map<String, dynamic>? ?? {};
    final rels = (m['relationships'] as List<dynamic>?) ?? [];
    final coverRel = rels.firstWhere((r) => r['type'] == 'cover_art', orElse: () => null);
    final fileName = coverRel != null && coverRel['attributes'] != null ? coverRel['attributes']['fileName']?.toString() : null;
    final id = m['id']?.toString() ?? '';

    String title = '';
    final titleMap = a['title'];
    if (titleMap is Map) {
      title = titleMap['en']?.toString() ?? (titleMap.isNotEmpty ? titleMap.values.first.toString() : '');
    }
    if (title.isEmpty) {
      final alt = (a['altTitles'] as List<dynamic>?) ?? [];
      for (final t in alt) {
        if (t is Map && t['en'] != null) {
          title = t['en'].toString();
          break;
        }
      }
    }
    if (title.isEmpty) title = 'Untitled';

    String desc = '';
    final descMap = a['description'];
    if (descMap is Map) {
      desc = descMap['en']?.toString() ?? (descMap.isNotEmpty ? descMap.values.first.toString() : '');
    }

    final origLang = a['originalLanguage']?.toString() ?? '';
    final type = origLang == 'ko' ? 'manhwa' : (origLang.startsWith('zh') ? 'manhua' : 'manga');
    final coverUrl = (fileName != null && fileName.isNotEmpty)
        ? 'https://uploads.mangadex.org/covers/$id/$fileName.512.jpg'
        : '';

    final authors = rels
        .where((r) => r['type'] == 'author' || r['type'] == 'artist')
        .map((r) => (r['attributes'] as Map<String, dynamic>?)?['name']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();

    return MangaItem(
      id: id,
      title: title,
      description: desc,
      cover: coverUrl,
      authors: authors,
      status: a['status']?.toString() ?? '',
      type: type,
      lastChapter: a['lastChapter']?.toString(),
      source: 'mangadex',
    );
  }

  Future<List<MangaItem>> _searchAsura({String? query, String? type, int page = 1}) async {
    try {
      if (type != null && type.isNotEmpty && type != 'all' && type != 'manhwa') {
        // Asura Scans specializes in Korean Manhwa
        return [];
      }
      final uri = Uri.parse('https://api.asurascans.com/api/series').replace(queryParameters: {
        if (query != null && query.isNotEmpty) 'search': query,
        'page': page.toString(),
      });
      final res = await http.get(uri, headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 8));

      if (res.statusCode == 200) {
        final clean = res.body.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
        final data = jsonDecode(clean) as Map<String, dynamic>;
        final list = (data['data'] as List<dynamic>?) ?? [];
        return list.map((item) {
          final latest = item['latest_chapters'] as List<dynamic>?;
          final chNum = latest != null && latest.isNotEmpty ? latest[0]['number']?.toString() : null;
          final desc = (item['description']?.toString() ?? '').replaceAll(RegExp(r'<[^>]*>'), '').trim();
          return MangaItem(
            id: 'asura:${item['slug']}',
            title: item['title']?.toString() ?? 'Untitled',
            description: desc,
            cover: item['cover']?.toString() ?? '',
            status: item['status']?.toString() ?? '',
            type: item['type']?.toString() ?? 'manhwa',
            lastChapter: chNum,
            source: 'asura',
          );
        }).toList();
      }
    } catch (e) {
      debugPrint('Asura search error: $e');
    }
    return [];
  }

  Future<MangaItem> _getAsuraManga(String id) async {
    final cleanSlug = id.replaceFirst('asura:', '');
    final uri = Uri.parse('https://api.asurascans.com/api/series/$cleanSlug');
    final res = await http.get(uri, headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 8));

    if (res.statusCode == 200) {
      final clean = res.body.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
      final data = jsonDecode(clean) as Map<String, dynamic>;
      final s = data['series'] as Map<String, dynamic>? ?? {};
      final desc = (s['description']?.toString() ?? '').replaceAll(RegExp(r'<[^>]*>'), '').trim();
      final genres = (s['genres'] as List<dynamic>?)?.map((g) => g['name']?.toString() ?? '').where((g) => g.isNotEmpty).toList() ?? [];
      return MangaItem(
        id: 'asura:$cleanSlug',
        title: s['title']?.toString() ?? 'Untitled',
        description: desc,
        cover: s['cover']?.toString() ?? '',
        status: s['status']?.toString() ?? '',
        type: s['type']?.toString() ?? 'manhwa',
        authors: [if (s['author'] != null && s['author'].toString().isNotEmpty) s['author'].toString()],
        tags: genres,
        source: 'asura',
      );
    }
    throw Exception('Failed to load Asura series details');
  }

  Future<List<ChapterItem>> _getAsuraChapters(String id) async {
    final cleanSlug = id.replaceFirst('asura:', '');
    final uri = Uri.parse('https://api.asurascans.com/api/series/$cleanSlug/chapters');
    final res = await http.get(uri, headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 8));

    if (res.statusCode == 200) {
      final clean = res.body.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
      final data = jsonDecode(clean) as Map<String, dynamic>;
      final list = (data['data'] as List<dynamic>?) ?? [];
      final chapters = list.map((ch) {
        final chSlug = ch['slug']?.toString() ?? '';
        return ChapterItem(
          id: 'asura:$cleanSlug:$chSlug',
          number: ch['number']?.toString(),
          title: ch['title']?.toString() ?? '',
          group: 'Asura Scans',
          publishAt: ch['published_at']?.toString(),
          pages: (ch['page_count'] as num?)?.toInt() ?? 0,
          source: 'asura',
        );
      }).toList();

      chapters.sort((a, b) {
        final na = double.tryParse(a.number ?? '') ?? -1.0;
        final nb = double.tryParse(b.number ?? '') ?? -1.0;
        return nb.compareTo(na);
      });
      return chapters;
    }
    return [];
  }

  Future<ChapterPages> _getAsuraChapterPages(String chapterId) async {
    final parts = chapterId.split(':');
    if (parts.length < 3) throw Exception('Invalid Asura chapter ID');
    final seriesSlug = parts[1];
    final chapterSlug = parts[2];
    final uri = Uri.parse('https://api.asurascans.com/api/series/$seriesSlug/chapters/$chapterSlug');
    final res = await http.get(uri, headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 8));

    if (res.statusCode == 200) {
      final clean = res.body.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
      final data = jsonDecode(clean) as Map<String, dynamic>;
      final chapterObj = data['data']?['chapter'] as Map<String, dynamic>?;
      final pagesList = (chapterObj?['pages'] as List<dynamic>?)?.map((p) => p['url']?.toString() ?? '').where((u) => u.isNotEmpty).toList() ?? [];
      return ChapterPages(chapterId: chapterId, pages: pagesList);
    }
    throw Exception('Failed to load Asura chapter pages');
  }

  // ---- Flame Comics Scraper ----

  Future<List<MangaItem>> _searchFlameComics({String? query, String? type, int page = 1, int limit = 24}) async {
    try {
      final res = await http.get(
        Uri.parse('https://flamecomics.xyz/browse'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': 'text/html',
        },
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final html = res.body;
        final idx = html.indexOf('<script id="__NEXT_DATA__"');
        if (idx == -1) return [];
        final end = html.indexOf('</script>', idx);
        if (end == -1) return [];
        final jsonStr = html.substring(html.indexOf('>', idx) + 1, end);
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        final seriesList = (data['props']?['pageProps']?['series'] as List<dynamic>?) ?? [];

        var items = seriesList.map((item) {
          final sId = item['series_id']?.toString() ?? '';
          final coverFile = item['cover']?.toString() ?? '';
          final coverUrl = coverFile.startsWith('http')
              ? coverFile
              : 'https://cdn.flamecomics.xyz/uploads/images/series/$sId/$coverFile';
          final cats = (item['categories'] as List<dynamic>?)?.map((c) => c.toString()).toList() ?? <String>[];
          final authors = (item['author'] as List<dynamic>?)?.map((a) => a.toString()).toList() ?? <String>[];

          return MangaItem(
            id: 'flame:$sId',
            title: item['title']?.toString() ?? 'Untitled',
            description: item['description']?.toString() ?? '',
            cover: coverUrl,
            status: item['status']?.toString() ?? '',
            type: item['type']?.toString().toLowerCase() ?? 'manhwa',
            tags: cats,
            authors: authors,
            source: 'flamecomics',
          );
        }).toList();

        if (type != null && type.isNotEmpty && type != 'all') {
          final t = type.toLowerCase();
          items = items.where((m) {
            final mt = m.type.toLowerCase();
            if (t == 'manhwa') return mt.contains('manhwa') || mt == 'webtoon' || mt == 'comic';
            if (t == 'manga') return mt.contains('manga');
            if (t == 'manhua') return mt.contains('manhua');
            return mt == t;
          }).toList();
        }

        if (query != null && query.trim().isNotEmpty) {
          final q = query.trim().toLowerCase();
          items = items.where((m) =>
            m.title.toLowerCase().contains(q) ||
            m.description.toLowerCase().contains(q)
          ).toList();
        }

        final start = (page - 1) * limit;
        if (start >= items.length) return [];
        return items.skip(start).take(limit).toList();
      }
    } catch (e) {
      debugPrint('FlameComics search error: $e');
    }
    return [];
  }

  Future<MangaItem> _getFlameManga(String id) async {
    final sId = id.replaceFirst('flame:', '');
    final res = await http.get(
      Uri.parse('https://flamecomics.xyz/series/$sId'),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
    ).timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      final html = res.body;
      final idx = html.indexOf('<script id="__NEXT_DATA__"');
      if (idx != -1) {
        final end = html.indexOf('</script>', idx);
        final jsonStr = html.substring(html.indexOf('>', idx) + 1, end);
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        final s = data['props']?['pageProps']?['series'] as Map<String, dynamic>? ?? {};
        final coverFile = s['cover']?.toString() ?? '';
        final coverUrl = coverFile.startsWith('http')
            ? coverFile
            : 'https://cdn.flamecomics.xyz/uploads/images/series/$sId/$coverFile';
        final cats = (s['categories'] as List<dynamic>?)?.map((c) => c.toString()).toList() ?? <String>[];
        final authors = (s['author'] as List<dynamic>?)?.map((a) => a.toString()).toList() ?? <String>[];

        return MangaItem(
          id: id,
          title: s['title']?.toString() ?? 'Untitled',
          description: s['description']?.toString() ?? '',
          cover: coverUrl,
          status: s['status']?.toString() ?? '',
          type: s['type']?.toString().toLowerCase() ?? 'manhwa',
          tags: cats,
          authors: authors,
          source: 'flamecomics',
        );
      }
    }
    throw Exception('Failed to load Flame Comics series details');
  }

  Future<List<ChapterItem>> _getFlameChapters(String id) async {
    final sId = id.replaceFirst('flame:', '');
    final res = await http.get(
      Uri.parse('https://flamecomics.xyz/series/$sId'),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
    ).timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      final html = res.body;
      final idx = html.indexOf('<script id="__NEXT_DATA__"');
      if (idx != -1) {
        final end = html.indexOf('</script>', idx);
        final jsonStr = html.substring(html.indexOf('>', idx) + 1, end);
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        final chs = (data['props']?['pageProps']?['chapters'] as List<dynamic>?) ?? [];

        final list = chs.map((c) {
          final token = c['token']?.toString() ?? '';
          final chNum = c['chapter']?.toString();
          final title = c['title']?.toString() ?? '';
          final rel = c['release_date']?.toString();
          return ChapterItem(
            id: 'flame:$sId:$token',
            number: chNum,
            title: title,
            source: 'flamecomics',
            publishAt: rel,
          );
        }).toList();

        list.sort((a, b) {
          final na = double.tryParse(a.number ?? '') ?? -1.0;
          final nb = double.tryParse(b.number ?? '') ?? -1.0;
          return nb.compareTo(na);
        });
        return list;
      }
    }
    return [];
  }

  Future<ChapterPages> _getFlameChapterPages(String chapterId) async {
    final parts = chapterId.split(':');
    if (parts.length < 3) throw Exception('Invalid Flame chapter ID');
    final sId = parts[1];
    final token = parts[2];
    final res = await http.get(
      Uri.parse('https://flamecomics.xyz/series/$sId/$token'),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
    ).timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      final html = res.body;
      final idx = html.indexOf('<script id="__NEXT_DATA__"');
      if (idx != -1) {
        final end = html.indexOf('</script>', idx);
        final jsonStr = html.substring(html.indexOf('>', idx) + 1, end);
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        final imgsObj = data['props']?['pageProps']?['chapter']?['images'];
        final pagesList = <String>[];
        if (imgsObj is Map<String, dynamic>) {
          final sortedKeys = imgsObj.keys.toList()
            ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
          for (final k in sortedKeys) {
            final imgMap = imgsObj[k];
            if (imgMap is Map<String, dynamic>) {
              final name = imgMap['name']?.toString() ?? '';
              if (name.isNotEmpty) {
                pagesList.add('https://cdn.flamecomics.xyz/uploads/images/series/$sId/$token/$name');
              }
            }
          }
        }
        return ChapterPages(chapterId: chapterId, pages: pagesList);
      }
    }
    throw Exception('Failed to load Flame Comics chapter pages');
  }

  // ---- Weeb Central Scraper ----

  Future<List<MangaItem>> _searchWeebCentral({String? query, String? type, int page = 1, int limit = 24}) async {
    try {
      final String typeParam;
      if (type == 'manhwa') {
        typeParam = '&included_type=Manhwa';
      } else if (type == 'manhua') {
        typeParam = '&included_type=Manhua';
      } else if (type == 'manga') {
        typeParam = '&included_type=Manga';
      } else {
        typeParam = '';
      }

      final String url;
      if (query != null && query.trim().isNotEmpty) {
        url = 'https://weebcentral.com/search/data?text=${Uri.encodeComponent(query.trim())}$typeParam&page=$page';
      } else {
        url = 'https://weebcentral.com/search/data?sort=Popularity&order=Ascending$typeParam&page=$page';
      }
      final res = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': 'text/html',
        },
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final html = res.body;
        final articles = html.split('<article class="bg-base-300 flex gap-4 p-4">').skip(1);
        final items = <MangaItem>[];

        for (final art in articles) {
          final seriesMatch = RegExp(r'href="https://weebcentral\.com/series/([A-Z0-9]+)/([^"]+)"').firstMatch(art);
          if (seriesMatch == null) continue;
          final sId = seriesMatch.group(1)!;
          final slug = seriesMatch.group(2)!;

          final imgMatch = RegExp(r'<img[^>]+src="([^"]+)"').firstMatch(art);
          final coverUrl = imgMatch?.group(1) ?? 'https://temp.compsci88.com/cover/fallback/$sId.jpg';

          final titleMatch = RegExp(r'<a[^>]+class="link link-hover[^"]*"[^>]*>([^<]+)</a>').firstMatch(art) ??
              RegExp(r'href="https://weebcentral\.com/series/[^/]+/[^"]+">([^<]+)</a>').firstMatch(art);
          final title = titleMatch?.group(1)?.trim() ?? slug.replaceAll('-', ' ');

          items.add(MangaItem(
            id: 'weeb:$sId:$slug',
            title: title,
            cover: coverUrl,
            type: type ?? 'manga',
            source: 'weebcentral',
          ));
        }
        return items;
      }
    } catch (e) {
      debugPrint('WeebCentral search error: $e');
    }
    return [];
  }

  Future<MangaItem> _getWeebManga(String id) async {
    final parts = id.split(':');
    final sId = parts.length > 1 ? parts[1] : '';
    final slug = parts.length > 2 ? parts[2] : '';
    final url = 'https://weebcentral.com/series/$sId/$slug';

    final res = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
    ).timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      final html = res.body;
      final titleMatch = RegExp(r'<h1[^>]*>([^<]+)</h1>').firstMatch(html);
      final title = titleMatch?.group(1)?.trim() ?? slug.replaceAll('-', ' ');

      final descMatch = RegExp(r'<p class="whitespace-pre-line[^"]*">([^<]+)</p>').firstMatch(html);
      final desc = descMatch?.group(1)?.trim() ?? '';

      final coverUrl = 'https://temp.compsci88.com/cover/fallback/$sId.jpg';

      return MangaItem(
        id: id,
        title: title,
        description: desc,
        cover: coverUrl,
        source: 'weebcentral',
      );
    }
    throw Exception('Failed to load Weeb Central series details');
  }

  Future<List<ChapterItem>> _getWeebChapters(String id) async {
    final parts = id.split(':');
    final sId = parts.length > 1 ? parts[1] : '';
    final url = 'https://weebcentral.com/series/$sId/full-chapter-list';

    final res = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
    ).timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      final html = res.body;
      final regex = RegExp(r'<a href="/chapters/([A-Z0-9]+)"[^>]*>[\s\S]*?<span class="">([^<]+)</span>[\s\S]*?</a>');
      final matches = regex.allMatches(html);
      final list = <ChapterItem>[];

      for (final m in matches) {
        final chId = m.group(1)!;
        final chText = m.group(2)!.trim();
        final numMatch = RegExp(r'Chapter\s*([\d\.]+)').firstMatch(chText);
        final chNum = numMatch?.group(1) ?? chText;

        list.add(ChapterItem(
          id: 'weeb:$chId',
          number: chNum,
          title: chText,
          source: 'weebcentral',
        ));
      }
      return list;
    }
    return [];
  }

  Future<ChapterPages> _getWeebChapterPages(String chapterId) async {
    final cleanId = chapterId.replaceFirst('weeb:', '');
    final url = 'https://weebcentral.com/chapters/$cleanId/images';

    final res = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
    ).timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      final html = res.body;
      final imgMatches = RegExp(r'src="(https://[^"]+)"').allMatches(html);
      final pagesList = imgMatches
          .map((m) => m.group(1)!)
          .where((u) => !u.contains('.svg') && !u.contains('logo'))
          .toList();

      return ChapterPages(chapterId: chapterId, pages: pagesList);
    }
    throw Exception('Failed to load Weeb Central chapter pages');
  }

  // ---- Bookmarks & Library (Local-First + Cloud Sync) ----

  Future<List<MangaItem>> getLibrary({String? type}) async {
    // If logged in, sync from cloud
    if (isLoggedIn) {
      try {
        final uri = Uri.parse('$_baseUrl/library').replace(queryParameters: {
          if (type != null && type.isNotEmpty && type != 'all') 'type': type,
        });
        final res = await http.get(uri, headers: _headers(withAuth: true));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final list = (data['items'] as List<dynamic>?) ?? [];
          for (final e in list) {
            final id = e['mangaId']?.toString() ?? e['id']?.toString() ?? '';
            if (id.isEmpty) continue;
            final source = _inferSourceFromId(id, e['source']?.toString());
            final m = MangaItem(
              id: id,
              title: e['title']?.toString() ?? 'Untitled',
              cover: e['cover']?.toString() ?? '',
              type: e['type']?.toString() ?? 'manga',
              status: e['status']?.toString() ?? '',
              lastChapter: e['latestChapter']?.toString() ?? '',
              source: source,
            );
            _localLibrary[m.id] = m;
          }
          await _persistLocalLibrary();
        }
      } catch (_) {}
    }

    // Return all items in local library (optionally filtered by type)
    var items = _localLibrary.values.toList();
    if (type != null && type.isNotEmpty && type != 'all') {
      items = items.where((m) => m.type == type).toList();
    }
    return items;
  }

  Future<bool> checkInLibrary(String mangaId) async {
    if (_localLibrary.containsKey(mangaId)) return true;
    if (!isLoggedIn) return false;
    try {
      final res = await http.get(Uri.parse('$_baseUrl/library/check/$mangaId'), headers: _headers(withAuth: true));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final inLib = data['inLibrary'] == true;
        if (inLib && !_localLibrary.containsKey(mangaId)) {
          // Sync into local cache
          final m = await getManga(mangaId);
          _localLibrary[mangaId] = m;
          await _persistLocalLibrary();
        }
        return inLib;
      }
    } catch (_) {}
    return false;
  }

  Future<void> addToLibrary(MangaItem manga) async {
    _localLibrary[manga.id] = manga;
    await _persistLocalLibrary();
    notifyListeners();

    if (isLoggedIn) {
      try {
        await http.post(
          Uri.parse('$_baseUrl/library'),
          headers: _headers(withAuth: true),
          body: jsonEncode({
            'mangaId': manga.id,
            'title': manga.title,
            'cover': manga.cover,
            'type': manga.type,
            'status': manga.status,
            'latestChapter': manga.lastChapter ?? '',
          }),
        );
      } catch (_) {}
    }
  }

  Future<void> removeFromLibrary(String mangaId) async {
    _localLibrary.remove(mangaId);
    await _persistLocalLibrary();
    notifyListeners();

    if (isLoggedIn) {
      try {
        await http.delete(Uri.parse('$_baseUrl/library/$mangaId'), headers: _headers(withAuth: true));
      } catch (_) {}
    }
  }

  // ---- Reading Progress & History ----

  Future<void> saveProgress({
    required String mangaId,
    required String chapterId,
    String? mangaTitle,
    String? cover,
    String? chapterNumber,
    String? chapterTitle,
    int page = 1,
    int totalPages = 0,
    bool completed = false,
  }) async {
    if (completed) {
      _readChapters.putIfAbsent(mangaId, () => <String>{}).add(chapterId);
      _persistReadChapters();
    }

    final progressData = <String, dynamic>{
      'mangaId': mangaId,
      'chapterId': chapterId,
      'mangaTitle': mangaTitle ?? '',
      'cover': cover ?? '',
      'chapterNumber': chapterNumber ?? '',
      'chapterTitle': chapterTitle ?? '',
      'page': page,
      'totalPages': totalPages,
      'completed': completed,
      'updatedAt': DateTime.now().toIso8601String(),
    };

    // 1. Always persist locally first so reading works 100% offline
    _localProgress[mangaId] = progressData;
    await _persistLocalProgress();

    // 2. Update history list (most recent first, deduplicated by mangaId)
    _localHistory.removeWhere((e) => e['mangaId'] == mangaId);
    _localHistory.insert(0, progressData);
    if (_localHistory.length > 100) {
      _localHistory.removeRange(100, _localHistory.length);
    }
    await _persistLocalHistory();
    notifyListeners();

    // 3. If logged in, also sync to cloud
    if (!isLoggedIn) return;
    try {
      await http.post(
        Uri.parse('$_baseUrl/progress'),
        headers: _headers(withAuth: true),
        body: jsonEncode(progressData),
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>> getMangaProgress(String mangaId) async {
    final localLast = _localProgress[mangaId];
    final readSet = _readChapters[mangaId] ?? <String>{};
    final base = <String, dynamic>{
      'mangaId': mangaId,
      'completedChapters': readSet.toList(),
      'lastRead': localLast,
    };

    if (!isLoggedIn) return base;
    try {
      final res = await http.get(Uri.parse('$_baseUrl/progress/manga/$mangaId'), headers: _headers(withAuth: true));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (data['completedChapters'] is List) {
          final cloudCompleted = (data['completedChapters'] as List).map((e) => e.toString()).toSet();
          readSet.addAll(cloudCompleted);
          _readChapters[mangaId] = readSet;
          _persistReadChapters();
        }
        if (data['lastRead'] is Map) {
          _localProgress[mangaId] = Map<String, dynamic>.from(data['lastRead'] as Map);
          _persistLocalProgress();
        }
        return {
          'mangaId': mangaId,
          'completedChapters': readSet.toList(),
          'lastRead': _localProgress[mangaId],
        };
      }
    } catch (_) {}
    return base;
  }

  // ---- Chapter Read/Unread Status ----

  bool isChapterRead(String mangaId, String chapterId) {
    return _readChapters[mangaId]?.contains(chapterId) ?? false;
  }

  Set<String> getReadChapterIds(String mangaId) {
    return Set<String>.from(_readChapters[mangaId] ?? const <String>{});
  }

  Future<void> markChapterRead(String mangaId, String chapterId, {bool read = true}) async {
    final set = _readChapters.putIfAbsent(mangaId, () => <String>{});
    if (read) {
      set.add(chapterId);
    } else {
      set.remove(chapterId);
    }
    await _persistReadChapters();
    notifyListeners();
  }

  Future<void> markChaptersRead(String mangaId, List<String> chapterIds, {bool read = true}) async {
    final set = _readChapters.putIfAbsent(mangaId, () => <String>{});
    if (read) {
      set.addAll(chapterIds);
    } else {
      set.removeAll(chapterIds);
    }
    await _persistReadChapters();
    notifyListeners();
  }

  // ---- Chapter Bookmarks ----

  bool isChapterBookmarked(String chapterId) {
    return _bookmarkedChapterIds.contains(chapterId);
  }

  Future<bool> toggleChapterBookmark(String chapterId) async {
    final has = _bookmarkedChapterIds.contains(chapterId);
    if (has) {
      _bookmarkedChapterIds.remove(chapterId);
    } else {
      _bookmarkedChapterIds.add(chapterId);
    }
    await _persistChapterBookmarks();
    notifyListeners();
    return !has;
  }

  Future<void> setChapterBookmarked(String chapterId, bool bookmarked) async {
    if (bookmarked) {
      _bookmarkedChapterIds.add(chapterId);
    } else {
      _bookmarkedChapterIds.remove(chapterId);
    }
    await _persistChapterBookmarks();
    notifyListeners();
  }

  Set<String> getBookmarkedChapterIds() {
    return Set<String>.from(_bookmarkedChapterIds);
  }

  // ---- User Categories Management ----

  List<CategoryItem> getCategories() {
    return List<CategoryItem>.from(_userCategories);
  }

  Future<CategoryItem> createCategory(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw Exception('Category name cannot be empty');
    final id = 'cat_${DateTime.now().millisecondsSinceEpoch}';
    final newCat = CategoryItem(id: id, name: trimmed, order: _userCategories.length);
    _userCategories.add(newCat);
    await _persistUserCategories();
    notifyListeners();
    return newCat;
  }

  Future<void> renameCategory(String id, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) throw Exception('Category name cannot be empty');
    final idx = _userCategories.indexWhere((c) => c.id == id);
    if (idx != -1) {
      _userCategories[idx] = CategoryItem(id: id, name: trimmed, order: _userCategories[idx].order);
      await _persistUserCategories();
      notifyListeners();
    }
  }

  Future<void> deleteCategory(String id) async {
    _userCategories.removeWhere((c) => c.id == id);
    for (final key in _mangaCategories.keys) {
      _mangaCategories[key]?.remove(id);
    }
    await _persistUserCategories();
    await _persistMangaCategories();
    notifyListeners();
  }

  List<String> getMangaCategoryIds(String mangaId) {
    return List<String>.from(_mangaCategories[mangaId] ?? const <String>[]);
  }

  Future<void> setMangaCategories(String mangaId, List<String> categoryIds) async {
    _mangaCategories[mangaId] = List<String>.from(categoryIds);
    await _persistMangaCategories();
    notifyListeners();
  }

  Future<void> toggleMangaCategory(String mangaId, String categoryId) async {
    final list = _mangaCategories.putIfAbsent(mangaId, () => <String>[]);
    if (list.contains(categoryId)) {
      list.remove(categoryId);
    } else {
      list.add(categoryId);
    }
    await _persistMangaCategories();
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> getHistory() async {
    if (isLoggedIn) {
      try {
        final res = await http.get(Uri.parse('$_baseUrl/progress/history'), headers: _headers(withAuth: true));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final list = data['items'] as List<dynamic>? ?? [];
          for (final item in list) {
            if (item is Map) {
              final map = Map<String, dynamic>.from(item);
              final mangaId = map['mangaId'] as String? ?? '';
              if (mangaId.isNotEmpty && !_localHistory.any((h) => h['mangaId'] == mangaId)) {
                _localHistory.add(map);
              }
            }
          }
          await _persistLocalHistory();
        }
      } catch (_) {}
    }
    return _localHistory;
  }

  Future<void> clearHistory() async {
    _localHistory.clear();
    _localProgress.clear();
    await _persistLocalHistory();
    await _persistLocalProgress();
    notifyListeners();
  }

  // ---- Backup & Data Transfer ----

  Future<String> exportBackupJson() async {
    final installed = ExtensionService.instance.installedPackages.toList();
    final backup = {
      'version': 1,
      'app': 'Shiori',
      'exportedAt': DateTime.now().toIso8601String(),
      'bookmarksCount': _localLibrary.length,
      'historyCount': _localHistory.length,
      'library': _localLibrary.values.map((e) => e.toJson()).toList(),
      'history': _localHistory,
      'progress': _localProgress,
      'installedSources': installed,
    };
    return const JsonEncoder.withIndent('  ').convert(backup);
  }

  Future<Map<String, int>> restoreBackupJson(String jsonString) async {
    final Map<String, dynamic> data = jsonDecode(jsonString.trim()) as Map<String, dynamic>;
    int restoredBookmarks = 0;
    int restoredHistory = 0;

    // 1. Restore Library Bookmarks
    if (data['library'] is List) {
      final list = data['library'] as List;
      for (final item in list) {
        if (item is Map) {
          final m = MangaItem.fromJson(Map<String, dynamic>.from(item));
          if (m.id.isNotEmpty) {
            _localLibrary[m.id] = m;
            restoredBookmarks++;
          }
        }
      }
      await _persistLocalLibrary();
    }

    // 2. Restore Progress & History
    if (data['progress'] is Map) {
      final prog = data['progress'] as Map;
      prog.forEach((k, v) {
        if (v is Map) {
          _localProgress[k.toString()] = Map<String, dynamic>.from(v);
        }
      });
      await _persistLocalProgress();
    }

    if (data['history'] is List) {
      final hist = data['history'] as List;
      for (final item in hist) {
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          _localHistory.removeWhere((e) => e['mangaId'] == map['mangaId']);
          _localHistory.add(map);
          restoredHistory++;
        }
      }
      await _persistLocalHistory();
    }

    // 3. Restore Installed Sources
    if (data['installedSources'] is List) {
      final exts = (data['installedSources'] as List).map((e) => e.toString()).toList();
      for (final pkg in exts) {
        await ExtensionService.instance.installPackageByNameOrId(pkg);
      }
    }

    // 4. Sync to cloud if user is logged in
    if (isLoggedIn) {
      syncAllCloudData();
    }

    notifyListeners();

    return {
      'bookmarks': restoredBookmarks,
      'history': restoredHistory,
    };
  }

  // ---- Updates Feed (Strictly for Bookmarked / Saved Manga) ----

  Future<Map<String, dynamic>> getUpdates() async {
    // 1. Get user's bookmarked manga (local + cloud)
    final bookmarked = await getLibrary();
    final bookmarkedIds = bookmarked.map((m) => m.id).toSet();

    // 2. If user has NOT bookmarked anything, updates MUST be completely empty!
    if (bookmarkedIds.isEmpty) {
      return {
        'groups': {
          'Today': [],
          'Yesterday': [],
          'Earlier': [],
        },
        'items': [],
        'total': 0,
      };
    }

    // 3. Try to get updates from the backend first, but STRICTLY filter to ONLY bookmarked titles!
    try {
      final res = await http.get(Uri.parse('$_baseUrl/updates'), headers: _headers(withAuth: true)).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final rawGroups = (data['groups'] as Map<String, dynamic>?) ?? {};
        final filteredGroups = <String, dynamic>{};
        final filteredItems = <dynamic>[];

        for (final entry in rawGroups.entries) {
          final list = (entry.value as List? ?? [])
              .where((item) => bookmarkedIds.contains(item['mangaId']))
              .toList();
          filteredGroups[entry.key] = list;
          filteredItems.addAll(list);
        }

        if (filteredItems.isNotEmpty) {
          return {
            'groups': filteredGroups,
            'items': filteredItems,
            'total': filteredItems.length,
          };
        }
      }
    } catch (_) {}

    // 4. Client-side fetch for the user's bookmarked manga:
    // Fetches real latest chapters directly from MangaDex API for each bookmarked title
    final List<Map<String, dynamic>> allChapters = [];
    final now = DateTime.now();
    final todayStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final yesterday = now.subtract(const Duration(days: 1));
    final yesterdayStr = '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';

    final tasks = bookmarked.take(20).map((manga) async {
      try {
        final chapters = await getChapters(manga.id);
        if (chapters.isNotEmpty) {
          for (final ch in chapters.take(2)) {
            allChapters.add({
              'id': ch.id,
              'mangaId': manga.id,
              'mangaTitle': manga.title,
              'cover': manga.cover,
              'chapterNumber': ch.number,
              'chapterTitle': ch.title,
              'group': ch.group.isNotEmpty
                  ? ch.group
                  : (manga.source.isNotEmpty
                      ? (ExtensionService.instance.getExtensionByPkg(manga.source)?.name ??
                         (manga.source == 'asura' ? 'Asura Scans' :
                          manga.source == 'flamecomics' ? 'Flame Comics' :
                          manga.source == 'weebcentral' ? 'Weeb Central' :
                          manga.source == 'mangadex' ? 'MangaDex' : manga.source))
                      : 'Direct Source'),
              'publishAt': ch.publishAt,
              'pages': ch.pages,
            });
          }
        }
      } catch (_) {}
    });

    await Future.wait(tasks);

    allChapters.sort((a, b) {
      final dtA = DateTime.tryParse(a['publishAt']?.toString() ?? '') ?? DateTime(2000);
      final dtB = DateTime.tryParse(b['publishAt']?.toString() ?? '') ?? DateTime(2000);
      return dtB.compareTo(dtA);
    });

    final groups = <String, dynamic>{
      'Today': <Map<String, dynamic>>[],
      'Yesterday': <Map<String, dynamic>>[],
      'Earlier': <Map<String, dynamic>>[],
    };

    for (final item in allChapters) {
      final pub = item['publishAt']?.toString() ?? '';
      final d = pub.length >= 10 ? pub.substring(0, 10) : '';
      if (d == todayStr) {
        (groups['Today'] as List).add(item);
      } else if (d == yesterdayStr) {
        (groups['Yesterday'] as List).add(item);
      } else {
        (groups['Earlier'] as List).add(item);
      }
    }

    return {
      'groups': groups,
      'items': allChapters,
      'total': allChapters.length,
    };
  }

  /// Checks for new chapters for all manga in library, updating unread badges
  Future<int> checkForLibraryUpdates() async {
    final library = await getLibrary();
    if (library.isEmpty) return 0;

    int newChaptersCount = 0;
    // Process in batches of 4
    for (var i = 0; i < library.length; i += 4) {
      final chunk = library.skip(i).take(4);
      await Future.wait(chunk.map((manga) async {
        try {
          final oldCount = _mangaChapterCounts[manga.id] ?? 0;
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

  // ---- Generic Web Manga Scraper for Community Extensions ----

  Future<List<MangaItem>> _searchWebManga(
    MangaExtension ext, {
    String? query,
    int page = 1,
    int limit = 24,
  }) async {
    try {
      final base = ext.homeUrl.endsWith('/') ? ext.homeUrl.substring(0, ext.homeUrl.length - 1) : ext.homeUrl;
      final String url;
      if (query != null && query.trim().isNotEmpty) {
        url = '$base/?s=${Uri.encodeComponent(query.trim())}';
      } else {
        url = base;
      }

      final res = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final html = res.body;
        final items = <MangaItem>[];

        final linkImgRegex = RegExp(
          r"""<a\s+[^>]*href=["']([^"']+)["'][^>]*>[\s\S]*?<img\s+[^>]*src=["']([^"']+)["'][^>]*(?:alt=["']([^"']*)["'])?[\s\S]*?</a>""",
          caseSensitive: false,
        );

        final matches = linkImgRegex.allMatches(html);
        final seenUrls = <String>{};

        for (final m in matches) {
          var itemUrl = m.group(1) ?? '';
          var coverUrl = m.group(2) ?? '';
          var title = m.group(3)?.trim() ?? '';

          if (itemUrl.isEmpty || itemUrl == '#' || itemUrl == base || itemUrl == '$base/') continue;
          if (coverUrl.contains('.svg') || coverUrl.contains('logo') || coverUrl.contains('avatar') || coverUrl.contains('icon')) continue;

          if (!itemUrl.startsWith('http')) {
            itemUrl = itemUrl.startsWith('/') ? '$base$itemUrl' : '$base/$itemUrl';
          }
          if (!coverUrl.startsWith('http')) {
            coverUrl = coverUrl.startsWith('/') ? '$base$coverUrl' : '$base/$coverUrl';
          }

          if (seenUrls.contains(itemUrl)) continue;
          seenUrls.add(itemUrl);

          if (title.isEmpty) {
            final slug = Uri.tryParse(itemUrl)?.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
            title = slug.replaceAll('-', ' ').replaceAll('_', ' ');
          }

          final lowerTitle = title.toLowerCase().trim();
          const invalidTitles = {
            'home', 'about', 'privacy', 'privacy policy', 'contact', 'contact us',
            'dmca', 'terms', 'terms of service', 'login', 'sign in', 'register',
            'sign up', 'discord', 'telegram', 'twitter', 'facebook', 'donate',
            'bookmark', 'history', 'popular', 'latest', 'search', 'manga list',
            'all manga', 'genre', 'genres', 'tags', 'news'
          };
          if (invalidTitles.contains(lowerTitle)) continue;
          if (coverUrl.isEmpty || coverUrl.length < 8) continue;

          if (title.isNotEmpty) {
            items.add(MangaItem(
              id: 'ext:${ext.pkg}:${Uri.encodeComponent(itemUrl)}',
              title: title,
              cover: coverUrl,
              source: ext.pkg,
            ));
          }
          if (items.length >= limit) break;
        }

        return items;
      }
    } catch (e) {
      debugPrint('WebExtension search error for ${ext.pkg}: $e');
    }
    return [];
  }

  Future<MangaItem> _getWebManga(String pkg, String actualId, {MangaExtension? ext}) async {
    final seriesUrl = Uri.decodeComponent(actualId);
    try {
      final res = await http.get(
        Uri.parse(seriesUrl),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final html = res.body;

        final h1Match = RegExp(r'<h1[^>]*>([^<]+)</h1>', caseSensitive: false).firstMatch(html);
        final title = h1Match?.group(1)?.trim() ?? ext?.name ?? 'Series';

        final descMatch = RegExp(r"""<div[^>]*class=["'][^"']*(?:description|synopsis|summary)[^"']*["'][^>]*>([\s\S]*?)</div>""", caseSensitive: false).firstMatch(html) ??
            RegExp(r"""<p[^>]*class=["'][^"']*(?:description|synopsis|summary)[^"']*["'][^>]*>([\s\S]*?)</p>""", caseSensitive: false).firstMatch(html);
        final desc = descMatch?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '';

        final coverMatch = RegExp(r'<img[^>]*class=["''][^"'']*(?:thumb|cover|poster)[^"'']*["''][^>]*src=["'']([^"'']+)["'']', caseSensitive: false).firstMatch(html) ??
            RegExp(r'<img[^>]*src=["'']([^"'']+)["''][^>]*class=["''][^"'']*(?:thumb|cover|poster)[^"'']*["'']', caseSensitive: false).firstMatch(html);
        var coverUrl = coverMatch?.group(1) ?? '';
        if (coverUrl.isNotEmpty && !coverUrl.startsWith('http')) {
          final uri = Uri.parse(seriesUrl);
          coverUrl = '${uri.scheme}://${uri.host}$coverUrl';
        }

        return MangaItem(
          id: 'ext:$pkg:$actualId',
          title: title,
          description: desc,
          cover: coverUrl,
          source: pkg,
        );
      }
    } catch (e) {
      debugPrint('WebExtension getManga error: $e');
    }

    return MangaItem(
      id: 'ext:$pkg:$actualId',
      title: ext?.name ?? 'Series',
      source: pkg,
    );
  }

  Future<List<ChapterItem>> _getWebChapters(String pkg, String actualId, {MangaExtension? ext}) async {
    final seriesUrl = Uri.decodeComponent(actualId);
    try {
      final res = await http.get(
        Uri.parse(seriesUrl),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final html = res.body;
        final chapterRegex = RegExp(
          r"""<a\s+[^>]*href=["']([^"']*(?:chapter|ch-)[^"']*)["'][^>]*>([\s\S]*?)</a>""",
          caseSensitive: false,
        );
        final matches = chapterRegex.allMatches(html);
        final list = <ChapterItem>[];
        final seen = <String>{};

        for (final m in matches) {
          var chUrl = m.group(1) ?? '';
          final rawText = (m.group(2) ?? '').replaceAll(RegExp(r'<[^>]*>'), '').trim();

          if (chUrl.isEmpty || seen.contains(chUrl)) continue;
          seen.add(chUrl);

          if (!chUrl.startsWith('http')) {
            final uri = Uri.parse(seriesUrl);
            chUrl = chUrl.startsWith('/') ? '${uri.scheme}://${uri.host}$chUrl' : '${uri.scheme}://${uri.host}/$chUrl';
          }

          final numMatch = RegExp(r'(?:chapter|ch\.?)\s*([\d\.]+)', caseSensitive: false).firstMatch(rawText);
          final chNum = numMatch?.group(1);

          list.add(ChapterItem(
            id: 'ext:$pkg:${Uri.encodeComponent(chUrl)}',
            number: chNum,
            title: rawText.isNotEmpty ? rawText : (chNum != null ? 'Chapter $chNum' : 'Chapter'),
            group: ext?.name ?? 'Web',
            source: pkg,
          ));
        }

        return list;
      }
    } catch (e) {
      debugPrint('WebExtension getChapters error: $e');
    }
    return [];
  }

  Future<ChapterPages> _getWebChapterPages(String pkg, String actualChapterId, {MangaExtension? ext}) async {
    final chapterUrl = Uri.decodeComponent(actualChapterId);
    try {
      final res = await http.get(
        Uri.parse(chapterUrl),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final html = res.body;
        final imgMatches = RegExp(r'<img[^>]+src=["'']([^"'']+)["'']', caseSensitive: false).allMatches(html);
        final pagesList = <String>[];
        final seen = <String>{};

        for (final m in imgMatches) {
          var u = m.group(1)?.trim() ?? '';
          if (u.isEmpty || u.contains('.svg') || u.contains('logo') || u.contains('banner') || u.contains('avatar') || u.contains('icon')) {
            continue;
          }
          if (!u.startsWith('http')) {
            final uri = Uri.parse(chapterUrl);
            u = u.startsWith('/') ? '${uri.scheme}://${uri.host}$u' : '${uri.scheme}://${uri.host}/$u';
          }
          if (seen.add(u)) {
            pagesList.add(u);
          }
        }

        return ChapterPages(
          chapterId: 'ext:$pkg:$actualChapterId',
          pages: pagesList,
          dataSaver: pagesList,
        );
      }
    } catch (e) {
      debugPrint('WebExtension getChapterPages error: $e');
    }
    throw Exception('Failed to load chapter pages from $pkg');
  }

  static String _unescapeHtml(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#8217;', "'")
        .replaceAll('&#8216;', "'")
        .replaceAll('&#8220;', '"')
        .replaceAll('&#8221;', '"')
        .replaceAll('&hellip;', '...');
  }

  // ---- MangaPill Direct Scraper ----

  Future<List<MangaItem>> _searchMangaPill({String? query, String? type, int page = 1, int limit = 24}) async {
    try {
      if (type == 'manhwa' || type == 'manhua') {
        // MangaPill only hosts Japanese Manga
        return [];
      }

      final String url;
      if (query != null && query.trim().isNotEmpty) {
        url = 'https://mangapill.com/search?q=${Uri.encodeComponent(query.trim())}&page=$page';
      } else {
        url = 'https://mangapill.com/mangas/new?page=$page';
      }

      final res = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
          'Accept': 'text/html',
        },
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final html = res.body;
        final cardRegex = RegExp(
          r'<a\s+href="/manga/(\d+)/([^"]+)"[^>]*>[\s\S]*?<img\s+[^>]*data-src="([^"]+)"[\s\S]*?<div class="mt-3 font-black leading-tight line-clamp-2">([^<]+)</div>',
          caseSensitive: false,
        );

        final matches = cardRegex.allMatches(html);
        final items = <MangaItem>[];
        final seen = <String>{};

        for (final m in matches) {
          final mId = m.group(1)!;
          final slug = m.group(2)!;
          final cover = m.group(3)!;
          final title = _unescapeHtml(m.group(4)!.trim());

          final id = 'pill:$mId:$slug';
          if (seen.contains(id)) continue;
          seen.add(id);

          items.add(MangaItem(
            id: id,
            title: title,
            cover: cover,
            type: 'manga',
            source: 'mangapill',
          ));
          if (items.length >= limit) break;
        }
        return items;
      }
    } catch (e) {
      debugPrint('MangaPill search error: $e');
    }
    return [];
  }

  Future<MangaItem> _getMangaPill(String id) async {
    final parts = id.split(':');
    final mId = parts.length > 1 ? parts[1] : '';
    final slug = parts.length > 2 ? parts[2] : '';
    final url = 'https://mangapill.com/manga/$mId/$slug';

    final res = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
    ).timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      final html = res.body;
      final titleMatch = RegExp(r'<h1[^>]*>([^<]+)</h1>').firstMatch(html);
      final title = titleMatch?.group(1)?.trim() ?? slug.replaceAll('-', ' ');

      final descMatch = RegExp(r'<p class="text-sm[^"]*">([^<]+)</p>').firstMatch(html);
      final desc = descMatch?.group(1)?.trim() ?? '';

      final coverMatch = RegExp(r'<figure[^>]*>[\s\S]*?<img[^>]+src="([^"]+)"').firstMatch(html) ??
          RegExp(r'<figure[^>]*>[\s\S]*?<img[^>]+data-src="([^"]+)"').firstMatch(html);
      final cover = coverMatch?.group(1) ?? '';

      return MangaItem(
        id: id,
        title: _unescapeHtml(title),
        description: _unescapeHtml(desc),
        cover: cover,
        source: 'mangapill',
      );
    }
    throw Exception('Failed to load MangaPill manga details');
  }

  Future<List<ChapterItem>> _getMangaPillChapters(String mangaId) async {
    final parts = mangaId.split(':');
    final mId = parts.length > 1 ? parts[1] : '';
    final slug = parts.length > 2 ? parts[2] : '';
    final url = 'https://mangapill.com/manga/$mId/$slug';

    final res = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
    ).timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      final html = res.body;
      final chapterRegex = RegExp(
        r'<a[^>]+href="/chapters/([0-9-]+)/([^"]+)"[^>]*>([^<]+)</a>',
        caseSensitive: false,
      );

      final matches = chapterRegex.allMatches(html);
      final chapters = <ChapterItem>[];

      for (final m in matches) {
        final cId = m.group(1)!;
        final cSlug = m.group(2)!;
        final rawTitle = m.group(3)!.trim();

        final numMatch = RegExp(r'Chapter\s+([0-9.]+)').firstMatch(rawTitle);
        final num = numMatch?.group(1);

        chapters.add(ChapterItem(
          id: 'pill:$cId:$cSlug',
          title: rawTitle,
          number: num,
          source: 'mangapill',
        ));
      }
      return chapters;
    }
    return [];
  }

  Future<ChapterPages> _getMangaPillChapterPages(String chapterId) async {
    final parts = chapterId.split(':');
    final cId = parts.length > 1 ? parts[1] : '';
    final cSlug = parts.length > 2 ? parts[2] : '';
    final url = 'https://mangapill.com/chapters/$cId/$cSlug';

    final res = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'Referer': 'https://mangapill.com/',
      },
    ).timeout(const Duration(seconds: 12));

    if (res.statusCode == 200) {
      final html = res.body;
      final pageRegex = RegExp(r'<img[^>]+class="[^"]*js-page[^"]*"[^>]+data-src="([^"]+)"');
      final matches = pageRegex.allMatches(html);

      final pages = <String>[];
      for (final m in matches) {
        final imgUrl = m.group(1);
        if (imgUrl != null && imgUrl.isNotEmpty) {
          pages.add(imgUrl);
        }
      }

      if (pages.isNotEmpty) {
        return ChapterPages(chapterId: chapterId, pages: pages, dataSaver: pages);
      }
    }
    throw Exception('Failed to load MangaPill chapter pages');
  }

  // ---- MangaKatana Direct Scraper (iOS & Web) ----

  Future<List<MangaItem>> _searchMangaKatana({String? query, String? type, int page = 1, int limit = 24}) async {
    try {
      final String url;
      if (query != null && query.trim().isNotEmpty) {
        url = 'https://mangakatana.com/page/$page?search=${Uri.encodeComponent(query.trim())}&search_by=book_name';
      } else if (type == 'manhwa') {
        url = 'https://mangakatana.com/genre/manhwa/page/$page';
      } else if (type == 'manhua') {
        url = 'https://mangakatana.com/genre/manhua/page/$page';
      } else {
        url = 'https://mangakatana.com/manga?filter=1&order=latest&page=$page';
      }

      final res = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
          'Accept': 'text/html,application/xhtml+xml',
        },
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode == 200) {
        final html = res.body;
        final cardRegex = RegExp(
          r'<div class="item"[^>]*>[\s\S]*?<a href="(https://mangakatana\.com/manga/([^.]+)\.(\d+))"[^>]*>[\s\S]*?<img\s+(?:src|data-src)="([^"]+)"[\s\S]*?<h3 class="title">\s*<a[^>]*>([^<]+)</a>',
          caseSensitive: false,
        );

        final matches = cardRegex.allMatches(html);
        final items = <MangaItem>[];
        final seen = <String>{};

        for (final m in matches) {
          final slug = m.group(2)!;
          final mId = m.group(3)!;
          final cover = m.group(4)!;
          final title = m.group(5)!.trim();

          final id = 'katana:$slug:$mId';
          if (seen.contains(id)) continue;
          seen.add(id);

          items.add(MangaItem(
            id: id,
            title: title,
            cover: cover,
            type: type ?? (url.contains('manhwa') ? 'manhwa' : (url.contains('manhua') ? 'manhua' : 'manga')),
            source: 'mangakatana',
          ));
          if (items.length >= limit) break;
        }
        return items;
      }
    } catch (e) {
      debugPrint('MangaKatana search error: $e');
    }
    return [];
  }

  Future<MangaItem> _getMangaKatana(String id) async {
    final parts = id.split(':');
    final slug = parts.length > 1 ? parts[1] : '';
    final mId = parts.length > 2 ? parts[2] : '';
    final url = 'https://mangakatana.com/manga/$slug.$mId';

    final res = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
      },
    ).timeout(const Duration(seconds: 12));

    if (res.statusCode == 200) {
      final html = res.body;
      final titleMatch = RegExp(r'<h1 class="heading">([^<]+)</h1>').firstMatch(html);
      final title = titleMatch?.group(1)?.trim() ?? slug.replaceAll('-', ' ');

      final descMatch = RegExp(r'<div class="summary">[\s\S]*?<p>([^<]+)</p>').firstMatch(html);
      final desc = descMatch?.group(1)?.trim() ?? '';

      final coverMatch = RegExp(r'<div class="cover">[\s\S]*?<img\s+(?:src|data-src)="([^"]+)"').firstMatch(html);
      final cover = coverMatch?.group(1) ?? '';

      final authorMatches = RegExp(r'<a class="author"[^>]*>([^<]+)</a>').allMatches(html);
      final authors = authorMatches.map((m) => m.group(1)!.trim()).toList();

      final genreMatches = RegExp(r'<div class="genres">[\s\S]*?<a[^>]*>([^<]+)</a>').allMatches(html);
      final tags = genreMatches.map((m) => m.group(1)!.trim()).toList();

      final status = html.contains('class="status completed"') ? 'completed' : 'ongoing';

      return MangaItem(
        id: id,
        title: title,
        description: desc,
        cover: cover,
        authors: authors,
        status: status,
        tags: tags,
        source: 'mangakatana',
      );
    }
    throw Exception('Failed to load MangaKatana manga details');
  }

  Future<List<ChapterItem>> _getMangaKatanaChapters(String mangaId) async {
    final parts = mangaId.split(':');
    final slug = parts.length > 1 ? parts[1] : '';
    final mId = parts.length > 2 ? parts[2] : '';
    final url = 'https://mangakatana.com/manga/$slug.$mId';

    final res = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
      },
    ).timeout(const Duration(seconds: 12));

    if (res.statusCode == 200) {
      final html = res.body;
      final chapterRegex = RegExp(
        r'<div class="chapter">\s*<a href="https://mangakatana\.com/manga/[^/]+/c([^"]+)"[^>]*>([^<]+)</a>',
        caseSensitive: false,
      );

      final matches = chapterRegex.allMatches(html);
      final chapters = <ChapterItem>[];

      for (final m in matches) {
        final cNum = m.group(1)!;
        final rawTitle = m.group(2)!.trim();

        chapters.add(ChapterItem(
          id: 'katana:$slug:$mId:c$cNum',
          title: rawTitle,
          number: cNum,
          source: 'mangakatana',
        ));
      }
      return chapters;
    }
    return [];
  }

  Future<ChapterPages> _getMangaKatanaChapterPages(String chapterId) async {
    final parts = chapterId.split(':');
    final slug = parts.length > 1 ? parts[1] : '';
    final mId = parts.length > 2 ? parts[2] : '';
    final cPart = parts.length > 3 ? parts[3] : '';
    final url = 'https://mangakatana.com/manga/$slug.$mId/$cPart';

    final res = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://mangakatana.com/',
      },
    ).timeout(const Duration(seconds: 12));

    if (res.statusCode == 200) {
      final html = res.body;
      final arrayMatch = RegExp(r'var\s+thzq\s*=\s*\[([^\]]+)\]').firstMatch(html) ??
          RegExp(r'var\s+ytaw\s*=\s*\[([^\]]+)\]').firstMatch(html);

      if (arrayMatch != null) {
        final content = arrayMatch.group(1)!;
        final urlMatches = RegExp(r"'((?:https?:)?//[^']+)'").allMatches(content);
        final pages = <String>[];
        for (final m in urlMatches) {
          var pUrl = m.group(1)!;
          if (pUrl.startsWith('//')) pUrl = 'https:$pUrl';
          pages.add(pUrl);
        }

        if (pages.isNotEmpty) {
          return ChapterPages(chapterId: chapterId, pages: pages, dataSaver: pages);
        }
      }
    }
    throw Exception('Failed to load MangaKatana chapter pages');
  }

  // ---- MangaRead Direct Scraper (iOS & Web) ----

  Future<List<MangaItem>> _searchMangaRead({String? query, String? type, int page = 1, int limit = 24}) async {
    try {
      final String url;
      if (query != null && query.trim().isNotEmpty) {
        url = 'https://www.mangaread.org/page/$page/?s=${Uri.encodeComponent(query.trim())}&post_type=wp-manga';
      } else if (type == 'manhwa') {
        url = 'https://www.mangaread.org/genres/manhwa/page/$page/?m_orderby=latest';
      } else if (type == 'manhua') {
        url = 'https://www.mangaread.org/genres/manhua/page/$page/?m_orderby=latest';
      } else if (type == 'manga') {
        url = 'https://www.mangaread.org/genres/manga/page/$page/?m_orderby=latest';
      } else {
        url = 'https://www.mangaread.org/manga/page/$page/?m_orderby=latest';
      }

      final res = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
          'Accept': 'text/html,application/xhtml+xml',
        },
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode == 200) {
        final html = res.body;
        final cardRegex = RegExp(
          r'<div[^>]*class="[^"]*(?:item-thumb|tab-thumb)[^"]*"[^>]*>[\s\S]*?<a href="https://www\.mangaread\.org/manga/([^/]+)/"[^>]*title="([^"]*)"[^>]*>[\s\S]*?<img[^>]+(?:src|data-src)="([^"]+)"',
          caseSensitive: false,
        );

        final matches = cardRegex.allMatches(html);
        final items = <MangaItem>[];
        final seen = <String>{};

        for (final m in matches) {
          final slug = m.group(1)!;
          final title = _unescapeHtml(m.group(2)!.trim());
          final cover = m.group(3)!.trim();

          final id = 'mread:$slug';
          if (seen.contains(id)) continue;
          seen.add(id);

          items.add(MangaItem(
            id: id,
            title: title,
            cover: cover,
            type: type ?? (url.contains('manhwa') ? 'manhwa' : (url.contains('manhua') ? 'manhua' : 'manga')),
            source: 'mangaread',
          ));
          if (items.length >= limit) break;
        }
        return items;
      }
    } catch (e) {
      debugPrint('MangaRead search error: $e');
    }
    return [];
  }

  Future<MangaItem> _getMangaRead(String id) async {
    final slug = id.replaceFirst('mread:', '');
    final url = 'https://www.mangaread.org/manga/$slug/';

    final res = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
      },
    ).timeout(const Duration(seconds: 12));

    if (res.statusCode == 200) {
      final html = res.body;
      final titleMatch = RegExp(r'<div class="post-title">[\s\S]*?<h1>([^<]+)</h1>').firstMatch(html);
      final title = _unescapeHtml(titleMatch?.group(1)?.trim() ?? slug.replaceAll('-', ' '));

      final descMatch = RegExp(r'<div class="description-summary">[\s\S]*?<p>([\s\S]*?)</p>').firstMatch(html);
      final desc = _unescapeHtml(descMatch?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '');

      final coverMatch = RegExp(r'<div class="summary_image"[^>]*>[\s\S]*?<img[^>]+(?:src|data-src)="([^"]+)"').firstMatch(html);
      final cover = coverMatch?.group(1)?.trim() ?? '';

      final authorMatches = RegExp(r'<div class="author-content">[\s\S]*?<a[^>]*>([^<]+)</a>').allMatches(html);
      final authors = authorMatches.map((m) => _unescapeHtml(m.group(1)!.trim())).toList();

      final genreMatches = RegExp(r'<div class="genres-content">[\s\S]*?<a[^>]*>([^<]+)</a>').allMatches(html);
      final tags = genreMatches.map((m) => _unescapeHtml(m.group(1)!.trim())).toList();

      return MangaItem(
        id: id,
        title: title,
        description: desc,
        cover: cover,
        authors: authors,
        tags: tags,
        source: 'mangaread',
      );
    }
    throw Exception('Failed to load MangaRead manga details');
  }

  Future<List<ChapterItem>> _getMangaReadChapters(String mangaId) async {
    final slug = mangaId.replaceFirst('mread:', '');
    final url = 'https://www.mangaread.org/manga/$slug/';

    final res = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
      },
    ).timeout(const Duration(seconds: 12));

    if (res.statusCode == 200) {
      final html = res.body;
      final chapterRegex = RegExp(
        r'<li class="wp-manga-chapter[^>]*>[\s\S]*?<a href="https://www\.mangaread\.org/manga/[^/]+/([^/]+)/"[^>]*>([^<]+)</a>',
        caseSensitive: false,
      );

      final matches = chapterRegex.allMatches(html);
      final chapters = <ChapterItem>[];

      for (final m in matches) {
        final cSlug = m.group(1)!;
        final rawTitle = m.group(2)!.trim();
        final numMatch = RegExp(r'Chapter\s+([0-9.]+)').firstMatch(rawTitle);
        final num = numMatch?.group(1);

        chapters.add(ChapterItem(
          id: 'mread:$slug:$cSlug',
          title: rawTitle,
          number: num,
          source: 'mangaread',
        ));
      }
      return chapters;
    }
    return [];
  }

  Future<ChapterPages> _getMangaReadChapterPages(String chapterId) async {
    final parts = chapterId.split(':');
    final slug = parts.length > 1 ? parts[1] : '';
    final cSlug = parts.length > 2 ? parts[2] : '';
    final url = 'https://www.mangaread.org/manga/$slug/$cSlug/';

    final res = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://www.mangaread.org/',
      },
    ).timeout(const Duration(seconds: 12));

    if (res.statusCode == 200) {
      final html = res.body;
      final pageRegex = RegExp(r'<div class="page-break[^>]*>[\s\S]*?<img[^>]+(?:src|data-src)="([^"]+)"');
      final matches = pageRegex.allMatches(html);

      final pages = <String>[];
      for (final m in matches) {
        final imgUrl = m.group(1)?.trim();
        if (imgUrl != null && imgUrl.isNotEmpty) {
          pages.add(imgUrl);
        }
      }

      if (pages.isNotEmpty) {
        return ChapterPages(chapterId: chapterId, pages: pages, dataSaver: pages);
      }
    }
    throw Exception('Failed to load MangaRead chapter pages');
  }
}
