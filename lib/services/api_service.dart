import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga_models.dart';

class ApiService extends ChangeNotifier {
  static final ApiService instance = ApiService._();
  ApiService._();

  static const _defaultPort = '3000';
  String _baseUrl = '';
  String? _token;
  UserAccount? _currentUser;
  bool _initialized = false;
  bool _mongoConnected = false;

  String get baseUrl => _baseUrl;
  String? get token => _token;
  UserAccount? get currentUser => _currentUser;
  bool get isLoggedIn => _token != null && _currentUser != null;
  bool get isMongoConnected => _mongoConnected;

  String _determineDefaultHost() {
    if (kIsWeb) return 'http://localhost:$_defaultPort/api';
    try {
      if (Platform.isAndroid) return 'http://10.0.2.2:$_defaultPort/api';
    } catch (_) {}
    return 'http://localhost:$_defaultPort/api';
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

    _initialized = true;
    checkHealth();
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
        _mongoConnected = data['mongo'] == 'connected';
        notifyListeners();
        return true;
      }
    } catch (_) {
      _mongoConnected = false;
      notifyListeners();
    }
    return false;
  }

  // ---- Authentication ----

  Future<void> register(String email, String password, {String displayName = ''}) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/auth/register'),
      headers: _headers(withAuth: false),
      body: jsonEncode({
        'email': email,
        'password': password,
        'displayName': displayName,
      }),
    );

    if (res.statusCode != 201) {
      final err = jsonDecode(res.body);
      throw Exception(err['error'] ?? 'Registration failed');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    await _saveAuthData(data['token'] as String, UserAccount.fromJson(data['user']));
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

  // ---- MangaDex Catalog ----

  Future<List<MangaItem>> searchManga({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
  }) async {
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
    throw Exception('Failed to search manga');
  }

  Future<MangaItem> getManga(String id) async {
    final res = await http.get(Uri.parse('$_baseUrl/manga/$id'), headers: _headers(withAuth: false));
    if (res.statusCode == 200) {
      return MangaItem.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    }
    throw Exception('Failed to load manga details');
  }

  Future<List<ChapterItem>> getChapters(String mangaId, {String lang = 'en'}) async {
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
    final res = await http.get(Uri.parse('$_baseUrl/manga/chapter/$chapterId/pages'), headers: _headers(withAuth: false));
    if (res.statusCode == 200) {
      return ChapterPages.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    }
    throw Exception('Failed to load chapter pages');
  }

  // ---- MongoDB User Library ----

  Future<List<MangaItem>> getLibrary({String? type}) async {
    if (!isLoggedIn) return [];
    final uri = Uri.parse('$_baseUrl/library').replace(queryParameters: {
      if (type != null && type.isNotEmpty && type != 'all') 'type': type,
    });
    final res = await http.get(uri, headers: _headers(withAuth: true));
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (data['items'] as List<dynamic>?) ?? [];
      return list.map((e) => MangaItem(
            id: e['mangaId'] ?? '',
            title: e['title'] ?? '',
            cover: e['cover'] ?? '',
            type: e['type'] ?? 'manga',
            status: e['status'] ?? '',
            lastChapter: e['latestChapter'] ?? '',
          )).toList();
    }
    return [];
  }

  Future<bool> checkInLibrary(String mangaId) async {
    if (!isLoggedIn) return false;
    try {
      final res = await http.get(Uri.parse('$_baseUrl/library/check/$mangaId'), headers: _headers(withAuth: true));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return data['inLibrary'] == true;
      }
    } catch (_) {}
    return false;
  }

  Future<void> addToLibrary(MangaItem manga) async {
    if (!isLoggedIn) return;
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
  }

  Future<void> removeFromLibrary(String mangaId) async {
    if (!isLoggedIn) return;
    await http.delete(Uri.parse('$_baseUrl/library/$mangaId'), headers: _headers(withAuth: true));
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
    if (!isLoggedIn) return;
    try {
      await http.post(
        Uri.parse('$_baseUrl/progress'),
        headers: _headers(withAuth: true),
        body: jsonEncode({
          'mangaId': mangaId,
          'chapterId': chapterId,
          'mangaTitle': mangaTitle ?? '',
          'cover': cover ?? '',
          'chapterNumber': chapterNumber ?? '',
          'chapterTitle': chapterTitle ?? '',
          'page': page,
          'totalPages': totalPages,
          'completed': completed,
        }),
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>> getMangaProgress(String mangaId) async {
    if (!isLoggedIn) return {};
    try {
      final res = await http.get(Uri.parse('$_baseUrl/progress/manga/$mangaId'), headers: _headers(withAuth: true));
      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  Future<List<Map<String, dynamic>>> getHistory() async {
    if (!isLoggedIn) return [];
    try {
      final res = await http.get(Uri.parse('$_baseUrl/progress/history'), headers: _headers(withAuth: true));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = data['items'] as List<dynamic>? ?? [];
        return list.map((e) => e as Map<String, dynamic>).toList();
      }
    } catch (_) {}
    return [];
  }

  // ---- Updates Feed ----

  Future<Map<String, dynamic>> getUpdates() async {
    try {
      final res = await http.get(Uri.parse('$_baseUrl/updates'), headers: _headers(withAuth: true));
      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }
}
