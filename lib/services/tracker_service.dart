import 'dart:async';
import 'dart:convert';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:manga_reader/services/app_logger.dart';
import 'package:manga_reader/services/secure_token_store.dart';

class AniListUser {
  final int id;
  final String name;
  final String? avatarUrl;

  const AniListUser({required this.id, required this.name, this.avatarUrl});
}

/// AniList tracking service with SecureTokenStore (#7) and OAuth2 PKCE/Implicit flow (#24)
class TrackerService extends ChangeNotifier {
  TrackerService._();
  static final TrackerService instance = TrackerService._();

  static const String _keyToken = 'anilist_access_token';
  static const String _keyUserName = 'anilist_user_name';
  static const String _keyUserAvatar = 'anilist_user_avatar';
  static const String _keyAutoUpdate = 'tracker_auto_update_enabled';

  // Default Shiori AniList Client ID (can be overridden by user or developer)
  static const String defaultClientId = '17865';

  final SecureTokenStore _tokenStore = SecureTokenStore.instance;
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;

  SharedPreferences? _cachedPrefs;
  String? _token;
  AniListUser? _currentUser;
  bool _autoUpdateEnabled = true;

  bool get isAuthenticated => _token != null && _token!.isNotEmpty;
  AniListUser? get currentUser => _currentUser;
  bool get autoUpdateEnabled => _autoUpdateEnabled;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _cachedPrefs = prefs;

      // Migrate legacy prefs if present
      await _tokenStore.migrateLegacyPrefs(prefs);

      _token = await _tokenStore.read(_keyToken);
      _autoUpdateEnabled = prefs.getBool(_keyAutoUpdate) ?? true;

      final name = prefs.getString(_keyUserName);
      final avatar = prefs.getString(_keyUserAvatar);
      if (_token != null && name != null) {
        _currentUser = AniListUser(id: 0, name: name, avatarUrl: avatar);
      }
      notifyListeners();

      _initDeepLinks();

      // Silent verify in background
      if (_token != null) {
        _verifyToken(_token!);
      }
    } catch (e) {
      AppLogger.warn('TrackerService init error', e);
    }
  }

  void _initDeepLinks() {
    try {
      _linkSubscription = _appLinks.uriLinkStream.listen(
        (uri) {
          handleAuthRedirect(uri);
        },
        onError: (err) {
          AppLogger.warn('AppLinks stream error: $err');
        },
      );
    } catch (_) {}
  }

  /// Handles incoming `shiori://auth/anilist#access_token=...` callback (#24)
  Future<bool> handleAuthRedirect(Uri uri) async {
    if (uri.scheme == 'shiori' && uri.host == 'auth') {
      String? token;

      // 1. Check fragment (e.g. #access_token=XYZ&token_type=Bearer)
      if (uri.fragment.isNotEmpty) {
        final fragParams = Uri.splitQueryString(uri.fragment);
        token = fragParams['access_token'];
      }

      // 2. Check query parameter (e.g. ?access_token=XYZ)
      token ??= uri.queryParameters['access_token'];

      if (token != null && token.isNotEmpty) {
        AppLogger.info('Received AniList OAuth token from redirect');
        return await loginWithToken(token);
      }
    }
    return false;
  }

  /// Opens browser to initiate AniList OAuth login (#24)
  Future<bool> startOAuthFlow({String? clientId}) async {
    final cid = (clientId != null && clientId.isNotEmpty)
        ? clientId
        : defaultClientId;
    final authUrl = Uri.parse(
      'https://anilist.co/api/v2/oauth/authorize?client_id=$cid&response_type=token',
    );
    try {
      return await launchUrl(authUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      AppLogger.warn('Failed to launch AniList OAuth URL', e);
      return false;
    }
  }

  Future<void> setAutoUpdate(bool enabled) async {
    _autoUpdateEnabled = enabled;
    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoUpdate, enabled);
    notifyListeners();
  }

  Future<bool> loginWithToken(String token) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) return false;

    final user = await _verifyToken(cleanToken);
    if (user != null) {
      _token = cleanToken;
      _currentUser = user;

      await _tokenStore.write(_keyToken, cleanToken);

      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      await prefs.setString(_keyUserName, user.name);
      if (user.avatarUrl != null) {
        await prefs.setString(_keyUserAvatar, user.avatarUrl!);
      }
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<void> logout() async {
    _token = null;
    _currentUser = null;
    await _tokenStore.delete(_keyToken);

    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.remove(_keyUserName);
    await prefs.remove(_keyUserAvatar);
    notifyListeners();
  }

  Future<AniListUser?> _verifyToken(String token) async {
    const query = '''
    query {
      Viewer {
        id
        name
        avatar {
          medium
        }
      }
    }
    ''';

    try {
      final res = await http
          .post(
            Uri.parse('https://graphql.anilist.co'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'query': query}),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final viewer = data['data']?['Viewer'];
        if (viewer != null) {
          return AniListUser(
            id: viewer['id'] as int? ?? 0,
            name: viewer['name'] as String? ?? 'User',
            avatarUrl: viewer['avatar']?['medium'] as String?,
          );
        }
      }
    } catch (e) {
      AppLogger.warn('AniList verifyToken error', e);
    }
    return null;
  }

  /// Searches for a manga on AniList by title and returns its AniList ID
  Future<int?> searchMangaId(String title) async {
    const query = '''
    query (\$search: String) {
      Media (search: \$search, type: MANGA) {
        id
        title {
          romaji
          english
        }
      }
    }
    ''';

    try {
      final res = await http
          .post(
            Uri.parse('https://graphql.anilist.co'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              if (_token != null) 'Authorization': 'Bearer $_token',
            },
            body: jsonEncode({
              'query': query,
              'variables': {'search': title},
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final mediaId = data['data']?['Media']?['id'] as int?;
        return mediaId;
      }
    } catch (e) {
      AppLogger.warn('AniList searchMangaId error', e);
    }
    return null;
  }

  /// Updates progress for a manga on AniList
  Future<bool> updateProgress({
    required int mediaId,
    required int chapterProgress,
    bool isCompleted = false,
  }) async {
    if (!isAuthenticated) return false;

    const mutation = '''
    mutation (\$mediaId: Int, \$progress: Int, \$status: MediaListStatus) {
      SaveMediaListEntry (mediaId: \$mediaId, progress: \$progress, status: \$status) {
        id
        progress
        status
      }
    }
    ''';

    try {
      final status = isCompleted ? 'COMPLETED' : 'CURRENT';
      final res = await http
          .post(
            Uri.parse('https://graphql.anilist.co'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Authorization': 'Bearer $_token',
            },
            body: jsonEncode({
              'query': mutation,
              'variables': {
                'mediaId': mediaId,
                'progress': chapterProgress,
                'status': status,
              },
            }),
          )
          .timeout(const Duration(seconds: 10));

      return res.statusCode == 200;
    } catch (e) {
      AppLogger.warn('AniList updateProgress error', e);
      return false;
    }
  }

  /// Automatically called when a chapter is finished reading in ReaderScreen
  Future<void> onChapterFinished({
    required String mangaTitle,
    required String? chapterNumber,
  }) async {
    if (!isAuthenticated || !_autoUpdateEnabled) return;
    if (chapterNumber == null || chapterNumber.isEmpty) return;

    final numVal = double.tryParse(chapterNumber)?.floor();
    if (numVal == null || numVal <= 0) return;

    try {
      final mediaId = await searchMangaId(mangaTitle);
      if (mediaId != null) {
        await updateProgress(mediaId: mediaId, chapterProgress: numVal);
        AppLogger.info(
          'TrackerService: Updated AniList for $mangaTitle to Ch. $numVal',
        );
      }
    } catch (e) {
      AppLogger.warn('TrackerService onChapterFinished error', e);
    }
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }
}
