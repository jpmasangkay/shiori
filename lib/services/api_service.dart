import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga_models.dart';
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

  String get baseUrl => _baseUrl;
  String? get token => _token;
  UserAccount? get currentUser => _currentUser;
  bool get isLoggedIn => _token != null && _currentUser != null;
  bool get isMongoConnected => _mongoConnected;

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
          final source = (e['source']?.toString()) ?? (id.startsWith('asura:') ? 'asura' : 'mangadex');
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
    final s = source.toLowerCase();

    // 1. Flame Comics Extension
    if (s.contains('flame')) {
      return _searchFlameComics(query: query, page: page, limit: limit);
    }

    // 2. Weeb Central Extension
    if (s.contains('weeb')) {
      return _searchWeebCentral(query: query, page: page, limit: limit);
    }

    // 3. Asura Scans Extension
    if (s.contains('asura')) {
      return _searchAsura(query: query, page: page);
    }

    // 4. MangaDex Extension
    if (s.contains('mangadex')) {
      final uri = Uri.parse('$_baseUrl/manga/search').replace(queryParameters: {
        if (query != null && query.isNotEmpty) 'q': query,
        if (type != null && type.isNotEmpty && type != 'all') 'type': type,
        'order': order,
        'page': page.toString(),
        'limit': limit.toString(),
      });

      final res = await http.get(uri, headers: _headers(withAuth: false));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['items'] as List<dynamic>?) ?? [];
        return list.map((e) => MangaItem.fromJson(e as Map<String, dynamic>)).toList();
      }
      return [];
    }

    // Unhandled community extension:
    // DO NOT silently fall back to MangaDex! Return empty so that the UI can
    // present the dedicated extension view with options to launch in Mihon or open the official site.
    return [];
  }

  Future<MangaItem> getManga(String id) async {
    if (id.startsWith('asura:')) return _getAsuraManga(id);
    if (id.startsWith('flame:')) return _getFlameManga(id);
    if (id.startsWith('weeb:')) return _getWeebManga(id);

    final res = await http.get(Uri.parse('$_baseUrl/manga/$id'), headers: _headers(withAuth: false));
    if (res.statusCode == 200) {
      return MangaItem.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    }
    throw Exception('Failed to load manga details');
  }

  Future<List<ChapterItem>> getChapters(String mangaId, {String lang = 'en'}) async {
    if (mangaId.startsWith('asura:')) return _getAsuraChapters(mangaId);
    if (mangaId.startsWith('flame:')) return _getFlameChapters(mangaId);
    if (mangaId.startsWith('weeb:')) return _getWeebChapters(mangaId);

    final uri = Uri.parse('$_baseUrl/manga/$mangaId/chapters').replace(queryParameters: {'lang': lang});
    final res = await http.get(uri, headers: _headers(withAuth: false));
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (data['chapters'] as List<dynamic>?) ?? [];
      return list.map((e) => ChapterItem.fromJson(e as Map<String, dynamic>)).toList();
    }
    throw Exception('Failed to load chapters');
  }

  Future<ChapterPages> getChapterPages(String chapterId) async {
    if (chapterId.startsWith('asura:')) return _getAsuraChapterPages(chapterId);
    if (chapterId.startsWith('flame:')) return _getFlameChapterPages(chapterId);
    if (chapterId.startsWith('weeb:')) return _getWeebChapterPages(chapterId);

    final res = await http.get(Uri.parse('$_baseUrl/manga/chapter/$chapterId/pages'), headers: _headers(withAuth: false));
    if (res.statusCode == 200) {
      return ChapterPages.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    }
    throw Exception('Failed to load chapter pages');
  }

  Future<List<MangaItem>> _searchAsura({String? query, int page = 1}) async {
    try {
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

  Future<List<MangaItem>> _searchFlameComics({String? query, int page = 1, int limit = 24}) async {
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

  Future<List<MangaItem>> _searchWeebCentral({String? query, int page = 1, int limit = 24}) async {
    try {
      final String url;
      if (query != null && query.trim().isNotEmpty) {
        url = 'https://weebcentral.com/search/data?text=${Uri.encodeComponent(query.trim())}&page=$page';
      } else {
        url = 'https://weebcentral.com/search/data?sort=Popularity&order=Ascending&page=$page';
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
            final source = (e['source']?.toString()) ?? (id.startsWith('asura:') ? 'asura' : 'mangadex');
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
    if (_localProgress.containsKey(mangaId)) {
      return _localProgress[mangaId]!;
    }
    if (!isLoggedIn) return {};
    try {
      final res = await http.get(Uri.parse('$_baseUrl/progress/manga/$mangaId'), headers: _headers(withAuth: true));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        _localProgress[mangaId] = data;
        _persistLocalProgress();
        return data;
      }
    } catch (_) {}
    return {};
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
              'group': ch.group.isNotEmpty ? ch.group : 'MangaDex',
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
}
