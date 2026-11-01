import 'dart:async';
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
  ApiService._() {
    ImageReferers.coverLookup = _resolveMissingCover;
  }

  Future<String?> _resolveMissingCover(String mangaId) async {
    try {
      final details = await getManga(mangaId);
      final cover = details.cover.trim();
      if (cover.isNotEmpty) {
        unawaited(updateCachedMangaMetadata(details));
        return cover;
      }
    } catch (_) {}
    return null;
  }

  String _baseUrl = '';
  String? _token;
  UserAccount? _currentUser;
  bool _initialized = false;
  bool _mongoConnected = false;
  http.Client _httpClient = http.Client();
  final Map<String, MangaItem> _localLibrary = {};
  final Map<String, MangaItem> _knownManga = {};
  final List<Map<String, dynamic>> _localHistory = [];
  final Map<String, Map<String, dynamic>> _localProgress = {};
  final Map<String, Set<String>> _readChapters = {};
  final Set<String> _bookmarkedChapterIds = {};
  final List<CategoryItem> _userCategories = [];
  final Map<String, List<String>> _mangaCategories = {};
  final Map<String, int> _mangaChapterCounts = {};

  @visibleForTesting
  void setHttpClient(http.Client? client) {
    _httpClient = client ?? http.Client();
  }

  // Request deduplication & short-TTL cache so concurrent getManga + getChapters
  // calls on the same series URL share a single network round-trip.
  final Map<String, Future<http.Response>> _inflightGets = {};
  final Map<String, ({http.Response response, DateTime expiresAt})> _responseCache = {};
  List<MangaItem>? _flameSeriesCache;
  DateTime? _flameCacheExpiresAt;

  Future<http.Response> _getCached(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
    Duration ttl = const Duration(seconds: 45),
    bool forceRefresh = false,
  }) {
    final key = uri.toString();
    final now = DateTime.now();
    if (!forceRefresh) {
      final cached = _responseCache[key];
      if (cached != null && now.isBefore(cached.expiresAt)) {
        return Future.value(cached.response);
      }
      final inflight = _inflightGets[key];
      if (inflight != null) return inflight;
    }

    final future = _httpClient.get(uri, headers: headers).timeout(timeout).then((res) {
      if (res.statusCode == 200) {
        if (_responseCache.length > 80) {
          final current = DateTime.now();
          _responseCache.removeWhere((_, v) => current.isAfter(v.expiresAt));
          if (_responseCache.length > 80) {
            _responseCache.remove(_responseCache.keys.first);
          }
        }
        _responseCache[key] = (response: res, expiresAt: DateTime.now().add(ttl));
      }
      return res;
    }).whenComplete(() {
      _inflightGets.remove(key);
    });

    _inflightGets[key] = future;
    return future;
  }

  static String _normalizeImgUrl(
    String? raw, {
    String? baseUrl,
    String? referer,
  }) {
    if (raw == null) return '';
    var u = raw
        .trim()
        .replaceAll('&amp;', '&')
        .replaceAll('\n', '')
        .replaceAll('\r', '')
        .replaceAll('\t', '');
    if (u.isEmpty) return '';
    final lower = u.toLowerCase();
    if (lower.startsWith('data:') ||
        lower.startsWith('javascript:') ||
        lower.startsWith('about:')) {
      return '';
    }
    if (u.startsWith('//')) {
      u = 'https:$u';
    } else if (!u.startsWith('http://') && !u.startsWith('https://') && !u.startsWith('file://')) {
      if (baseUrl != null && baseUrl.isNotEmpty) {
        final parsed = Uri.tryParse(baseUrl);
        if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
          final origin = '${parsed.scheme}://${parsed.host}${parsed.hasPort ? ':${parsed.port}' : ''}';
          u = u.startsWith('/') ? '$origin$u' : '$origin/$u';
        }
      }
    }
    if (u.contains(' ')) {
      u = u.replaceAll(' ', '%20');
    }
    if (referer != null && referer.isNotEmpty && u.startsWith('http')) {
      ImageReferers.register(u, referer);
    }
    return u;
  }

  static String _extractImgFromTag(
    String imgTag, {
    String? baseUrl,
    String? referer,
  }) {
    const attrs = [
      'data-src',
      'data-lazy-src',
      'data-cfsrc',
      'data-original',
      'data-echo',
      'data-bg',
      'src',
    ];
    for (final attr in attrs) {
      final m = RegExp(
        '(?:^|\\s)$attr\\s*=\\s*(?:"([^"]+)"|\'([^\']+)\'|([^\\s>"\']+))',
        caseSensitive: false,
      ).firstMatch(imgTag);
      if (m != null) {
        final rawVal = m.group(1) ?? m.group(2) ?? m.group(3);
        final candidate = _normalizeImgUrl(rawVal, baseUrl: baseUrl, referer: referer);
        if (_isValidContentImage(candidate)) return candidate;
      }
    }
    for (final attr in const ['data-srcset', 'srcset']) {
      final m = RegExp(
        '(?:^|\\s)$attr\\s*=\\s*(?:"([^"]+)"|\'([^\']+)\')',
        caseSensitive: false,
      ).firstMatch(imgTag);
      if (m != null) {
        final rawSet = m.group(1) ?? m.group(2) ?? '';
        final firstPart = rawSet.trim().split(RegExp(r'[\s,]+')).firstOrNull;
        final candidate = _normalizeImgUrl(firstPart, baseUrl: baseUrl, referer: referer);
        if (_isValidContentImage(candidate)) return candidate;
      }
    }
    final bgMatch = RegExp(
      r'''background(?:-image)?\s*:\s*url\(\s*['"]?([^'")\s]+)['"]?\s*\)''',
      caseSensitive: false,
    ).firstMatch(imgTag);
    if (bgMatch != null) {
      final candidate = _normalizeImgUrl(bgMatch.group(1), baseUrl: baseUrl, referer: referer);
      if (_isValidContentImage(candidate)) return candidate;
    }
    return '';
  }

  static bool _isValidContentImage(String url) {
    if (url.isEmpty || url.length < 8) return false;
    final lower = url.toLowerCase();
    if (lower.startsWith('data:')) return false;
    if (lower.endsWith('.svg') || lower.contains('.svg?')) return false;
    if (lower.contains('placeholder') ||
        lower.contains('1x1') ||
        lower.contains('blank.') ||
        lower.contains('spacer.')) {
      return false;
    }
    return true;
  }

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
    final prefs = await SharedPreferences.getInstance();
    final savedBase = prefs.getString('api_base_url');
    _baseUrl = savedBase ?? _determineDefaultHost();

    _token = prefs.getString('auth_token');
    _currentUser = null;
    final userJson = prefs.getString('auth_user');
    if (userJson != null && userJson.isNotEmpty) {
      try {
        _currentUser = UserAccount.fromJson(jsonDecode(userJson) as Map<String, dynamic>);
      } catch (_) {}
    }
    if (_token == null || _token!.isEmpty || _currentUser == null) {
      _token = null;
      _currentUser = null;
    }

    // Load local library / bookmarks
    _localLibrary.clear();
    final libJson = prefs.getString('shiori_local_library');
    if (libJson != null && libJson.isNotEmpty) {
      try {
        final List<dynamic> list = jsonDecode(libJson);
        for (final item in list) {
          final m = MangaItem.fromJson(item as Map<String, dynamic>);
          _localLibrary[m.id] = m;
          _knownManga[m.id] = m;
        }
      } catch (_) {}
    }

    // Load local history
    _localHistory.clear();
    final histJson = prefs.getString('shiori_local_history');
    if (histJson != null && histJson.isNotEmpty) {
      try {
        final List<dynamic> list = jsonDecode(histJson);
        for (final item in list) {
          if (item is Map) _localHistory.add(Map<String, dynamic>.from(item));
        }
      } catch (_) {}
    }

    // Load local progress
    _localProgress.clear();
    final progJson = prefs.getString('shiori_local_progress');
    if (progJson != null && progJson.isNotEmpty) {
      try {
        final Map<String, dynamic> map = jsonDecode(progJson);
        map.forEach((k, v) {
          if (v is Map) _localProgress[k] = Map<String, dynamic>.from(v);
        });
      } catch (_) {}
    }

    // Load read chapters
    _readChapters.clear();
    final readJson = prefs.getString('shiori_read_chapters');
    if (readJson != null && readJson.isNotEmpty) {
      try {
        final Map<String, dynamic> map = jsonDecode(readJson);
        map.forEach((k, v) {
          if (v is List) {
            _readChapters[k] = v.map((e) => e.toString()).toSet();
          }
        });
      } catch (_) {}
    }

    // Load chapter bookmarks
    _bookmarkedChapterIds.clear();
    final bmJson = prefs.getString('shiori_chapter_bookmarks');
    if (bmJson != null && bmJson.isNotEmpty) {
      try {
        final List<dynamic> list = jsonDecode(bmJson);
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
    _mangaCategories.clear();
    final mangaCatJson = prefs.getString('shiori_manga_categories');
    if (mangaCatJson != null && mangaCatJson.isNotEmpty) {
      try {
        final Map<String, dynamic> map = jsonDecode(mangaCatJson);
        map.forEach((k, v) {
          if (v is List) {
            _mangaCategories[k] = v.map((e) => e.toString()).toList();
          }
        });
      } catch (_) {}
    }

    // Load manga chapter counts for unread badges
    _mangaChapterCounts.clear();
    final chapterCountsJson = prefs.getString('shiori_manga_chapter_counts');
    if (chapterCountsJson != null && chapterCountsJson.isNotEmpty) {
      try {
        final Map<String, dynamic> map = jsonDecode(chapterCountsJson);
        map.forEach((k, v) {
          if (v is num) _mangaChapterCounts[k] = v.toInt();
        });
      } catch (_) {}
    }

    final firstInit = !_initialized;
    _initialized = true;
    if (firstInit) {
      unawaited(checkHealth());
      if (isLoggedIn) {
        unawaited(syncAllCloudData());
      }
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
      final res = await _httpClient.get(Uri.parse('$_baseUrl/health')).timeout(const Duration(seconds: 4));
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

  // ---- Auth & Automatic Real-Time Cloud Sync ----

  static String _extractAuthError(http.Response res, {required String fallback}) {
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map) {
        final msg = (decoded['error'] ?? decoded['message'])?.toString().trim();
        if (msg != null && msg.isNotEmpty) return msg;
      }
    } catch (_) {}
    if (res.statusCode == 409) return 'Email is already registered';
    if (res.statusCode == 401) return 'Invalid email or password';
    if (res.statusCode == 429) return 'Too many attempts. Please try again later.';
    if (res.statusCode >= 500) return 'Server error (${res.statusCode}). Please try again later.';
    return fallback;
  }

  Future<void> register(String email, String password, {String? displayName}) async {
    final trimmedEmail = email.trim();
    if (trimmedEmail.isEmpty || password.isEmpty) {
      throw Exception('Please fill in email and password.');
    }

    final http.Response res;
    try {
      res = await _httpClient
          .post(
            Uri.parse('$_baseUrl/auth/register'),
            headers: _headers(withAuth: false),
            body: jsonEncode({
              'email': trimmedEmail,
              'password': password,
              if (displayName != null && displayName.trim().isNotEmpty)
                'displayName': displayName.trim(),
            }),
          )
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw Exception('Connection timed out. Server may be unreachable.');
    } catch (e) {
      throw Exception('Network error: Unable to reach server.');
    }

    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception(_extractAuthError(res, fallback: 'Registration failed'));
    }

    final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) throw const FormatException('Not a JSON object');
      data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      throw Exception('Invalid response from server.');
    }

    final token = data['token']?.toString() ?? '';
    final userRaw = data['user'];
    if (token.isEmpty || userRaw is! Map) {
      throw Exception('Invalid authentication payload from server.');
    }

    await _saveAuthData(token, UserAccount.fromJson(Map<String, dynamic>.from(userRaw)));
    // Automatically bi-directionally sync library and reading history with MongoDB
    await syncAllCloudData();
  }

  Future<void> login(String email, String password) async {
    final trimmedEmail = email.trim();
    if (trimmedEmail.isEmpty || password.isEmpty) {
      throw Exception('Please fill in email and password.');
    }

    final http.Response res;
    try {
      res = await _httpClient
          .post(
            Uri.parse('$_baseUrl/auth/login'),
            headers: _headers(withAuth: false),
            body: jsonEncode({'email': trimmedEmail, 'password': password}),
          )
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw Exception('Connection timed out. Server may be unreachable.');
    } catch (e) {
      throw Exception('Network error: Unable to reach server.');
    }

    if (res.statusCode != 200) {
      throw Exception(_extractAuthError(res, fallback: 'Login failed'));
    }

    final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) throw const FormatException('Not a JSON object');
      data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      throw Exception('Invalid response from server.');
    }

    final token = data['token']?.toString() ?? '';
    final userRaw = data['user'];
    if (token.isEmpty || userRaw is! Map) {
      throw Exception('Invalid authentication payload from server.');
    }

    await _saveAuthData(token, UserAccount.fromJson(Map<String, dynamic>.from(userRaw)));
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
    for (final manga in _localLibrary.values.toList()) {
      try {
        await _httpClient.post(
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
      final res = await _httpClient.get(
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
          _knownManga[m.id] = m;
        }
        await _persistLocalLibrary();
      }
    } catch (_) {}

    // 3. Fetch cloud reading history & progress and merge into local state
    try {
      final res = await _httpClient.get(
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
      return _searchFlameComics(query: query, type: type, order: order, page: page, limit: limit);
    }
    if (s == 'weebcentral' || s == 'weeb') {
      return _searchWeebCentral(query: query, type: type, order: order, page: page, limit: limit);
    }
    if (s == 'mangapill' || s == 'pill') {
      return _searchMangaPill(query: query, type: type, page: page, limit: limit);
    }
    if (s == 'mangakatana' || s == 'katana') {
      return _searchMangaKatana(query: query, type: type, order: order, page: page, limit: limit);
    }
    if (s == 'mangaread' || s == 'mread') {
      return _searchMangaRead(query: query, type: type, order: order, page: page, limit: limit);
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

    final selectorIdx = pkg.indexOf('@');
    final selectorSuffix = selectorIdx != -1 ? pkg.substring(selectorIdx) : '';
    final ext = ExtensionService.instance.getExtensionByPkg(pkg);
    final effectivePkg = ext != null ? '${ext.pkg}$selectorSuffix' : pkg;

    try {
      final hasQuery = query != null && query.trim().isNotEmpty;
      final results = hasQuery
          ? await ExtensionBridge.instance.searchManga(
              pkg: effectivePkg,
              query: query.trim(),
              page: page,
              type: type,
            )
          : (order == 'latest'
              ? await ExtensionBridge.instance.fetchLatestUpdates(
                  pkg: effectivePkg,
                  page: page,
                  type: type,
                )
              : await ExtensionBridge.instance.fetchPopularManga(
                  pkg: effectivePkg,
                  page: page,
                  type: type,
                ));

      if (results.isNotEmpty) return results;
    } catch (e) {
      debugPrint('ExtensionBridge native execution for $effectivePkg encountered: $e');
      if (ext != null && ext.homeUrl.isNotEmpty) {
        try {
          final webResults = await _searchWebManga(
            ext,
            sourcePkg: effectivePkg,
            query: query,
            order: order,
            page: page,
            limit: limit,
          );
          if (webResults.isNotEmpty) return webResults;
        } catch (_) {}
      }
      rethrow;
    }

    // Secondary fallback to web scraper ONLY if homeUrl is present
    if (ext != null && ext.homeUrl.isNotEmpty) {
      return _searchWebManga(
        ext,
        sourcePkg: effectivePkg,
        query: query,
        order: order,
        page: page,
        limit: limit,
      );
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
          try {
            final webChapters = await _getWebChapters(pkg, actualId, ext: ext);
            if (webChapters.isNotEmpty) return webChapters;
          } catch (_) {}
        }
        rethrow;
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

  Future<ChapterPages> getChapterPages(String chapterId, {bool forceRefresh = false}) async {
    // 1. Check offline downloaded pages first (unless explicitly forcing fresh remote reload)
    if (!forceRefresh && DownloadService.instance.isChapterDownloaded(chapterId)) {
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
    // 1. Direct MangaDex API first (~250ms, avoids stalling on cold Render backend)
    try {
      final qParams = <String, dynamic>{
        'limit': limit.clamp(1, 50).toString(),
        'offset': ((page - 1) * limit).toString(),
        'includes[]': ['cover_art', 'author', 'artist'],
        'contentRating[]': ['safe', 'suggestive', 'erotica'],
        'hasAvailableChapters': 'true',
      };
      if (query != null && query.trim().isNotEmpty) {
        qParams['title'] = query.trim();
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
        qParams['originalLanguage[]'] = ['ko'];
      } else if (type == 'manhua') {
        qParams['originalLanguage[]'] = ['zh', 'zh-hk'];
      } else if (type == 'manga') {
        qParams['originalLanguage[]'] = ['ja'];
      }

      if (lang != null && lang.isNotEmpty && lang.toLowerCase() != 'all') {
        qParams['availableTranslatedLanguage[]'] = [lang.toLowerCase()];
      } else {
        qParams['availableTranslatedLanguage[]'] = ['en'];
      }

      final uri = Uri.https('api.mangadex.org', '/manga', qParams);
      final res = await _getCached(
        uri,
        headers: const {'User-Agent': 'ShioriApp/1.0', 'Accept': 'application/json'},
        timeout: const Duration(seconds: 8),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['data'] as List<dynamic>?) ?? [];
        return list.map((m) => _normalizeDirectManga(m as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      debugPrint('_searchMangaCatalog direct error: $e');
    }

    // 2. Fallback to Backend proxy if direct API is unreachable
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
      final res = await http.get(uri, headers: _headers(withAuth: false)).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['items'] as List<dynamic>?) ?? [];
        if (list.isNotEmpty) {
          return list.map((e) => MangaItem.fromJson(e as Map<String, dynamic>)).toList();
        }
      }
    } catch (_) {}

    return [];
  }

  Future<MangaItem> _getMangaById(String actualId) async {
    // 1. Direct MangaDex API first
    try {
      final uri = Uri.https('api.mangadex.org', '/manga/$actualId', {
        'includes[]': ['cover_art', 'author', 'artist'],
      });
      final res = await _getCached(
        uri,
        headers: const {'User-Agent': 'ShioriApp/1.0', 'Accept': 'application/json'},
        timeout: const Duration(seconds: 8),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final m = data['data'] as Map<String, dynamic>? ?? {};
        return _normalizeDirectManga(m);
      }
    } catch (_) {}

    // 2. Fallback to Backend
    try {
      final res = await http.get(Uri.parse('$_baseUrl/manga/$actualId'), headers: _headers(withAuth: false)).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        return MangaItem.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
    } catch (_) {}

    throw Exception('Failed to load manga details');
  }

  Future<List<ChapterItem>> _getChaptersById(String actualId, {String lang = 'en'}) async {
    // 1. Direct MangaDex API first
    try {
      final qParams = <String, dynamic>{
        'limit': '300',
        'order[chapter]': 'desc',
        'contentRating[]': ['safe', 'suggestive', 'erotica'],
        'includes[]': ['scanlation_group'],
      };
      if (lang.isNotEmpty && lang != 'all') {
        qParams['translatedLanguage[]'] = [lang];
      }
      final uri = Uri.https('api.mangadex.org', '/manga/$actualId/feed', qParams);
      final res = await _getCached(
        uri,
        headers: const {'User-Agent': 'ShioriApp/1.0', 'Accept': 'application/json'},
        timeout: const Duration(seconds: 9),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['data'] as List<dynamic>?) ?? [];
        final parsed = <ChapterItem>[];
        for (final c in list) {
          final a = c['attributes'] as Map<String, dynamic>? ?? {};
          final pagesCount = (a['pages'] as num?)?.toInt() ?? 0;
          final extUrl = a['externalUrl']?.toString() ?? '';
          // Skip external-only stubs (e.g. MangaPlus redirect with 0 hosted pages)
          if (extUrl.isNotEmpty && pagesCount == 0) continue;

          final rels = (c['relationships'] as List<dynamic>?) ?? [];
          final grpRel = rels.firstWhere((r) => r['type'] == 'scanlation_group', orElse: () => null);
          final groupName = grpRel != null && grpRel['attributes'] != null
              ? grpRel['attributes']['name']?.toString() ?? ''
              : '';
          parsed.add(ChapterItem(
            id: c['id']?.toString() ?? '',
            number: a['chapter']?.toString(),
            volume: a['volume']?.toString(),
            title: a['title']?.toString() ?? '',
            pages: pagesCount,
            group: groupName,
            publishAt: a['publishAt']?.toString() ?? a['readableAt']?.toString(),
            source: 'mangadex',
          ));
        }
        return parsed;
      }
    } catch (_) {}

    // 2. Fallback to Backend
    try {
      final uri = Uri.parse('$_baseUrl/manga/$actualId/chapters').replace(queryParameters: {
        if (lang.isNotEmpty) 'lang': lang,
      });
      final res = await http.get(uri, headers: _headers(withAuth: false)).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['chapters'] as List<dynamic>?) ?? [];
        return list.map((e) => ChapterItem.fromJson(e as Map<String, dynamic>)).toList();
      }
    } catch (_) {}

    return [];
  }

  Future<ChapterPages> _getChapterPagesById(String actualChapterId) async {
    // 1. Direct MangaDex@Home server resolution first
    try {
      final res = await http.get(
        Uri.parse('https://api.mangadex.org/at-home/server/$actualChapterId'),
        headers: const {'User-Agent': 'ShioriApp/1.0', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final baseUrl = data['baseUrl']?.toString() ?? 'https://uploads.mangadex.org';
        final chapterObj = data['chapter'] as Map<String, dynamic>? ?? {};
        final hash = chapterObj['hash']?.toString() ?? '';
        final dataList = (chapterObj['data'] as List<dynamic>?) ?? [];
        final dataSaverList = (chapterObj['dataSaver'] as List<dynamic>?) ?? [];
        final pages = dataList.map((fn) {
          final u = '$baseUrl/data/$hash/$fn';
          ImageReferers.register(u, 'https://mangadex.org/');
          return u;
        }).toList();
        // Use official uploads.mangadex.org data-saver when baseUrl is a volunteer node
        // so flaky @home nodes fall back cleanly to the primary CDN.
        final saverHost = baseUrl == 'https://uploads.mangadex.org'
            ? baseUrl
            : 'https://uploads.mangadex.org';
        final saver = dataSaverList.map((fn) {
          final u = '$saverHost/data-saver/$hash/$fn';
          ImageReferers.register(u, 'https://mangadex.org/');
          return u;
        }).toList();
        return ChapterPages(chapterId: actualChapterId, pages: pages, dataSaver: saver);
      }
    } catch (_) {}

    // 2. Fallback to Backend
    try {
      final res = await http.get(
        Uri.parse('$_baseUrl/manga/chapter/$actualChapterId/pages'),
        headers: _headers(withAuth: false),
      ).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        return ChapterPages.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
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
        ? _normalizeImgUrl(
            'https://uploads.mangadex.org/covers/$id/$fileName.512.jpg',
            referer: 'https://mangadex.org/',
          )
        : '';

    final authors = rels
        .where((r) => r['type'] == 'author' || r['type'] == 'artist')
        .map((r) => (r['attributes'] as Map<String, dynamic>?)?['name']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList();

    final tags = ((a['tags'] as List<dynamic>?) ?? [])
        .map((t) => (t['attributes']?['name'] as Map?)?['en']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();

    return MangaItem(
      id: id,
      title: title,
      description: desc,
      cover: coverUrl,
      authors: authors,
      tags: tags,
      status: a['status']?.toString() ?? '',
      type: type,
      lastChapter: a['lastChapter']?.toString(),
      source: 'mangadex',
    );
  }

  Future<List<MangaItem>> _searchAsura({String? query, String? type, int page = 1}) async {
    if (type != null && type.isNotEmpty && type != 'all' && type != 'manhwa') {
      // Asura Scans specializes in Korean Manhwa
      return [];
    }
    final uri = Uri.parse('https://api.asurascans.com/api/series').replace(queryParameters: {
      if (query != null && query.trim().isNotEmpty) 'search': query.trim(),
      'page': page.toString(),
    });
    final res = await _getCached(
      uri,
      headers: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'application/json',
      },
      timeout: const Duration(seconds: 8),
    );

    _checkResponseHealth(res, 'Asura Scans');

    if (res.statusCode == 200) {
      final clean = res.body.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
      final data = jsonDecode(clean) as Map<String, dynamic>;
      final list = (data['data'] as List<dynamic>?) ?? [];
      return list.map((item) {
        final latest = item['latest_chapters'] as List<dynamic>?;
        final chNum = latest != null && latest.isNotEmpty ? latest[0]['number']?.toString() : null;
        final desc = (item['description']?.toString() ?? '').replaceAll(RegExp(r'<[^>]*>'), '').trim();
        final cover = _normalizeImgUrl(
          item['cover']?.toString() ?? item['thumb']?.toString(),
          baseUrl: 'https://asurascans.com',
          referer: 'https://asurascans.com/',
        );
        return MangaItem(
          id: 'asura:${item['slug']}',
          title: _unescapeHtml(item['title']?.toString() ?? 'Untitled'),
          description: _unescapeHtml(desc),
          cover: cover,
          status: item['status']?.toString() ?? '',
          type: item['type']?.toString() ?? 'manhwa',
          lastChapter: chNum,
          source: 'asura',
        );
      }).toList();
    }
    return [];
  }

  Future<MangaItem> _getAsuraManga(String id) async {
    final cleanSlug = id.replaceFirst('asura:', '');
    final uri = Uri.parse('https://api.asurascans.com/api/series/$cleanSlug');
    final res = await _getCached(
      uri,
      headers: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'application/json',
      },
      timeout: const Duration(seconds: 8),
    );

    _checkResponseHealth(res, 'Asura Scans');

    if (res.statusCode == 200) {
      final clean = res.body.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
      final data = jsonDecode(clean) as Map<String, dynamic>;
      final rawInner = data['data'];
      final s = (rawInner is Map<String, dynamic>
              ? (rawInner['series'] as Map<String, dynamic>? ?? rawInner)
              : null) ??
          (data['series'] as Map<String, dynamic>?) ??
          data;
      final desc = (s['description']?.toString() ?? s['synopsis']?.toString() ?? '')
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .trim();
      final genres = (s['genres'] as List<dynamic>?)
              ?.map((g) => (g is Map ? g['name']?.toString() : g?.toString()) ?? '')
              .where((g) => g.isNotEmpty)
              .toList() ??
          [];
      final cover = _normalizeImgUrl(
        s['cover']?.toString() ??
            s['thumb']?.toString() ??
            s['cover_url']?.toString() ??
            s['poster']?.toString() ??
            s['image']?.toString(),
        baseUrl: 'https://asurascans.com',
        referer: 'https://asurascans.com/',
      );
      return MangaItem(
        id: 'asura:$cleanSlug',
        title: _unescapeHtml(s['title']?.toString() ?? 'Untitled'),
        description: _unescapeHtml(desc),
        cover: cover,
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
    final res = await _getCached(
      uri,
      headers: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'application/json',
      },
      timeout: const Duration(seconds: 8),
    );

    _checkResponseHealth(res, 'Asura Scans');

    if (res.statusCode == 200) {
      final clean = res.body.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
      final data = jsonDecode(clean) as Map<String, dynamic>;
      final list = (data['data'] as List<dynamic>?) ?? [];
      final chapters = <ChapterItem>[];
      for (final ch in list) {
        if (ch['is_locked'] == true) continue;
        final chSlug = ch['slug']?.toString() ?? '';
        if (chSlug.isEmpty) continue;
        chapters.add(ChapterItem(
          id: 'asura:$cleanSlug:$chSlug',
          number: ch['number']?.toString(),
          title: ch['title']?.toString() ?? '',
          group: 'Asura Scans',
          publishAt: ch['published_at']?.toString(),
          pages: (ch['page_count'] as num?)?.toInt() ?? 0,
          source: 'asura',
        ));
      }

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
    final res = await http.get(uri, headers: const {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      'Accept': 'application/json',
      'Referer': 'https://asurascans.com/',
    }).timeout(const Duration(seconds: 10));

    _checkResponseHealth(res, 'Asura Scans');

    if (res.statusCode == 200) {
      final clean = res.body.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
      final data = jsonDecode(clean) as Map<String, dynamic>;
      final chapterObj = data['data']?['chapter'] as Map<String, dynamic>?;
      final pagesList = (chapterObj?['pages'] as List<dynamic>?)
              ?.map((p) => _normalizeImgUrl(
                    p['url']?.toString(),
                    baseUrl: 'https://asurascans.com',
                    referer: 'https://asurascans.com/',
                  ))
              .where((u) => u.isNotEmpty)
              .toList() ??
          [];
      if (pagesList.isEmpty && chapterObj?['is_locked'] == true) {
        throw Exception('This chapter is currently Early Access / locked on Asura Scans.');
      }
      return ChapterPages(chapterId: chapterId, pages: pagesList, dataSaver: pagesList);
    }
    throw Exception('Failed to load Asura chapter pages');
  }

  // ---- Flame Comics Scraper ----

  Future<List<MangaItem>> _loadFlameSeriesList() async {
    final now = DateTime.now();
    if (_flameSeriesCache != null &&
        _flameCacheExpiresAt != null &&
        now.isBefore(_flameCacheExpiresAt!)) {
      return _flameSeriesCache!;
    }

    final res = await _getCached(
      Uri.parse('https://flamecomics.xyz/browse'),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
      timeout: const Duration(seconds: 10),
      ttl: const Duration(minutes: 3),
    );

    _checkResponseHealth(res, 'Flame Comics');

    if (res.statusCode == 200) {
      final html = res.body;
      final idx = html.indexOf('<script id="__NEXT_DATA__"');
      if (idx == -1) return [];
      final end = html.indexOf('</script>', idx);
      if (end == -1) return [];
      final jsonStr = html.substring(html.indexOf('>', idx) + 1, end);
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final seriesList = (data['props']?['pageProps']?['series'] as List<dynamic>?) ?? [];

      final items = seriesList.map((item) {
        final sId = item['series_id']?.toString() ?? '';
        final coverFile = item['cover']?.toString() ?? '';
        final rawCover = coverFile.startsWith('http')
            ? coverFile
            : (coverFile.isNotEmpty
                ? 'https://cdn.flamecomics.xyz/uploads/images/series/$sId/$coverFile'
                : '');
        final coverUrl = _normalizeImgUrl(rawCover, referer: 'https://flamecomics.xyz/');
        final cats = (item['categories'] as List<dynamic>?)?.map((c) => c.toString()).toList() ?? <String>[];
        final authors = (item['author'] as List<dynamic>?)?.map((a) => a.toString()).toList() ?? <String>[];

        return MangaItem(
          id: 'flame:$sId',
          title: _unescapeHtml(item['title']?.toString() ?? 'Untitled'),
          description: _unescapeHtml((item['description']?.toString() ?? '').replaceAll(RegExp(r'<[^>]*>'), '').trim()),
          cover: coverUrl,
          status: item['status']?.toString() ?? '',
          type: item['type']?.toString().toLowerCase() ?? 'manhwa',
          tags: cats,
          authors: authors,
          source: 'flamecomics',
        );
      }).toList();

      if (items.isNotEmpty) {
        _flameSeriesCache = items;
        _flameCacheExpiresAt = DateTime.now().add(const Duration(minutes: 3));
      }
      return items;
    }
    return [];
  }

  Future<List<MangaItem>> _searchFlameComics({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
  }) async {
    var items = List<MangaItem>.from(await _loadFlameSeriesList());
    if (items.isEmpty) return [];

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
      // Rank title matches ahead of description-only matches
      items.sort((a, b) {
        final aTitle = a.title.toLowerCase().contains(q) ? 0 : 1;
        final bTitle = b.title.toLowerCase().contains(q) ? 0 : 1;
        return aTitle.compareTo(bTitle);
      });
    }

    final start = (page - 1) * limit;
    if (start >= items.length) return [];
    return items.skip(start).take(limit).toList();
  }

  Future<MangaItem> _getFlameManga(String id) async {
    final sId = id.replaceFirst('flame:', '');
    final res = await _getCached(
      Uri.parse('https://flamecomics.xyz/series/$sId'),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
      timeout: const Duration(seconds: 10),
    );

    _checkResponseHealth(res, 'Flame Comics');

    if (res.statusCode == 200) {
      final html = res.body;
      final idx = html.indexOf('<script id="__NEXT_DATA__"');
      if (idx != -1) {
        final end = html.indexOf('</script>', idx);
        final jsonStr = html.substring(html.indexOf('>', idx) + 1, end);
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        final s = data['props']?['pageProps']?['series'] as Map<String, dynamic>? ?? {};
        final coverFile = s['cover']?.toString() ?? '';
        final rawCover = coverFile.startsWith('http')
            ? coverFile
            : (coverFile.isNotEmpty
                ? 'https://cdn.flamecomics.xyz/uploads/images/series/$sId/$coverFile'
                : '');
        final coverUrl = _normalizeImgUrl(rawCover, referer: 'https://flamecomics.xyz/');
        final cats = (s['categories'] as List<dynamic>?)?.map((c) => c.toString()).toList() ?? <String>[];
        final authors = (s['author'] as List<dynamic>?)?.map((a) => a.toString()).toList() ?? <String>[];

        return MangaItem(
          id: id,
          title: _unescapeHtml(s['title']?.toString() ?? 'Untitled'),
          description: _unescapeHtml((s['description']?.toString() ?? '').replaceAll(RegExp(r'<[^>]*>'), '').trim()),
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
    final res = await _getCached(
      Uri.parse('https://flamecomics.xyz/series/$sId'),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
      timeout: const Duration(seconds: 10),
    );

    _checkResponseHealth(res, 'Flame Comics');

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
            group: 'Flame Comics',
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
      headers: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'Referer': 'https://flamecomics.xyz/',
      },
    ).timeout(const Duration(seconds: 10));

    _checkResponseHealth(res, 'Flame Comics');

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
                final u = _normalizeImgUrl(
                  'https://cdn.flamecomics.xyz/uploads/images/series/$sId/$token/$name',
                  referer: 'https://flamecomics.xyz/',
                );
                if (u.isNotEmpty) pagesList.add(u);
              }
            }
          }
        } else if (imgsObj is List) {
          for (final entry in imgsObj) {
            final name = entry is Map ? entry['name']?.toString() ?? '' : entry.toString();
            if (name.isNotEmpty) {
              final u = _normalizeImgUrl(
                name.startsWith('http')
                    ? name
                    : 'https://cdn.flamecomics.xyz/uploads/images/series/$sId/$token/$name',
                referer: 'https://flamecomics.xyz/',
              );
              if (u.isNotEmpty) pagesList.add(u);
            }
          }
        }
        return ChapterPages(chapterId: chapterId, pages: pagesList, dataSaver: pagesList);
      }
    }
    throw Exception('Failed to load Flame Comics chapter pages');
  }

  // ---- Weeb Central Scraper ----

  Future<List<MangaItem>> _searchWeebCentral({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
  }) async {
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

    final offset = (page - 1) * limit;
    final String url;
    if (query != null && query.trim().isNotEmpty) {
      url = 'https://weebcentral.com/search/data?limit=$limit&offset=$offset&text=${Uri.encodeComponent(query.trim())}&sort=Best%20Match&order=Descending&display_mode=Full%20Display$typeParam';
    } else {
      final sort = order == 'latest' ? 'Updated%20At' : 'Popularity';
      url = 'https://weebcentral.com/search/data?limit=$limit&offset=$offset&sort=$sort&order=Descending&display_mode=Full%20Display$typeParam';
    }
    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'HX-Request': 'true',
        'Referer': 'https://weebcentral.com/search',
      },
      timeout: const Duration(seconds: 10),
    );

    _checkResponseHealth(res, 'Weeb Central');

    if (res.statusCode == 200) {
      final html = res.body;
      final articles = html.split('<article').skip(1);
      final items = <MangaItem>[];
      final seen = <String>{};

      for (final art in articles) {
        final seriesMatch = RegExp(r'href="(?:https://weebcentral\.com)?/series/([A-Z0-9]+)/([^"#?]+)"').firstMatch(art);
        if (seriesMatch == null) continue;
        final sId = seriesMatch.group(1)!;
        final slug = seriesMatch.group(2)!;
        final itemId = 'weeb:$sId:$slug';
        if (!seen.add(itemId)) continue;

        final sourceMatch = RegExp(r'<source[^>]+srcset="([^"]+)"').firstMatch(art);
        final imgTagMatch = RegExp(r'<img\b[^>]*>').firstMatch(art);
        var coverUrl = _normalizeImgUrl(
          sourceMatch?.group(1),
          baseUrl: 'https://weebcentral.com',
          referer: 'https://weebcentral.com/',
        );
        if (coverUrl.isEmpty && imgTagMatch != null) {
          final extracted = _extractImgFromTag(
            imgTagMatch.group(0)!,
            baseUrl: 'https://weebcentral.com',
            referer: 'https://weebcentral.com/',
          );
          if (!extracted.contains('/static/')) coverUrl = extracted;
        }
        if (coverUrl.isEmpty) {
          coverUrl = _normalizeImgUrl(
            'https://temp.compsci88.com/cover/normal/$sId.webp',
            referer: 'https://weebcentral.com/',
          );
        }

        final titleMatch = RegExp(r'<a[^>]+class="[^"]*link-hover[^"]*"[^>]*>([\s\S]*?)</a>').firstMatch(art) ??
            RegExp(r'href="(?:https://weebcentral\.com)?/series/[^/]+/[^"]+">([^<]+)</a>').firstMatch(art);
        final rawTitle = titleMatch?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '';
        final title = _unescapeHtml(rawTitle.isNotEmpty ? rawTitle : slug.replaceAll('-', ' '));

        items.add(MangaItem(
          id: itemId,
          title: title,
          cover: coverUrl,
          type: type ?? 'manga',
          source: 'weebcentral',
        ));
      }
      return items;
    }
    return [];
  }

  Future<MangaItem> _getWeebManga(String id) async {
    final parts = id.split(':');
    final sId = parts.length > 1 ? parts[1] : '';
    final slug = parts.length > 2 ? parts[2] : '';
    final url = 'https://weebcentral.com/series/$sId/$slug';

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
      timeout: const Duration(seconds: 10),
    );

    _checkResponseHealth(res, 'Weeb Central');

    if (res.statusCode == 200) {
      final html = res.body;
      final titleMatch = RegExp(r'<h1[^>]*>([^<]+)</h1>').firstMatch(html);
      final title = _unescapeHtml(titleMatch?.group(1)?.trim() ?? slug.replaceAll('-', ' '));

      final descMatch = RegExp(r'<p class="whitespace-pre-line[^"]*">([\s\S]*?)</p>').firstMatch(html);
      final desc = _unescapeHtml(descMatch?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '');

      final picMatch = RegExp(r'<picture[^>]*>[\s\S]*?<source[^>]+srcset="([^"]+)"').firstMatch(html) ??
          RegExp(r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"').firstMatch(html);
      var coverUrl = _normalizeImgUrl(
        picMatch?.group(1),
        baseUrl: 'https://weebcentral.com',
        referer: 'https://weebcentral.com/',
      );
      if (coverUrl.isEmpty || coverUrl.contains('/static/')) {
        coverUrl = _normalizeImgUrl(
          'https://temp.compsci88.com/cover/normal/$sId.webp',
          referer: 'https://weebcentral.com/',
        );
      }

      final authors = RegExp(r'href="[^"]*author=[^"]*"[^>]*>([^<]+)</a>')
          .allMatches(html)
          .map((m) => _unescapeHtml(m.group(1)!.trim()))
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();
      final tags = RegExp(r'href="[^"]*included_tag=[^"]*"[^>]*>([^<]+)</a>')
          .allMatches(html)
          .map((m) => _unescapeHtml(m.group(1)!.trim()))
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();

      return MangaItem(
        id: id,
        title: title,
        description: desc,
        cover: coverUrl,
        authors: authors,
        tags: tags,
        source: 'weebcentral',
      );
    }
    throw Exception('Failed to load Weeb Central series details');
  }

  Future<List<ChapterItem>> _getWeebChapters(String id) async {
    final parts = id.split(':');
    final sId = parts.length > 1 ? parts[1] : '';
    final url = 'https://weebcentral.com/series/$sId/full-chapter-list';

    final res = await _getCached(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'HX-Request': 'true',
        'Referer': 'https://weebcentral.com/series/$sId',
      },
      timeout: const Duration(seconds: 10),
    );

    _checkResponseHealth(res, 'Weeb Central');

    if (res.statusCode == 200) {
      final html = res.body;
      final regex = RegExp(
        r'<a[^>]+href="(?:https://weebcentral\.com)?/chapters/([A-Z0-9]+)"[^>]*>([\s\S]*?)</a>',
        caseSensitive: false,
      );
      final matches = regex.allMatches(html);
      final list = <ChapterItem>[];
      final seen = <String>{};

      for (final m in matches) {
        final chId = m.group(1)!;
        if (!seen.add(chId)) continue;
        final block = m.group(2)!;
        final spanMatch = RegExp(r'<span class="">([^<]+)</span>').firstMatch(block);
        final chText = _unescapeHtml(
          (spanMatch?.group(1) ?? block.replaceAll(RegExp(r'<[^>]*>'), '')).trim(),
        );
        final numMatch = RegExp(r'(?:Chapter|Episode|Ch\.?)\s*([\d\.]+)', caseSensitive: false).firstMatch(chText);
        final chNum = numMatch?.group(1);
        final timeMatch = RegExp(r'datetime="([^"]+)"').firstMatch(block);

        list.add(ChapterItem(
          id: 'weeb:$chId',
          number: chNum,
          title: chText.isNotEmpty ? chText : 'Chapter',
          publishAt: timeMatch?.group(1),
          group: 'Weeb Central',
          source: 'weebcentral',
        ));
      }
      return list;
    }
    return [];
  }

  Future<ChapterPages> _getWeebChapterPages(String chapterId) async {
    final cleanId = chapterId.replaceFirst('weeb:', '');
    final url = 'https://weebcentral.com/chapters/$cleanId/images?is_prev=False&current_page=1&reading_style=long_strip';

    final res = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'HX-Request': 'true',
        'Referer': 'https://weebcentral.com/chapters/$cleanId',
      },
    ).timeout(const Duration(seconds: 12));

    _checkResponseHealth(res, 'Weeb Central');

    if (res.statusCode == 200) {
      final html = res.body;
      final imgTags = RegExp(r'<img\b[^>]*>', caseSensitive: false).allMatches(html);
      final pagesList = <String>[];
      final seen = <String>{};
      for (final m in imgTags) {
        final u = _extractImgFromTag(
          m.group(0)!,
          baseUrl: 'https://weebcentral.com',
          referer: 'https://weebcentral.com/',
        );
        if (u.isEmpty || u.contains('/static/') || u.contains('logo') || u.contains('avatar')) {
          continue;
        }
        if (seen.add(u)) {
          pagesList.add(u);
        }
      }

      if (pagesList.isNotEmpty) {
        return ChapterPages(chapterId: chapterId, pages: pagesList, dataSaver: pagesList);
      }
    }
    throw Exception('Failed to load Weeb Central chapter pages');
  }

  // ---- Bookmarks & Library (Local-First + Cloud Sync) ----

  bool isInLibrary(String mangaId) => _localLibrary.containsKey(mangaId);

  void cacheKnownManga(MangaItem manga) {
    if (manga.id.isNotEmpty) {
      _knownManga[manga.id] = manga;
    }
  }

  Future<List<MangaItem>> getLibrary({String? type}) async {
    // If logged in, sync from cloud
    if (isLoggedIn) {
      try {
        final uri = Uri.parse('$_baseUrl/library').replace(queryParameters: {
          if (type != null && type.isNotEmpty && type != 'all') 'type': type,
        });
        final res = await _httpClient
            .get(uri, headers: _headers(withAuth: true))
            .timeout(const Duration(seconds: 8));
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
            _knownManga[m.id] = m;
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
      final res = await _httpClient
          .get(Uri.parse('$_baseUrl/library/check/$mangaId'), headers: _headers(withAuth: true))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final inLib = data['inLibrary'] == true;
        if (inLib && !_localLibrary.containsKey(mangaId)) {
          // Sync into local cache
          final m = await getManga(mangaId);
          _localLibrary[mangaId] = m;
          _knownManga[mangaId] = m;
          await _persistLocalLibrary();
        }
        return inLib;
      }
    } catch (_) {}
    return false;
  }

  Future<void> addToLibrary(MangaItem manga) async {
    final existing = _localLibrary[manga.id];
    final effective = (existing != null && manga.cover.isEmpty && existing.cover.isNotEmpty)
        ? MangaItem(
            id: manga.id,
            title: manga.title,
            description: manga.description.isNotEmpty ? manga.description : existing.description,
            cover: existing.cover,
            authors: manga.authors.isNotEmpty ? manga.authors : existing.authors,
            status: manga.status.isNotEmpty ? manga.status : existing.status,
            type: manga.type,
            year: manga.year ?? existing.year,
            lastChapter: manga.lastChapter ?? existing.lastChapter,
            tags: manga.tags.isNotEmpty ? manga.tags : existing.tags,
            source: manga.source,
          )
        : manga;
    _localLibrary[manga.id] = effective;
    _knownManga[manga.id] = effective;
    await _persistLocalLibrary();
    notifyListeners();

    if (isLoggedIn) {
      try {
        await _httpClient
            .post(
              Uri.parse('$_baseUrl/library'),
              headers: _headers(withAuth: true),
              body: jsonEncode({
                'mangaId': effective.id,
                'title': effective.title,
                'cover': effective.cover,
                'type': effective.type,
                'status': effective.status,
                'latestChapter': effective.lastChapter ?? '',
              }),
            )
            .timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
  }

  Future<void> updateCachedMangaMetadata(MangaItem updated) async {
    _knownManga[updated.id] = updated;
    bool changed = false;
    final libExisting = _localLibrary[updated.id];
    if (libExisting != null) {
      final merged = MangaItem(
        id: updated.id,
        title: updated.title.isNotEmpty ? updated.title : libExisting.title,
        description: updated.description.isNotEmpty ? updated.description : libExisting.description,
        cover: updated.cover.isNotEmpty ? updated.cover : libExisting.cover,
        authors: updated.authors.isNotEmpty ? updated.authors : libExisting.authors,
        status: updated.status.isNotEmpty ? updated.status : libExisting.status,
        type: updated.type.isNotEmpty ? updated.type : libExisting.type,
        year: updated.year ?? libExisting.year,
        lastChapter: (updated.lastChapter != null && updated.lastChapter!.isNotEmpty)
            ? updated.lastChapter
            : libExisting.lastChapter,
        tags: updated.tags.isNotEmpty ? updated.tags : libExisting.tags,
        source: updated.source.isNotEmpty ? updated.source : libExisting.source,
      );
      _knownManga[updated.id] = merged;
      if (merged.cover != libExisting.cover ||
          merged.status != libExisting.status ||
          merged.lastChapter != libExisting.lastChapter) {
        _localLibrary[updated.id] = merged;
        await _persistLocalLibrary();
        changed = true;
      }
    }
    if (updated.cover.isNotEmpty) {
      bool histChanged = false;
      for (final h in _localHistory) {
        if (h['mangaId'] == updated.id && (h['cover']?.toString().isEmpty ?? true)) {
          h['cover'] = updated.cover;
          histChanged = true;
        }
      }
      if (histChanged) {
        await _persistLocalHistory();
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  Future<void> removeFromLibrary(String mangaId) async {
    _localLibrary.remove(mangaId);
    await _persistLocalLibrary();
    notifyListeners();

    if (isLoggedIn) {
      try {
        await _httpClient
            .delete(Uri.parse('$_baseUrl/library/$mangaId'), headers: _headers(withAuth: true))
            .timeout(const Duration(seconds: 8));
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
      await _httpClient
          .post(
            Uri.parse('$_baseUrl/progress'),
            headers: _headers(withAuth: true),
            body: jsonEncode(progressData),
          )
          .timeout(const Duration(seconds: 8));
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
      final res = await _httpClient
          .get(Uri.parse('$_baseUrl/progress/manga/$mangaId'), headers: _headers(withAuth: true))
          .timeout(const Duration(seconds: 8));
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

  Future<void> _ensureInLibraryWhenCategorizing(String mangaId, {MangaItem? manga}) async {
    if (_localLibrary.containsKey(mangaId)) {
      if (manga != null) {
        await updateCachedMangaMetadata(manga);
      }
      return;
    }
    final resolved = manga ??
        _knownManga[mangaId] ??
        MangaItem(
          id: mangaId,
          title: mangaId,
          source: _inferSourceFromId(mangaId),
        );
    await addToLibrary(resolved);
  }

  Future<void> setMangaCategories(
    String mangaId,
    List<String> categoryIds, {
    MangaItem? manga,
  }) async {
    final nextIds = List<String>.from(categoryIds);
    if (nextIds.isNotEmpty) {
      await _ensureInLibraryWhenCategorizing(mangaId, manga: manga);
    }
    _mangaCategories[mangaId] = nextIds;
    await _persistMangaCategories();
    notifyListeners();
  }

  Future<void> toggleMangaCategory(
    String mangaId,
    String categoryId, {
    MangaItem? manga,
  }) async {
    final list = _mangaCategories.putIfAbsent(mangaId, () => <String>[]);
    if (list.contains(categoryId)) {
      // Removing a manga from a category (even its last category) must NOT remove it from the library.
      list.remove(categoryId);
    } else {
      // Assigning a category to a non-library manga automatically adds it to the library first.
      await _ensureInLibraryWhenCategorizing(mangaId, manga: manga);
      if (!list.contains(categoryId)) {
        list.add(categoryId);
      }
    }
    await _persistMangaCategories();
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> getHistory() async {
    if (isLoggedIn) {
      try {
        final res = await _httpClient
            .get(Uri.parse('$_baseUrl/progress/history'), headers: _headers(withAuth: true))
            .timeout(const Duration(seconds: 8));
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
                          manga.source == 'mangapill' ? 'MangaPill' :
                          manga.source == 'mangakatana' ? 'MangaKatana' :
                          manga.source == 'mangaread' ? 'MangaRead' :
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
    String? sourcePkg,
    String? query,
    String order = 'popular',
    int page = 1,
    int limit = 24,
  }) async {
    final effectivePkg = (sourcePkg != null && sourcePkg.isNotEmpty) ? sourcePkg : ext.pkg;
    // If a sub-source was selected and has its own baseUrl, prefer that sub-source's baseUrl.
    String home = ext.homeUrl;
    if (effectivePkg.contains('@') && ext.subSources.isNotEmpty) {
      final sel = effectivePkg.split('@').sublist(1).join('@').toUpperCase();
      final matchSub = ext.subSources.where((s) =>
          (s['id'] ?? '').toUpperCase() == sel ||
          (s['lang'] ?? '').toUpperCase() == sel ||
          (s['name'] ?? '').toUpperCase() == sel).firstOrNull;
      if (matchSub != null && (matchSub['baseUrl'] ?? '').startsWith('http')) {
        home = matchSub['baseUrl']!;
      }
    }
    if (home.isEmpty) return [];

    try {
      final base = home.endsWith('/') ? home.substring(0, home.length - 1) : home;
      final referer = '$base/';
      final candidateUrls = <String>[];
      if (query != null && query.trim().isNotEmpty) {
        final q = Uri.encodeComponent(query.trim());
        candidateUrls.addAll([
          if (page > 1) '$base/page/$page/?s=$q&post_type=wp-manga' else '$base/?s=$q&post_type=wp-manga',
          if (page > 1) '$base/page/$page/?s=$q' else '$base/?s=$q',
          '$base/manga/?s=$q&page=$page',
        ]);
      } else if (order == 'latest') {
        candidateUrls.addAll([
          '$base/manga/?page=$page&order=update',
          if (page > 1) '$base/page/$page/?s=&post_type=wp-manga&m_orderby=latest' else '$base/?s=&post_type=wp-manga&m_orderby=latest',
          if (page > 1) '$base/page/$page/' else base,
        ]);
      } else {
        candidateUrls.addAll([
          '$base/manga/?page=$page&order=popular',
          if (page > 1) '$base/page/$page/?s=&post_type=wp-manga&m_orderby=views' else '$base/?s=&post_type=wp-manga&m_orderby=views',
          if (page > 1) '$base/page/$page/' else base,
        ]);
      }

      const invalidTitles = {
        'home', 'about', 'privacy', 'privacy policy', 'contact', 'contact us',
        'dmca', 'terms', 'terms of service', 'login', 'sign in', 'register',
        'sign up', 'discord', 'telegram', 'twitter', 'facebook', 'donate',
        'bookmark', 'history', 'popular', 'latest', 'search', 'manga list',
        'all manga', 'genre', 'genres', 'tags', 'news', 'read more', 'next', 'prev',
      };

      for (final url in candidateUrls) {
        http.Response res;
        try {
          res = await _getCached(
            Uri.parse(url),
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
              'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Referer': referer,
            },
            timeout: const Duration(seconds: 10),
          );
        } catch (_) {
          continue;
        }
        if (res.statusCode != 200) continue;

        final html = res.body;
        final items = <MangaItem>[];
        final seenUrls = <String>{};

        void tryAddItem(String rawHref, String titleHint, String coverHint) {
          var itemUrl = rawHref.trim();
          if (itemUrl.isEmpty || itemUrl == '#' || itemUrl == base || itemUrl == '$base/') return;
          if (itemUrl.startsWith('javascript:') || itemUrl.startsWith('mailto:')) return;
          final lowerHref = itemUrl.toLowerCase();
          if (lowerHref.contains('/wp-login') ||
              lowerHref.contains('/genre/') ||
              lowerHref.contains('/tag/') ||
              lowerHref.contains('/author/') ||
              RegExp(r'(?:chapter|ch-|episode|ep-)\d', caseSensitive: false).hasMatch(lowerHref)) {
            return;
          }
          if (!itemUrl.startsWith('http')) {
            itemUrl = itemUrl.startsWith('/') ? '$base$itemUrl' : '$base/$itemUrl';
          }
          if (!seenUrls.add(itemUrl)) return;

          var title = _unescapeHtml(titleHint.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim());
          if (title.isEmpty) {
            final slug = Uri.tryParse(itemUrl)?.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
            title = slug.replaceAll('-', ' ').replaceAll('_', ' ');
          }
          final lowerTitle = title.toLowerCase().trim();
          if (title.isEmpty || invalidTitles.contains(lowerTitle)) return;

          items.add(MangaItem(
            id: 'ext:$effectivePkg:${Uri.encodeComponent(itemUrl)}',
            title: title,
            cover: coverHint,
            source: effectivePkg,
          ));
        }

        // Pattern A: <a href="..."> containing <img> or CSS background-image
        final linkBlockRegex = RegExp(
          r'''<a\s+[^>]*href=["']([^"']+)["']([^>]*)>((?:(?!</a>)[\s\S])*?)</a>''',
          caseSensitive: false,
        );
        for (final m in linkBlockRegex.allMatches(html)) {
          final href = m.group(1) ?? '';
          final aAttrs = m.group(2) ?? '';
          final innerHtml = m.group(3) ?? '';

          String coverUrl = '';
          final imgTagMatch = RegExp(r'<img\b[^>]*>', caseSensitive: false).firstMatch(innerHtml);
          if (imgTagMatch != null) {
            coverUrl = _extractImgFromTag(imgTagMatch.group(0)!, baseUrl: base, referer: referer);
          }
          if (coverUrl.isEmpty) {
            final bgMatch = RegExp(r'''url\(["']?([^"')]+)["']?\)''', caseSensitive: false)
                .firstMatch('$aAttrs $innerHtml');
            if (bgMatch != null) {
              coverUrl = _normalizeImgUrl(bgMatch.group(1), baseUrl: base, referer: referer);
            }
          }
          if (coverUrl.isEmpty) continue;
          final lowerCover = coverUrl.toLowerCase();
          if (lowerCover.contains('logo') ||
              lowerCover.contains('avatar') ||
              lowerCover.contains('favicon') ||
              lowerCover.contains('banner')) {
            continue;
          }

          final titleAttrMatch = RegExp(r'''title=["']([^"']+)["']''', caseSensitive: false).firstMatch(aAttrs) ??
              (imgTagMatch != null
                  ? RegExp(r'''alt=["']([^"']+)["']''', caseSensitive: false).firstMatch(imgTagMatch.group(0)!)
                  : null);
          final titleHint = titleAttrMatch?.group(1) ?? innerHtml;
          tryAddItem(href, titleHint, coverUrl);
          if (items.length >= limit) break;
        }

        // Pattern B: Madara / MangaThemesia card containers where <img> and <a title> are siblings
        if (items.isEmpty) {
          final cardRegex = RegExp(
            r'''<div[^>]*class=["'][^"']*(?:page-item-detail|c-tabs-item__content|bsx|utao|manga-item|serie-card)[^"']*["'][^>]*>([\s\S]*?)</div>\s*</div>''',
            caseSensitive: false,
          );
          for (final cm in cardRegex.allMatches(html)) {
            final block = cm.group(1) ?? '';
            final hrefMatch = RegExp(r'''<a\s+[^>]*href=["']([^"']+)["']([^>]*)>([\s\S]*?)</a>''', caseSensitive: false)
                .firstMatch(block);
            if (hrefMatch == null) continue;
            final imgMatch = RegExp(r'<img\b[^>]*>', caseSensitive: false).firstMatch(block);
            var coverUrl = imgMatch != null
                ? _extractImgFromTag(imgMatch.group(0)!, baseUrl: base, referer: referer)
                : '';
            if (coverUrl.isEmpty) {
              final bgMatch = RegExp(r'''url\(["']?([^"')]+)["']?\)''', caseSensitive: false).firstMatch(block);
              coverUrl = _normalizeImgUrl(bgMatch?.group(1), baseUrl: base, referer: referer);
            }
            final titleMatch = RegExp(r'''<(?:h3|h4|h5|div)[^>]*class=["'][^"']*(?:post-title|tt|title)[^"']*["'][^>]*>([\s\S]*?)</(?:h3|h4|h5|div)>''', caseSensitive: false)
                    .firstMatch(block) ??
                RegExp(r'''title=["']([^"']+)["']''', caseSensitive: false).firstMatch(hrefMatch.group(2) ?? '');
            tryAddItem(hrefMatch.group(1) ?? '', titleMatch?.group(1) ?? hrefMatch.group(3) ?? '', coverUrl);
            if (items.length >= limit) break;
          }
        }

        if (items.isNotEmpty) {
          // Backfill any missing covers from detail pages (up to 6 concurrently)
          final missingIndices = <int>[
            for (var i = 0; i < items.length; i++)
              if (items[i].cover.isEmpty) i,
          ];
          if (missingIndices.isNotEmpty) {
            await Future.wait(missingIndices.take(6).map((idx) async {
              try {
                final m = items[idx];
                final actual = m.id.split(':').sublist(2).join(':');
                final detailed = await _getWebManga(effectivePkg, actual, ext: ext);
                if (detailed.cover.isNotEmpty) {
                  items[idx] = MangaItem(
                    id: m.id,
                    title: m.title,
                    cover: detailed.cover,
                    source: m.source,
                  );
                }
              } catch (_) {}
            }));
          }
          return items;
        }
      }
    } catch (e) {
      debugPrint('WebExtension search error for $effectivePkg: $e');
    }
    return [];
  }

  Future<MangaItem> _getWebManga(String pkg, String actualId, {MangaExtension? ext}) async {
    final seriesUrl = Uri.decodeComponent(actualId);
    final parsedUri = Uri.tryParse(seriesUrl);
    final origin = (parsedUri != null && parsedUri.hasScheme && parsedUri.host.isNotEmpty)
        ? '${parsedUri.scheme}://${parsedUri.host}'
        : (ext?.homeUrl ?? '');
    final referer = origin.isNotEmpty ? (origin.endsWith('/') ? origin : '$origin/') : null;

    try {
      final res = await _getCached(
        Uri.parse(seriesUrl),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Referer': ?referer,
        },
        timeout: const Duration(seconds: 10),
      );

      if (res.statusCode == 200) {
        final html = res.body;

        final h1Match = RegExp(r'<h1[^>]*>([\s\S]*?)</h1>', caseSensitive: false).firstMatch(html);
        final rawTitle = h1Match?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '';
        final title = _unescapeHtml(rawTitle.isNotEmpty ? rawTitle : (ext?.name ?? 'Series'));

        final descMatch = RegExp(r'''<div[^>]*class=["'][^"']*(?:description|synopsis|summary|entry-content)[^"']*["'][^>]*>([\s\S]*?)</div>''', caseSensitive: false).firstMatch(html) ??
            RegExp(r'''<p[^>]*class=["'][^"']*(?:description|synopsis|summary)[^"']*["'][^>]*>([\s\S]*?)</p>''', caseSensitive: false).firstMatch(html) ??
            RegExp(r'''<meta[^>]+(?:property=["']og:description["']|name=["']description["'])[^>]+content=["']([^"']+)["']''', caseSensitive: false).firstMatch(html);
        final desc = _unescapeHtml(descMatch?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '');

        String coverUrl = '';
        final coverContainerMatch = RegExp(
          r'''<(?:div|figure)[^>]*class=["'][^"']*(?:summary_image|thumb|cover|poster|seriestucon)[^"']*["'][^>]*>[\s\S]*?(<img\b[^>]*>)''',
          caseSensitive: false,
        ).firstMatch(html);
        if (coverContainerMatch != null) {
          coverUrl = _extractImgFromTag(coverContainerMatch.group(1)!, baseUrl: origin, referer: referer);
        }
        if (coverUrl.isEmpty) {
          final coverImgMatch = RegExp(
            r'''<img\b[^>]*class=["'][^"']*(?:thumb|cover|poster|wp-post-image)[^"']*["'][^>]*>''',
            caseSensitive: false,
          ).firstMatch(html);
          if (coverImgMatch != null) {
            coverUrl = _extractImgFromTag(coverImgMatch.group(0)!, baseUrl: origin, referer: referer);
          }
        }
        if (coverUrl.isEmpty) {
          final ogMatch = RegExp(
            r'''<meta[^>]+(?:property=["']og:image["']|name=["']twitter:image["'])[^>]+content=["']([^"']+)["']''',
            caseSensitive: false,
          ).firstMatch(html) ?? RegExp(
            r'''<meta[^>]+content=["']([^"']+)["'][^>]+(?:property=["']og:image["']|name=["']twitter:image["'])''',
            caseSensitive: false,
          ).firstMatch(html);
          coverUrl = _normalizeImgUrl(ogMatch?.group(1), baseUrl: origin, referer: referer);
        }

        final mangaId = 'ext:$pkg:$actualId';
        if (coverUrl.isNotEmpty) {
          ImageReferers.rememberResolvedCover(mangaId, coverUrl);
        }

        return MangaItem(
          id: mangaId,
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
    final parsedUri = Uri.tryParse(seriesUrl);
    final origin = (parsedUri != null && parsedUri.hasScheme && parsedUri.host.isNotEmpty)
        ? '${parsedUri.scheme}://${parsedUri.host}'
        : (ext?.homeUrl ?? '');
    final referer = origin.isNotEmpty ? (origin.endsWith('/') ? origin : '$origin/') : null;

    List<ChapterItem> parseHtmlChapters(String html) {
      final chapterRegex = RegExp(
        r'''<a\s+[^>]*href=["']([^"']*(?:chapter|ch-|episode|ep-|chap-)[^"']*)["'][^>]*>((?:(?!</a>)[\s\S])*?)</a>''',
        caseSensitive: false,
      );
      final list = <ChapterItem>[];
      final seen = <String>{};
      for (final m in chapterRegex.allMatches(html)) {
        var chUrl = (m.group(1) ?? '').trim();
        final rawText = _unescapeHtml(
          (m.group(2) ?? '').replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim(),
        );
        if (chUrl.isEmpty || chUrl.startsWith('#') || chUrl.startsWith('javascript:')) continue;
        if (!chUrl.startsWith('http')) {
          final uri = Uri.parse(seriesUrl);
          chUrl = chUrl.startsWith('/') ? '${uri.scheme}://${uri.host}$chUrl' : '${uri.scheme}://${uri.host}/$chUrl';
        }
        if (!seen.add(chUrl)) continue;
        final numMatch = RegExp(r'(?:chapter|episode|ch\.?|ep\.?|chap\.?)\s*([\d\.]+)', caseSensitive: false).firstMatch(rawText) ??
            RegExp(r'(?:chapter|ch|ep)[-_]([\d\.]+)', caseSensitive: false).firstMatch(chUrl);
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

    try {
      final res = await _getCached(
        Uri.parse(seriesUrl),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Referer': ?referer,
        },
        timeout: const Duration(seconds: 10),
      );

      if (res.statusCode == 200) {
        final directList = parseHtmlChapters(res.body);
        if (directList.isNotEmpty) return directList;

        // Madara WordPress sites often load chapters via POST `{seriesUrl}ajax/chapters/`
        final ajaxUrl = '${seriesUrl.endsWith('/') ? seriesUrl : '$seriesUrl/'}ajax/chapters/';
        try {
          final ajaxRes = await http.post(
            Uri.parse(ajaxUrl),
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
              'X-Requested-With': 'XMLHttpRequest',
              'Referer': seriesUrl,
            },
          ).timeout(const Duration(seconds: 8));
          if (ajaxRes.statusCode == 200 && ajaxRes.body.isNotEmpty) {
            final ajaxList = parseHtmlChapters(ajaxRes.body);
            if (ajaxList.isNotEmpty) return ajaxList;
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('WebExtension getChapters error: $e');
    }
    return [];
  }

  Future<ChapterPages> _getWebChapterPages(String pkg, String actualChapterId, {MangaExtension? ext}) async {
    final chapterUrl = Uri.decodeComponent(actualChapterId);
    final parsedUri = Uri.tryParse(chapterUrl);
    final origin = (parsedUri != null && parsedUri.hasScheme && parsedUri.host.isNotEmpty)
        ? '${parsedUri.scheme}://${parsedUri.host}'
        : (ext?.homeUrl ?? '');
    final referer = origin.isNotEmpty ? (origin.endsWith('/') ? origin : '$origin/') : null;

    try {
      final res = await http.get(
        Uri.parse(chapterUrl),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Referer': ?referer,
        },
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode == 200) {
        final html = res.body;
        final pagesList = <String>[];
        final seen = <String>{};

        // 1. Check MangaThemesia / WP-Manga JS arrays (`ts_reader.run(...)` or `chapter_preloaded_images`)
        final tsReaderMatch = RegExp(r'ts_reader\.run\((\{[\s\S]*?\})\)\s*;?', caseSensitive: false).firstMatch(html);
        if (tsReaderMatch != null) {
          final jsonBlock = tsReaderMatch.group(1)!;
          final imagesArrMatch = RegExp(r'"images"\s*:\s*\[([\s\S]*?)\]').firstMatch(jsonBlock);
          if (imagesArrMatch != null) {
            for (final um in RegExp(r'"([^"]+)"').allMatches(imagesArrMatch.group(1)!)) {
              final rawImg = um.group(1)!.replaceAll(r'\/', '/');
              final u = _normalizeImgUrl(rawImg, baseUrl: origin, referer: referer);
              if (u.isNotEmpty && seen.add(u)) pagesList.add(u);
            }
          }
        }

        if (pagesList.isEmpty) {
          final preloadMatch = RegExp(r'(?:chapter_preloaded_images|var\s+thzq)\s*=\s*\[([\s\S]*?)\]', caseSensitive: false)
              .firstMatch(html);
          if (preloadMatch != null) {
            for (final um in RegExp(r'''["']([^"']+)["']''').allMatches(preloadMatch.group(1)!)) {
              final rawImg = um.group(1)!.replaceAll(r'\/', '/');
              final u = _normalizeImgUrl(rawImg, baseUrl: origin, referer: referer);
              if (u.isNotEmpty && seen.add(u)) pagesList.add(u);
            }
          }
        }

        // 2. Standard HTML <img> tags inside reader containers or full page
        if (pagesList.isEmpty) {
          final readerSectionMatch = RegExp(
            r'''<div[^>]*(?:id=["']readerarea["']|class=["'][^"']*(?:reading-content|chapter-content|vung-doc|container-chapter-reader)[^"']*["'])[^>]*>([\s\S]*?)</div>\s*</div>''',
            caseSensitive: false,
          ).firstMatch(html);
          final targetHtml = readerSectionMatch?.group(1) ?? html;
          final imgTags = RegExp(r'<img\b[^>]*>', caseSensitive: false).allMatches(targetHtml);
          for (final m in imgTags) {
            final u = _extractImgFromTag(m.group(0)!, baseUrl: origin, referer: referer);
            if (u.isEmpty) continue;
            final lower = u.toLowerCase();
            if (lower.contains('logo') ||
                lower.contains('banner') ||
                lower.contains('avatar') ||
                lower.contains('favicon') ||
                lower.contains('icon') ||
                lower.contains('gravatar')) {
              continue;
            }
            if (seen.add(u)) {
              pagesList.add(u);
            }
          }
        }

        if (pagesList.isNotEmpty) {
          return ChapterPages(
            chapterId: 'ext:$pkg:$actualChapterId',
            pages: pagesList,
            dataSaver: pagesList,
          );
        }
      }
    } catch (e) {
      debugPrint('WebExtension getChapterPages error: $e');
    }
    throw Exception('Failed to load chapter pages from $pkg');
  }

  static String _unescapeHtml(String text) {
    var out = text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&rsquo;', "'")
        .replaceAll('&lsquo;', "'")
        .replaceAll('&ldquo;', '"')
        .replaceAll('&rdquo;', '"')
        .replaceAll('&ndash;', '–')
        .replaceAll('&mdash;', '—')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#8217;', "'")
        .replaceAll('&#8216;', "'")
        .replaceAll('&#8220;', '"')
        .replaceAll('&#8221;', '"')
        .replaceAll('&hellip;', '...');
    if (out.contains('&#')) {
      out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
        final code = int.tryParse(m.group(1)!);
        return code != null ? String.fromCharCode(code) : m.group(0)!;
      });
      out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
        final code = int.tryParse(m.group(1)!, radix: 16);
        return code != null ? String.fromCharCode(code) : m.group(0)!;
      });
    }
    return out;
  }

  static void _checkResponseHealth(http.Response res, String sourceName) {
    if (res.statusCode == 403) {
      throw Exception('$sourceName is protected by Cloudflare (HTTP 403). Please open in WebView to verify.');
    }
    if (res.statusCode == 502 || res.statusCode == 503 || res.statusCode == 504) {
      throw Exception('$sourceName server is temporarily down for maintenance (HTTP ${res.statusCode}).');
    }
    if (res.statusCode >= 400) {
      throw Exception('$sourceName returned an error (HTTP ${res.statusCode}).');
    }
    final bodyLower = res.body.toLowerCase();
    if (bodyLower.contains('scheduled maintenance') ||
        bodyLower.contains('under maintenance') ||
        bodyLower.contains('maintenance mode') ||
        (bodyLower.contains('maintenance') && bodyLower.contains('sorry for the inconvenience')) ||
        (bodyLower.contains('maintenance') && bodyLower.contains('everything is fine'))) {
      throw Exception('$sourceName is currently undergoing scheduled maintenance. Please try again later.');
    }
    if (bodyLower.contains('cf-browser-verification') ||
        (bodyLower.contains('ray id') && (bodyLower.contains('cloudflare') || bodyLower.contains('attention required!')))) {
      throw Exception('$sourceName is protected by Cloudflare. Please open in WebView to verify.');
    }
  }

  // ---- MangaPill Direct Scraper ----

  Future<List<MangaItem>> _searchMangaPill({String? query, String? type, int page = 1, int limit = 24}) async {
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

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'Referer': 'https://mangapill.com/',
      },
      timeout: const Duration(seconds: 10),
    );

    _checkResponseHealth(res, 'MangaPill');

    if (res.statusCode == 200) {
      final html = res.body;
      final cardRegex = RegExp(
        r'<a\s+href="/manga/(\d+)/([^"]+)"[^>]*>([\s\S]*?<img\b[^>]*>)[\s\S]*?<div class="mt-3 font-black leading-tight line-clamp-2">([^<]+)</div>',
        caseSensitive: false,
      );

      final matches = cardRegex.allMatches(html);
      final items = <MangaItem>[];
      final seen = <String>{};

      for (final m in matches) {
        final mId = m.group(1)!;
        final slug = m.group(2)!;
        final imgSub = m.group(3)!;
        final imgTag = RegExp(r'<img\b[^>]*>', caseSensitive: false).firstMatch(imgSub)?.group(0) ?? '';
        final cover = _extractImgFromTag(
          imgTag,
          baseUrl: 'https://mangapill.com',
          referer: 'https://mangapill.com/',
        );
        final title = _unescapeHtml(m.group(4)!.trim());

        final id = 'pill:$mId:$slug';
        if (!seen.add(id)) continue;

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
    return [];
  }

  Future<MangaItem> _getMangaPill(String id) async {
    final parts = id.split(':');
    final mId = parts.length > 1 ? parts[1] : '';
    final slug = parts.length > 2 ? parts[2] : '';
    final url = 'https://mangapill.com/manga/$mId/$slug';

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'Referer': 'https://mangapill.com/',
      },
      timeout: const Duration(seconds: 10),
    );

    _checkResponseHealth(res, 'MangaPill');

    if (res.statusCode == 200) {
      final html = res.body;
      final titleMatch = RegExp(r'<h1[^>]*>([^<]+)</h1>').firstMatch(html);
      final title = titleMatch?.group(1)?.trim() ?? slug.replaceAll('-', ' ');

      final descMatch = RegExp(r'<p class="text-sm[^"]*">([\s\S]*?)</p>').firstMatch(html);
      final desc = descMatch?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '';

      final figImgMatch = RegExp(r'<figure[^>]*>[\s\S]*?(<img\b[^>]*>)', caseSensitive: false).firstMatch(html);
      var cover = figImgMatch != null
          ? _extractImgFromTag(
              figImgMatch.group(1)!,
              baseUrl: 'https://mangapill.com',
              referer: 'https://mangapill.com/',
            )
          : '';
      if (cover.isEmpty) {
        final ogMatch = RegExp(r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"', caseSensitive: false).firstMatch(html);
        cover = _normalizeImgUrl(ogMatch?.group(1), baseUrl: 'https://mangapill.com', referer: 'https://mangapill.com/');
      }

      final tags = RegExp(r'<a[^>]+href="/search\?genre=[^"]+"[^>]*>([^<]+)</a>', caseSensitive: false)
          .allMatches(html)
          .map((m) => _unescapeHtml(m.group(1)!.trim()))
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();

      return MangaItem(
        id: id,
        title: _unescapeHtml(title),
        description: _unescapeHtml(desc),
        cover: cover,
        tags: tags,
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

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'Referer': 'https://mangapill.com/',
      },
      timeout: const Duration(seconds: 10),
    );

    _checkResponseHealth(res, 'MangaPill');

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
        final rawTitle = _unescapeHtml(m.group(3)!.trim());

        final numMatch = RegExp(r'Chapter\s+([0-9.]+)', caseSensitive: false).firstMatch(rawTitle);
        final num = numMatch?.group(1);

        chapters.add(ChapterItem(
          id: 'pill:$cId:$cSlug',
          title: rawTitle,
          number: num,
          group: 'MangaPill',
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
      headers: const {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'Referer': 'https://mangapill.com/',
      },
    ).timeout(const Duration(seconds: 12));

    _checkResponseHealth(res, 'MangaPill');

    if (res.statusCode == 200) {
      final html = res.body;
      final pageTagRegex = RegExp(r'<img\b[^>]*class="[^"]*js-page[^"]*"[^>]*>', caseSensitive: false);
      final matches = pageTagRegex.allMatches(html);

      final pages = <String>[];
      for (final m in matches) {
        final imgUrl = _extractImgFromTag(
          m.group(0)!,
          baseUrl: 'https://mangapill.com',
          referer: 'https://mangapill.com/',
        );
        if (imgUrl.isNotEmpty) {
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

  Future<List<MangaItem>> _searchMangaKatana({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
  }) async {
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

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://mangakatana.com/',
      },
      timeout: const Duration(seconds: 12),
    );

    _checkResponseHealth(res, 'MangaKatana');

    if (res.statusCode == 200) {
      final html = res.body;
      // Scope to #book_list so unrelated sidebar widgets (#hot_book / #hot_update)
      // don't pollute search results or return text-only rows without covers.
      final bookListIdx = html.indexOf('id="book_list"');
      final sidebarIdx = bookListIdx >= 0 ? html.indexOf('id="hot_', bookListIdx) : -1;
      final listHtml = bookListIdx >= 0
          ? html.substring(bookListIdx, sidebarIdx > bookListIdx ? sidebarIdx : null)
          : html;

      final cardRegex = RegExp(
        r'<div class="item"[^>]*>[\s\S]*?<a href="(https://mangakatana\.com/manga/([^.]+)\.(\d+))"[^>]*>([\s\S]*?<img\b(?:"[^"]*"|' "'" r"[^']*'|[^'" '"' r'>])*>)[\s\S]*?<h3 class="title">\s*<a[^>]*>([^<]+)</a>',
        caseSensitive: false,
      );

      var matches = cardRegex.allMatches(listHtml).toList();
      if (matches.isEmpty && bookListIdx >= 0) {
        matches = cardRegex.allMatches(html).toList();
      }
      final items = <MangaItem>[];
      final seen = <String>{};

      for (final m in matches) {
        final slug = m.group(2)!;
        final mId = m.group(3)!;
        final imgBlock = m.group(4)!;
        final imgTag = RegExp(
              r'<img\b(?:"[^"]*"|' "'" r"[^']*'|[^'" '"' r'>])*>',
              caseSensitive: false,
            ).firstMatch(imgBlock)?.group(0) ??
            imgBlock;
        final cover = _extractImgFromTag(
          imgTag,
          baseUrl: 'https://mangakatana.com',
          referer: 'https://mangakatana.com/',
        );
        if (cover.isEmpty) continue;
        final title = _unescapeHtml(m.group(5)!.trim());

        final id = 'katana:$slug:$mId';
        if (!seen.add(id)) continue;

        items.add(MangaItem(
          id: id,
          title: title,
          cover: cover,
          type: type ?? (url.contains('manhwa') ? 'manhwa' : (url.contains('manhua') ? 'manhua' : 'manga')),
          source: 'mangakatana',
        ));
        if (items.length >= limit) break;
      }

      if (items.isNotEmpty) return items;

      // If no list items found, check if MangaKatana redirected directly to a manga detail page (exact match)
      final canonicalMatch = RegExp(
        r'<link\s+rel="canonical"\s+href="https://mangakatana\.com/manga/([^.]+)\.(\d+)"',
        caseSensitive: false,
      ).firstMatch(html) ?? RegExp(
        r'<meta\s+property="og:url"\s+content="https://mangakatana\.com/manga/([^.]+)\.(\d+)"',
        caseSensitive: false,
      ).firstMatch(html);

      if (canonicalMatch != null) {
        final slug = canonicalMatch.group(1)!;
        final mId = canonicalMatch.group(2)!;
        final titleMatch = RegExp(r'<h1 class="heading">\s*([^<]+)\s*</h1>', caseSensitive: false).firstMatch(html)
            ?? RegExp(r'<meta\s+property="og:title"\s+content="([^"]+)"', caseSensitive: false).firstMatch(html);
        final title = _unescapeHtml(titleMatch?.group(1)?.trim() ?? query?.trim() ?? slug.replaceAll('-', ' '));

        final coverDivMatch = RegExp(r'<div class="cover"[^>]*>[\s\S]*?(<img\b[^>]*>)', caseSensitive: false).firstMatch(html);
        var cover = coverDivMatch != null
            ? _extractImgFromTag(
                coverDivMatch.group(1)!,
                baseUrl: 'https://mangakatana.com',
                referer: 'https://mangakatana.com/',
              )
            : '';
        if (cover.isEmpty) {
          final ogMatch = RegExp(r'<meta\s+property="og:image"\s+content="([^"]+)"', caseSensitive: false).firstMatch(html);
          cover = _normalizeImgUrl(ogMatch?.group(1), baseUrl: 'https://mangakatana.com', referer: 'https://mangakatana.com/');
        }

        items.add(MangaItem(
          id: 'katana:$slug:$mId',
          title: title,
          cover: cover,
          type: type ?? 'manga',
          source: 'mangakatana',
        ));
      }

      return items;
    }
    return [];
  }

  Future<MangaItem> _getMangaKatana(String id) async {
    final parts = id.split(':');
    final slug = parts.length > 1 ? parts[1] : '';
    final mId = parts.length > 2 ? parts[2] : '';
    final url = 'https://mangakatana.com/manga/$slug.$mId';

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://mangakatana.com/',
      },
      timeout: const Duration(seconds: 12),
    );

    _checkResponseHealth(res, 'MangaKatana');

    if (res.statusCode == 200) {
      final html = res.body;
      final titleMatch = RegExp(r'<h1 class="heading">([^<]+)</h1>').firstMatch(html);
      final title = _unescapeHtml(titleMatch?.group(1)?.trim() ?? slug.replaceAll('-', ' '));

      final descMatch = RegExp(r'<div class="summary">[\s\S]*?<p>([\s\S]*?)</p>').firstMatch(html);
      final desc = _unescapeHtml(descMatch?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '');

      final coverDivMatch = RegExp(r'<div class="cover"[^>]*>[\s\S]*?(<img\b[^>]*>)', caseSensitive: false).firstMatch(html);
      var cover = coverDivMatch != null
          ? _extractImgFromTag(
              coverDivMatch.group(1)!,
              baseUrl: 'https://mangakatana.com',
              referer: 'https://mangakatana.com/',
            )
          : '';
      if (cover.isEmpty) {
        final ogMatch = RegExp(r'<meta\s+property="og:image"\s+content="([^"]+)"', caseSensitive: false).firstMatch(html);
        cover = _normalizeImgUrl(ogMatch?.group(1), baseUrl: 'https://mangakatana.com', referer: 'https://mangakatana.com/');
      }

      final authorMatches = RegExp(r'<a class="author"[^>]*>([^<]+)</a>').allMatches(html);
      final authors = authorMatches.map((m) => _unescapeHtml(m.group(1)!.trim())).toList();

      final genreBlock = RegExp(r'<div class="genres">([\s\S]*?)</div>').firstMatch(html)?.group(1) ?? '';
      final tags = RegExp(r'<a[^>]*>([^<]+)</a>')
          .allMatches(genreBlock)
          .map((m) => _unescapeHtml(m.group(1)!.trim()))
          .where((s) => s.isNotEmpty)
          .toList();

      final status = html.contains('status completed') ? 'completed' : 'ongoing';

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

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://mangakatana.com/',
      },
      timeout: const Duration(seconds: 12),
    );

    _checkResponseHealth(res, 'MangaKatana');

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
        final rawTitle = _unescapeHtml(m.group(2)!.trim());

        chapters.add(ChapterItem(
          id: 'katana:$slug:$mId:c$cNum',
          title: rawTitle,
          number: cNum,
          group: 'MangaKatana',
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
      headers: const {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://mangakatana.com/',
      },
    ).timeout(const Duration(seconds: 12));

    _checkResponseHealth(res, 'MangaKatana');

    if (res.statusCode == 200) {
      final html = res.body;
      final arrayMatch = RegExp(r'var\s+thzq\s*=\s*\[([^\]]+)\]').firstMatch(html) ??
          RegExp(r'var\s+ytaw\s*=\s*\[([^\]]+)\]').firstMatch(html);

      if (arrayMatch != null) {
        final content = arrayMatch.group(1)!;
        final urlMatches = RegExp(r'''['"]((?:https?:)?//[^'"]+)['"]''').allMatches(content);
        final pages = <String>[];
        for (final m in urlMatches) {
          final pUrl = _normalizeImgUrl(
            m.group(1),
            baseUrl: 'https://mangakatana.com',
            referer: 'https://mangakatana.com/',
          );
          if (pUrl.isNotEmpty) pages.add(pUrl);
        }

        if (pages.isNotEmpty) {
          return ChapterPages(chapterId: chapterId, pages: pages, dataSaver: pages);
        }
      }
    }
    throw Exception('Failed to load MangaKatana chapter pages');
  }

  // ---- MangaRead Direct Scraper (iOS & Web) ----

  Future<List<MangaItem>> _searchMangaRead({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
  }) async {
    final sortParam = order == 'popular' ? 'views' : 'latest';
    final String url;
    if (query != null && query.trim().isNotEmpty) {
      url = 'https://www.mangaread.org/page/$page/?s=${Uri.encodeComponent(query.trim())}&post_type=wp-manga';
    } else if (type == 'manhwa') {
      url = 'https://www.mangaread.org/genres/manhwa/page/$page/?m_orderby=$sortParam';
    } else if (type == 'manhua') {
      url = 'https://www.mangaread.org/genres/manhua/page/$page/?m_orderby=$sortParam';
    } else if (type == 'manga') {
      url = 'https://www.mangaread.org/genres/manga/page/$page/?m_orderby=$sortParam';
    } else {
      url = 'https://www.mangaread.org/manga/page/$page/?m_orderby=$sortParam';
    }

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://www.mangaread.org/',
      },
      timeout: const Duration(seconds: 12),
    );

    _checkResponseHealth(res, 'MangaRead');

    if (res.statusCode == 200) {
      final html = res.body;
      final cardRegex = RegExp(
        r'<div[^>]*class="[^"]*(?:item-thumb|tab-thumb)[^"]*"[^>]*>[\s\S]*?<a href="https://www\.mangaread\.org/manga/([^/]+)/"[^>]*title="([^"]*)"[^>]*>([\s\S]*?<img\b[^>]*>)',
        caseSensitive: false,
      );

      final matches = cardRegex.allMatches(html);
      final items = <MangaItem>[];
      final seen = <String>{};

      for (final m in matches) {
        final slug = m.group(1)!;
        final title = _unescapeHtml(m.group(2)!.trim());
        final imgBlock = m.group(3)!;
        final imgTag = RegExp(r'<img\b[^>]*>', caseSensitive: false).firstMatch(imgBlock)?.group(0) ?? '';
        final cover = _extractImgFromTag(
          imgTag,
          baseUrl: 'https://www.mangaread.org',
          referer: 'https://www.mangaread.org/',
        );

        final id = 'mread:$slug';
        if (!seen.add(id)) continue;

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
    return [];
  }

  Future<MangaItem> _getMangaRead(String id) async {
    final slug = id.replaceFirst('mread:', '');
    final url = 'https://www.mangaread.org/manga/$slug/';

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://www.mangaread.org/',
      },
      timeout: const Duration(seconds: 12),
    );

    _checkResponseHealth(res, 'MangaRead');

    if (res.statusCode == 200) {
      final html = res.body;
      final titleMatch = RegExp(r'<div class="post-title">[\s\S]*?<h1>([^<]+)</h1>').firstMatch(html);
      final title = _unescapeHtml(titleMatch?.group(1)?.trim() ?? slug.replaceAll('-', ' '));

      final descMatch = RegExp(r'<div class="description-summary">[\s\S]*?<p>([\s\S]*?)</p>').firstMatch(html);
      final desc = _unescapeHtml(descMatch?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '');

      final coverDivMatch = RegExp(r'<div class="summary_image"[^>]*>[\s\S]*?(<img\b[^>]*>)', caseSensitive: false).firstMatch(html);
      var cover = coverDivMatch != null
          ? _extractImgFromTag(
              coverDivMatch.group(1)!,
              baseUrl: 'https://www.mangaread.org',
              referer: 'https://www.mangaread.org/',
            )
          : '';
      if (cover.isEmpty) {
        final ogMatch = RegExp(r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"', caseSensitive: false).firstMatch(html);
        cover = _normalizeImgUrl(ogMatch?.group(1), baseUrl: 'https://www.mangaread.org', referer: 'https://www.mangaread.org/');
      }

      final authorBlock = RegExp(r'<div class="author-content">([\s\S]*?)</div>').firstMatch(html)?.group(1) ?? '';
      final authors = RegExp(r'<a[^>]*>([^<]+)</a>')
          .allMatches(authorBlock)
          .map((m) => _unescapeHtml(m.group(1)!.trim()))
          .where((s) => s.isNotEmpty)
          .toList();

      final genreBlock = RegExp(r'<div class="genres-content">([\s\S]*?)</div>').firstMatch(html)?.group(1) ?? '';
      final tags = RegExp(r'<a[^>]*>([^<]+)</a>')
          .allMatches(genreBlock)
          .map((m) => _unescapeHtml(m.group(1)!.trim()))
          .where((s) => s.isNotEmpty)
          .toList();

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
    throw Exception('Failed to load MangaRead series details');
  }

  Future<List<ChapterItem>> _getMangaReadChapters(String mangaId) async {
    final slug = mangaId.replaceFirst('mread:', '');
    final url = 'https://www.mangaread.org/manga/$slug/';

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://www.mangaread.org/',
      },
      timeout: const Duration(seconds: 12),
    );

    _checkResponseHealth(res, 'MangaRead');

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
        final rawTitle = _unescapeHtml(m.group(2)!.trim());
        final numMatch = RegExp(r'Chapter\s+([0-9.]+)', caseSensitive: false).firstMatch(rawTitle);
        final num = numMatch?.group(1);

        chapters.add(ChapterItem(
          id: 'mread:$slug:$cSlug',
          title: rawTitle,
          number: num,
          group: 'MangaRead',
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
      headers: const {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://www.mangaread.org/',
      },
    ).timeout(const Duration(seconds: 12));

    _checkResponseHealth(res, 'MangaRead');

    if (res.statusCode == 200) {
      final html = res.body;
      final pageRegex = RegExp(r'<div class="page-break[^>]*>[\s\S]*?(<img\b[^>]*>)', caseSensitive: false);
      final matches = pageRegex.allMatches(html);

      final pages = <String>[];
      for (final m in matches) {
        final imgUrl = _extractImgFromTag(
          m.group(1)!,
          baseUrl: 'https://www.mangaread.org',
          referer: 'https://www.mangaread.org/',
        );
        if (imgUrl.isNotEmpty) {
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
