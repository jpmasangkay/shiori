import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:manga_reader/models/tracking_models.dart';
import 'package:manga_reader/services/app_logger.dart';
import 'package:manga_reader/services/privacy_service.dart';
import 'package:manga_reader/services/secure_token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class AniListUser {
  final int id;
  final String name;
  final String? avatarUrl;

  const AniListUser({required this.id, required this.name, this.avatarUrl});
}

class MangaRecommendation {
  final String title;
  final String? coverUrl;
  final double? score;
  final int? chapters;
  final String? status;
  final String? siteUrl;

  const MangaRecommendation({
    required this.title,
    this.coverUrl,
    this.score,
    this.chapters,
    this.status,
    this.siteUrl,
  });
}

/// Multi-tracker tracking service supporting AniList, MyAnimeList (OAuth2 PKCE),
/// Kitsu (JSON:API), MangaUpdates (v1 API), Shikimori, and Bangumi.
class TrackerService extends ChangeNotifier {
  TrackerService._();
  static final TrackerService instance = TrackerService._();

  static const String _keyToken = 'anilist_access_token';
  static const String _keyUserName = 'anilist_user_name';
  static const String _keyUserAvatar = 'anilist_user_avatar';
  static const String _keyAutoUpdate = 'tracker_auto_update_enabled';
  static const String _keyUpdateWhenMarkedRead = 'tracker_update_when_marked_read';
  static const String _keyMangaRecordsPrefix = 'manga_tracking_records_v1_';
  static const String _keyMalCodeVerifier = 'mal_pkce_code_verifier';
  static const String _keyMalClientId = 'mal_client_id';
  static const String _keyMalRefreshToken = 'tracker_refresh_myanimelist';

  // Default Shiori AniList Client ID
  static const String defaultClientId = '17865';
  static const String defaultMalClientId = '6114d00ca681b7701d1e15fe11a4987e';

  final SecureTokenStore _tokenStore = SecureTokenStore.instance;
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;

  http.Client _httpClient = http.Client();
  SharedPreferences? _cachedPrefs;
  String? _token;
  AniListUser? _currentUser;
  bool _autoUpdateEnabled = true;
  String _updateProgressWhenMarkedRead = 'Always'; // 'Always', 'Never'

  // Per-tracker tokens / usernames (tokens persisted strictly in SecureTokenStore)
  final Map<String, String> _trackerTokens = {};
  final Map<String, String> _trackerUsernames = {};
  final Map<String, String> _trackerRefreshTokens = {};

  // Per-manga tracked records in-memory cache: mangaId -> List<MangaTrackingRecord>
  final Map<String, List<MangaTrackingRecord>> _recordsCache = {};

  bool get isAuthenticated => _token != null && _token!.isNotEmpty;
  AniListUser? get currentUser => _currentUser;
  bool get autoUpdateEnabled => _autoUpdateEnabled;
  bool get updateProgressAfterReading => _autoUpdateEnabled;
  String get updateProgressWhenMarkedRead => _updateProgressWhenMarkedRead;

  @visibleForTesting
  void setHttpClientForTesting(http.Client? client) {
    _httpClient = client ?? http.Client();
  }

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _cachedPrefs = prefs;

      // Migrate legacy auth prefs if present
      await _tokenStore.migrateLegacyPrefs(prefs);

      _token = await _tokenStore.read(_keyToken);
      _autoUpdateEnabled = prefs.getBool(_keyAutoUpdate) ?? true;
      _updateProgressWhenMarkedRead =
          prefs.getString(_keyUpdateWhenMarkedRead) ?? 'Always';

      final name = prefs.getString(_keyUserName);
      final avatar = prefs.getString(_keyUserAvatar);
      if (_token != null && name != null) {
        _currentUser = AniListUser(id: 0, name: name, avatarUrl: avatar);
        _trackerTokens['anilist'] = _token!;
        _trackerUsernames['anilist'] = name;
      }

      // Load tracker tokens securely; migrate any legacy plaintext SharedPreferences tokens
      for (final t in TrackerServiceMeta.all) {
        if (t.id == 'anilist') continue;
        final secureKey = 'tracker_token_${t.id}';
        var tok = await _tokenStore.read(secureKey);
        final legacyPlaintext = prefs.getString(secureKey);
        if ((tok == null || tok.isEmpty) &&
            legacyPlaintext != null &&
            legacyPlaintext.isNotEmpty) {
          tok = legacyPlaintext;
          await _tokenStore.write(secureKey, tok);
        }
        if (legacyPlaintext != null) {
          // Always scrub plaintext token from SharedPreferences
          await prefs.remove(secureKey);
        }

        final refreshTok = await _tokenStore.read('tracker_refresh_${t.id}');
        final usr = prefs.getString('tracker_username_${t.id}');
        if (tok != null && tok.isNotEmpty) _trackerTokens[t.id] = tok;
        if (refreshTok != null && refreshTok.isNotEmpty) {
          _trackerRefreshTokens[t.id] = refreshTok;
        }
        if (usr != null && usr.isNotEmpty) _trackerUsernames[t.id] = usr;
      }

      notifyListeners();

      _initDeepLinks();

      // Silent verify in background
      if (_token != null) {
        unawaited(_verifyToken(_token!));
      }
    } catch (e) {
      AppLogger.warn('TrackerService init error', e);
    }
  }

  void _initDeepLinks() {
    try {
      _linkSubscription?.cancel();
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

  /// Generates a RFC 7636 PKCE code verifier (43–128 URL-safe characters).
  static String generatePkceVerifier([int length = 64]) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rng = Random.secure();
    return List.generate(length, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  /// Derives a BASE64URL-encoded SHA-256 PKCE code challenge (S256).
  static String derivePkceS256Challenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  /// Handles incoming `shiori://auth/anilist#access_token=...` and
  /// `shiori://auth/myanimelist?code=...` OAuth callbacks.
  Future<bool> handleAuthRedirect(Uri uri) async {
    if (uri.scheme != 'shiori' || uri.host != 'auth') return false;

    final pathLower = uri.path.toLowerCase();
    // MyAnimeList Authorization Code + PKCE callback
    if (pathLower.contains('myanimelist') || pathLower.contains('mal')) {
      final code = uri.queryParameters['code'];
      if (code != null && code.isNotEmpty) {
        return await exchangeMalAuthCode(code);
      }
      return false;
    }

    // AniList OAuth callback
    String? token;
    if (uri.fragment.isNotEmpty) {
      final fragParams = Uri.splitQueryString(uri.fragment);
      token = fragParams['access_token'];
    }
    token ??= uri.queryParameters['access_token'];

    if (token != null && token.isNotEmpty) {
      AppLogger.info('Received AniList OAuth token from redirect');
      return await loginWithToken(token);
    }
    return false;
  }

  /// Opens browser to initiate AniList OAuth login
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

  /// Initiates MyAnimeList OAuth2 Authorization Code + PKCE flow.
  /// MAL API v2 requires `code_challenge_method=plain` with a 43–128 char verifier.
  Future<bool> startMalOAuthFlow({String? clientId}) async {
    final cid = (clientId != null && clientId.isNotEmpty)
        ? clientId
        : defaultMalClientId;
    final verifier = generatePkceVerifier(96);
    await _tokenStore.write(_keyMalCodeVerifier, verifier);
    await _tokenStore.write(_keyMalClientId, cid);

    final authUrl = Uri.https('myanimelist.net', '/v1/oauth2/authorize', {
      'response_type': 'code',
      'client_id': cid,
      'code_challenge': verifier,
      'code_challenge_method': 'plain',
      'redirect_uri': 'shiori://auth/myanimelist',
    });
    try {
      return await launchUrl(authUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      AppLogger.warn('Failed to launch MyAnimeList OAuth URL', e);
      return false;
    }
  }

  /// Exchanges a MyAnimeList OAuth2 PKCE authorization code for access + refresh tokens.
  Future<bool> exchangeMalAuthCode(String code) async {
    final verifier = await _tokenStore.read(_keyMalCodeVerifier);
    final cid = (await _tokenStore.read(_keyMalClientId)) ?? defaultMalClientId;
    if (verifier == null || verifier.isEmpty) return false;

    try {
      final res = await _httpClient
          .post(
            Uri.parse('https://myanimelist.net/v1/oauth2/token'),
            headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
            body: {
              'client_id': cid,
              'grant_type': 'authorization_code',
              'code': code,
              'code_verifier': verifier,
              'redirect_uri': 'shiori://auth/myanimelist',
            },
          )
          .timeout(const Duration(seconds: 12));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final accessToken = data['access_token']?.toString() ?? '';
        final refreshToken = data['refresh_token']?.toString() ?? '';
        if (accessToken.isNotEmpty) {
          await _tokenStore.delete(_keyMalCodeVerifier);
          if (refreshToken.isNotEmpty) {
            _trackerRefreshTokens['myanimelist'] = refreshToken;
            await _tokenStore.write(_keyMalRefreshToken, refreshToken);
          }
          final username = await _fetchMalUsername(accessToken);
          return await loginTracker('myanimelist', accessToken, username: username ?? 'MAL User');
        }
      }
    } catch (e) {
      AppLogger.warn('MAL OAuth token exchange failed', e);
    }
    return false;
  }

  Future<bool> refreshMalToken() async {
    final refreshToken = _trackerRefreshTokens['myanimelist'] ??
        await _tokenStore.read(_keyMalRefreshToken);
    if (refreshToken == null || refreshToken.isEmpty) return false;
    final cid = (await _tokenStore.read(_keyMalClientId)) ?? defaultMalClientId;
    try {
      final res = await _httpClient
          .post(
            Uri.parse('https://myanimelist.net/v1/oauth2/token'),
            headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
            body: {
              'client_id': cid,
              'grant_type': 'refresh_token',
              'refresh_token': refreshToken,
            },
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final newAccess = data['access_token']?.toString() ?? '';
        final newRefresh = data['refresh_token']?.toString() ?? '';
        if (newAccess.isNotEmpty) {
          if (newRefresh.isNotEmpty) {
            _trackerRefreshTokens['myanimelist'] = newRefresh;
            await _tokenStore.write(_keyMalRefreshToken, newRefresh);
          }
          return await loginTracker('myanimelist', newAccess);
        }
      }
    } catch (e) {
      AppLogger.warn('MAL token refresh failed', e);
    }
    return false;
  }

  Future<String?> _fetchMalUsername(String accessToken) async {
    try {
      final res = await _httpClient
          .get(
            Uri.parse('https://api.myanimelist.net/v2/users/@me'),
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return data['name']?.toString();
      }
    } catch (_) {}
    return null;
  }

  Future<void> setAutoUpdate(bool enabled) async {
    _autoUpdateEnabled = enabled;
    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoUpdate, enabled);
    notifyListeners();
  }

  Future<void> setUpdateProgressAfterReading(bool enabled) =>
      setAutoUpdate(enabled);

  Future<void> setUpdateProgressWhenMarkedRead(String option) async {
    _updateProgressWhenMarkedRead = option;
    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.setString(_keyUpdateWhenMarkedRead, option);
    notifyListeners();
  }

  bool isTrackerAuthenticated(String trackerId) {
    if (trackerId == 'anilist') return isAuthenticated;
    return _trackerTokens.containsKey(trackerId) &&
        _trackerTokens[trackerId]!.isNotEmpty;
  }

  String? getTrackerUsername(String trackerId) {
    if (trackerId == 'anilist') return _currentUser?.name;
    return _trackerUsernames[trackerId];
  }

  Future<bool> loginTracker(
    String trackerId,
    String token, {
    String? username,
  }) async {
    if (trackerId == 'anilist') {
      return await loginWithToken(token);
    }
    final cleanTok = token.trim();
    if (cleanTok.isEmpty) return false;
    _trackerTokens[trackerId] = cleanTok;
    if (username != null) _trackerUsernames[trackerId] = username.trim();

    await _tokenStore.write('tracker_token_$trackerId', cleanTok);
    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.remove('tracker_token_$trackerId'); // ensure no plaintext copy
    if (username != null) {
      await prefs.setString('tracker_username_$trackerId', username.trim());
    }
    notifyListeners();
    return true;
  }

  Future<void> logoutTracker(String trackerId) async {
    if (trackerId == 'anilist') {
      await logout();
      return;
    }
    _trackerTokens.remove(trackerId);
    _trackerUsernames.remove(trackerId);
    _trackerRefreshTokens.remove(trackerId);

    await _tokenStore.delete('tracker_token_$trackerId');
    await _tokenStore.delete('tracker_refresh_$trackerId');
    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.remove('tracker_token_$trackerId');
    await prefs.remove('tracker_username_$trackerId');
    notifyListeners();
  }

  Future<bool> loginWithToken(String token) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) return false;

    final user = await _verifyToken(cleanToken);
    if (user != null) {
      _token = cleanToken;
      _currentUser = user;
      _trackerTokens['anilist'] = cleanToken;
      _trackerUsernames['anilist'] = user.name;

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
    _trackerTokens.remove('anilist');
    _trackerUsernames.remove('anilist');
    await _tokenStore.delete(_keyToken);

    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.remove(_keyUserName);
    await prefs.remove(_keyUserAvatar);
    notifyListeners();
  }

  // -------------------------------------------------------------
  // PER-MANGA TRACKING RECORDS
  // -------------------------------------------------------------

  List<MangaTrackingRecord> getTrackingRecordsForManga(String mangaId) {
    if (_recordsCache.containsKey(mangaId)) {
      return _recordsCache[mangaId]!;
    }
    final prefs = _cachedPrefs;
    if (prefs == null) return [];

    final raw = prefs.getString('$_keyMangaRecordsPrefix$mangaId');
    if (raw == null || raw.isEmpty) {
      _recordsCache[mangaId] = [];
      return [];
    }

    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final records = list
          .map((e) => MangaTrackingRecord.fromJson(e as Map<String, dynamic>))
          .toList();
      _recordsCache[mangaId] = records;
      return records;
    } catch (e) {
      AppLogger.warn('Error parsing tracking records for manga $mangaId', e);
      return [];
    }
  }

  MangaTrackingRecord? getTrackingRecord(String mangaId, String trackerId) {
    final records = getTrackingRecordsForManga(mangaId);
    for (final r in records) {
      if (r.trackerId == trackerId) return r;
    }
    return null;
  }

  bool isMangaTracked(String mangaId) {
    return getTrackingRecordsForManga(mangaId).isNotEmpty;
  }

  Future<void> saveTrackingRecord(MangaTrackingRecord record) async {
    final list = List<MangaTrackingRecord>.from(
      getTrackingRecordsForManga(record.mangaId),
    );
    list.removeWhere((r) => r.trackerId == record.trackerId);
    list.add(record);
    _recordsCache[record.mangaId] = list;

    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(list.map((r) => r.toJson()).toList());
    await prefs.setString('$_keyMangaRecordsPrefix${record.mangaId}', jsonStr);

    // Sync to remote tracker API if authenticated
    await _syncRecordRemotely(record);

    notifyListeners();
  }

  Future<void> _syncRecordRemotely(MangaTrackingRecord record) async {
    final tid = record.trackerId.toLowerCase();
    if (!isTrackerAuthenticated(tid)) return;

    switch (tid) {
      case 'anilist':
        final mediaId = int.tryParse(record.remoteId);
        if (mediaId != null) {
          await updateProgress(
            mediaId: mediaId,
            chapterProgress: record.lastChapterRead,
            status: record.status,
            score: record.score,
          );
        }
        break;
      case 'myanimelist':
      case 'mal':
        await _updateMalProgress(record);
        break;
      case 'kitsu':
        await _updateKitsuProgress(record);
        break;
      case 'mangaupdates':
        await _updateMangaUpdatesProgress(record);
        break;
    }
  }

  Future<void> removeTrackingRecord(String mangaId, String trackerId) async {
    final list =
        List<MangaTrackingRecord>.from(getTrackingRecordsForManga(mangaId));
    list.removeWhere((r) => r.trackerId == trackerId);
    _recordsCache[mangaId] = list;

    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(list.map((r) => r.toJson()).toList());
    await prefs.setString('$_keyMangaRecordsPrefix$mangaId', jsonStr);
    notifyListeners();
  }

  // -------------------------------------------------------------
  // AUTOMATIC UPDATES (EXPLICITLY LINKED RECORDS ONLY)
  // -------------------------------------------------------------

  /// Called when a chapter is finished in the reader.
  /// Only updates explicitly linked tracking records (never guesses remote IDs
  /// by title string for unlinked titles) and respects Incognito mode.
  Future<void> onChapterFinished({
    required String mangaTitle,
    required String? chapterNumber,
    String? mangaId,
  }) async {
    if (PrivacyService.instance.incognitoMode) return;
    if (!_autoUpdateEnabled) return;
    if (mangaId == null || mangaId.isEmpty) return;
    if (chapterNumber == null || chapterNumber.isEmpty) return;

    final numVal = double.tryParse(chapterNumber)?.floor();
    if (numVal == null || numVal <= 0) return;

    try {
      final records = getTrackingRecordsForManga(mangaId);
      for (final r in records) {
        if (numVal > r.lastChapterRead) {
          final updated = r.copyWith(
            lastChapterRead: numVal,
            status: (r.totalChapters != null &&
                    r.totalChapters! > 0 &&
                    numVal >= r.totalChapters!)
                ? 'Completed'
                : r.status,
            updatedAt: DateTime.now(),
          );
          await saveTrackingRecord(updated);
        }
      }
    } catch (e) {
      AppLogger.warn('TrackerService onChapterFinished error', e);
    }
  }

  /// Called when chapters are marked read from DetailScreen.
  /// Only updates explicitly linked tracking records and respects Incognito mode.
  Future<void> onChaptersMarkedRead({
    required String mangaId,
    required String mangaTitle,
    required int maxChapterRead,
  }) async {
    if (PrivacyService.instance.incognitoMode) return;
    if (_updateProgressWhenMarkedRead != 'Always') return;
    if (maxChapterRead <= 0) return;

    try {
      final records = getTrackingRecordsForManga(mangaId);
      for (final r in records) {
        if (maxChapterRead > r.lastChapterRead) {
          final updated = r.copyWith(
            lastChapterRead: maxChapterRead,
            status: (r.totalChapters != null &&
                    r.totalChapters! > 0 &&
                    maxChapterRead >= r.totalChapters!)
                ? 'Completed'
                : r.status,
            updatedAt: DateTime.now(),
          );
          await saveTrackingRecord(updated);
        }
      }
    } catch (e) {
      AppLogger.warn('TrackerService onChaptersMarkedRead error', e);
    }
  }

  // -------------------------------------------------------------
  // REMOTE SEARCH & RECOMMENDATIONS API IMPLEMENTATIONS
  // -------------------------------------------------------------

  Future<List<TrackerSearchResult>> searchTracker({
    required String trackerId,
    required String query,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return [];

    switch (trackerId.toLowerCase()) {
      case 'anilist':
        return await _searchAniList(cleanQuery);
      case 'myanimelist':
      case 'mal':
        return await _searchMyAnimeList(cleanQuery);
      case 'kitsu':
        return await _searchKitsu(cleanQuery);
      case 'mangaupdates':
        return await _searchMangaUpdates(cleanQuery);
      case 'shikimori':
        return await _searchShikimori(cleanQuery);
      case 'bangumi':
        return await _searchBangumi(cleanQuery);
      default:
        return const [];
    }
  }

  /// Fetches similar manga recommendations from AniList for [mangaTitle].
  Future<List<MangaRecommendation>> fetchRecommendations(String mangaTitle) async {
    final clean = mangaTitle.trim();
    if (clean.isEmpty) return const [];
    const q = '''
    query (\$search: String) {
      Media(search: \$search, type: MANGA) {
        recommendations(page: 1, perPage: 10, sort: RATING_DESC) {
          nodes {
            mediaRecommendation {
              title { romaji english }
              coverImage { large medium }
              averageScore
              chapters
              status
              siteUrl
            }
          }
        }
      }
    }
    ''';

    try {
      final res = await _httpClient
          .post(
            Uri.parse('https://graphql.anilist.co'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'query': q,
              'variables': {'search': clean},
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (res.statusCode != 200) return const [];
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final nodes =
          data['data']?['Media']?['recommendations']?['nodes'] as List<dynamic>? ??
              const [];
      final recs = <MangaRecommendation>[];
      for (final node in nodes) {
        final rec = node['mediaRecommendation'] as Map<String, dynamic>?;
        if (rec == null) continue;
        final titleMap = rec['title'] as Map<String, dynamic>?;
        final title = titleMap?['english']?.toString() ??
            titleMap?['romaji']?.toString() ??
            '';
        if (title.isEmpty) continue;
        final score = (rec['averageScore'] as num?)?.toDouble();
        recs.add(
          MangaRecommendation(
            title: title,
            coverUrl: rec['coverImage']?['large']?.toString() ??
                rec['coverImage']?['medium']?.toString(),
            score: score != null ? score / 10.0 : null,
            chapters: (rec['chapters'] as num?)?.toInt(),
            status: rec['status']?.toString(),
            siteUrl: rec['siteUrl']?.toString(),
          ),
        );
      }
      return recs;
    } catch (e) {
      AppLogger.warn('AniList recommendations fetch failed', e);
      return const [];
    }
  }

  Future<List<TrackerSearchResult>> _searchAniList(String query) async {
    const q = '''
    query (\$search: String) {
      Page(page: 1, perPage: 15) {
        media(search: \$search, type: MANGA) {
          id
          title {
            romaji
            english
            native
          }
          coverImage {
            medium
            large
          }
          chapters
          status
          averageScore
          siteUrl
        }
      }
    }
    ''';

    try {
      final res = await _httpClient
          .post(
            Uri.parse('https://graphql.anilist.co'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              if (_token != null) 'Authorization': 'Bearer $_token',
            },
            body: jsonEncode({
              'query': q,
              'variables': {'search': query},
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final mediaList =
            data['data']?['Page']?['media'] as List<dynamic>? ?? [];
        return mediaList.map((m) {
          final titleObj = m['title'] as Map<String, dynamic>?;
          final title = titleObj?['romaji'] as String? ??
              titleObj?['english'] as String? ??
              titleObj?['native'] as String? ??
              'Untitled';
          final cover = m['coverImage']?['large'] as String? ??
              m['coverImage']?['medium'] as String?;
          final scoreVal = m['averageScore'] as num?;
          return TrackerSearchResult(
            trackerId: 'anilist',
            remoteId: m['id'].toString(),
            title: title,
            coverUrl: cover,
            totalChapters: m['chapters'] as int?,
            status: m['status'] as String?,
            score: scoreVal != null ? scoreVal / 10.0 : null,
            url: m['siteUrl'] as String?,
          );
        }).toList();
      }
    } catch (e) {
      AppLogger.warn('AniList search error', e);
    }
    return [];
  }

  Future<List<TrackerSearchResult>> _searchMyAnimeList(String query) async {
    try {
      final uri = Uri.parse(
        'https://api.jikan.moe/v4/manga?q=${Uri.encodeComponent(query)}&limit=15',
      );
      final res = await _httpClient.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = data['data'] as List<dynamic>? ?? [];
        return list.map((item) {
          final images = item['images']?['jpg'] as Map<String, dynamic>?;
          final cover = images?['large_image_url'] as String? ??
              images?['image_url'] as String?;
          final score = (item['score'] as num?)?.toDouble();
          return TrackerSearchResult(
            trackerId: 'myanimelist',
            remoteId: item['mal_id'].toString(),
            title: item['title'] as String? ?? 'Untitled',
            coverUrl: cover,
            totalChapters: item['chapters'] as int?,
            status: item['status'] as String?,
            score: score,
            url: item['url'] as String?,
          );
        }).toList();
      }
    } catch (e) {
      AppLogger.warn('MyAnimeList search error', e);
    }
    return [];
  }

  Future<List<TrackerSearchResult>> _searchKitsu(String query) async {
    try {
      final uri = Uri.parse(
        'https://kitsu.io/api/edge/manga?filter[text]=${Uri.encodeComponent(query)}&page[limit]=15',
      );
      final res = await _httpClient.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = data['data'] as List<dynamic>? ?? [];
        return list.map((item) {
          final attrs = item['attributes'] as Map<String, dynamic>? ?? {};
          final cover = attrs['posterImage']?['medium'] as String? ??
              attrs['posterImage']?['original'] as String?;
          final rating = double.tryParse(attrs['averageRating']?.toString() ?? '');
          return TrackerSearchResult(
            trackerId: 'kitsu',
            remoteId: item['id'].toString(),
            title: attrs['canonicalTitle'] as String? ?? 'Untitled',
            coverUrl: cover,
            totalChapters: attrs['chapterCount'] as int?,
            status: attrs['status'] as String?,
            score: rating != null ? rating / 10.0 : null,
            url: 'https://kitsu.io/manga/${attrs['slug'] ?? item['id']}',
          );
        }).toList();
      }
    } catch (e) {
      AppLogger.warn('Kitsu search error', e);
    }
    return [];
  }

  Future<List<TrackerSearchResult>> _searchMangaUpdates(String query) async {
    try {
      final uri = Uri.parse('https://api.mangaupdates.com/v1/series/search');
      final res = await _httpClient
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'search': query, 'perpage': 15}),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final results = data['results'] as List<dynamic>? ?? [];
        return results.map((item) {
          final record = item['record'] as Map<String, dynamic>? ?? {};
          final img = record['image']?['url']?['original'] as String?;
          final id = record['series_id']?.toString() ?? '';
          return TrackerSearchResult(
            trackerId: 'mangaupdates',
            remoteId: id,
            title: record['title'] as String? ?? 'Untitled',
            coverUrl: img,
            status: record['status'] as String?,
            url: record['url'] as String? ??
                'https://www.mangaupdates.com/series.html?id=$id',
          );
        }).toList();
      }
    } catch (e) {
      AppLogger.warn('MangaUpdates search error', e);
    }
    return [];
  }

  Future<List<TrackerSearchResult>> _searchShikimori(String query) async {
    try {
      final uri = Uri.parse(
        'https://shikimori.one/api/mangas?search=${Uri.encodeComponent(query)}&limit=15',
      );
      final res = await _httpClient.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List<dynamic>? ?? [];
        return list.map((item) {
          final img = item['image']?['preview'] as String?;
          final fullImg = img != null ? 'https://shikimori.one$img' : null;
          final score = double.tryParse(item['score']?.toString() ?? '');
          return TrackerSearchResult(
            trackerId: 'shikimori',
            remoteId: item['id'].toString(),
            title: item['name'] as String? ?? 'Untitled',
            coverUrl: fullImg,
            totalChapters: item['chapters'] as int?,
            status: item['status'] as String?,
            score: score,
            url: 'https://shikimori.one${item['url'] ?? ''}',
          );
        }).toList();
      }
    } catch (e) {
      AppLogger.warn('Shikimori search error', e);
    }
    return [];
  }

  Future<List<TrackerSearchResult>> _searchBangumi(String query) async {
    try {
      final uri = Uri.parse(
        'https://api.bgm.tv/search/subject/${Uri.encodeComponent(query)}?type=1&responseGroup=small&max_results=15',
      );
      final res = await _httpClient.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = data['list'] as List<dynamic>? ?? [];
        return list.map((item) {
          final name = item['name_cn'] != null &&
                  (item['name_cn'] as String).isNotEmpty
              ? item['name_cn'] as String
              : item['name'] as String? ?? 'Untitled';
          final img = item['images']?['common'] as String? ??
              item['images']?['small'] as String?;
          return TrackerSearchResult(
            trackerId: 'bangumi',
            remoteId: item['id'].toString(),
            title: name,
            coverUrl: img,
            url: item['url'] as String? ?? 'https://bgm.tv/subject/${item['id']}',
          );
        }).toList();
      }
    } catch (e) {
      AppLogger.warn('Bangumi search error', e);
    }
    return [];
  }

  // -------------------------------------------------------------
  // REMOTE SYNC IMPLEMENTATIONS (ANILIST, MAL, KITSU, MANGAUPDATES)
  // -------------------------------------------------------------

  static String _mapStatusToAniList(String status) {
    switch (status.toLowerCase()) {
      case 'completed':
        return 'COMPLETED';
      case 'on hold':
      case 'paused':
        return 'PAUSED';
      case 'dropped':
        return 'DROPPED';
      case 'plan to read':
      case 'planning':
        return 'PLANNING';
      case 'rereading':
      case 'repeating':
        return 'REPEATING';
      default:
        return 'CURRENT';
    }
  }

  static String _mapStatusToMal(String status) {
    switch (status.toLowerCase()) {
      case 'completed':
        return 'completed';
      case 'on hold':
      case 'paused':
        return 'on_hold';
      case 'dropped':
        return 'dropped';
      case 'plan to read':
      case 'planning':
        return 'plan_to_read';
      default:
        return 'reading';
    }
  }

  static String _mapStatusToKitsu(String status) {
    switch (status.toLowerCase()) {
      case 'completed':
        return 'completed';
      case 'on hold':
      case 'paused':
        return 'on_hold';
      case 'dropped':
        return 'dropped';
      case 'plan to read':
      case 'planning':
        return 'planned';
      default:
        return 'current';
    }
  }

  Future<bool> _updateMalProgress(MangaTrackingRecord record) async {
    var tok = _trackerTokens['myanimelist'];
    if (tok == null || tok.isEmpty) return false;
    final mangaId = int.tryParse(record.remoteId);
    if (mangaId == null) return false;

    Future<http.Response> sendReq(String bearer) {
      final body = <String, String>{
        'status': _mapStatusToMal(record.status),
        'num_chapters_read': record.lastChapterRead.toString(),
        if (record.score > 0)
          'score': record.score.round().clamp(1, 10).toString(),
      };
      return _httpClient
          .put(
            Uri.parse('https://api.myanimelist.net/v2/manga/$mangaId/my_list_status'),
            headers: {
              'Authorization': 'Bearer $bearer',
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 10));
    }

    try {
      var res = await sendReq(tok);
      if (res.statusCode == 401 && await refreshMalToken()) {
        tok = _trackerTokens['myanimelist']!;
        res = await sendReq(tok);
      }
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      AppLogger.warn('MAL updateProgress error', e);
      return false;
    }
  }

  Future<bool> _updateKitsuProgress(MangaTrackingRecord record) async {
    final tok = _trackerTokens['kitsu'];
    if (tok == null || tok.isEmpty) return false;
    try {
      final headers = {
        'Authorization': 'Bearer $tok',
        'Accept': 'application/vnd.api+json',
        'Content-Type': 'application/vnd.api+json',
      };
      // Fetch current user ID
      final meRes = await _httpClient
          .get(
            Uri.parse('https://kitsu.io/api/edge/users?filter[self]=true'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 8));
      if (meRes.statusCode != 200) return false;
      final meData = jsonDecode(meRes.body) as Map<String, dynamic>;
      final users = meData['data'] as List<dynamic>? ?? const [];
      if (users.isEmpty) return false;
      final userId = users.first['id']?.toString() ?? '';
      if (userId.isEmpty) return false;

      // Check for existing library entry
      final findRes = await _httpClient
          .get(
            Uri.parse(
              'https://kitsu.io/api/edge/library-entries?filter[userId]=$userId&filter[mangaId]=${record.remoteId}',
            ),
            headers: headers,
          )
          .timeout(const Duration(seconds: 8));
      final existing = findRes.statusCode == 200
          ? ((jsonDecode(findRes.body) as Map<String, dynamic>)['data']
                  as List<dynamic>? ??
              const [])
          : const [];

      final attrs = <String, dynamic>{
        'progress': record.lastChapterRead,
        'status': _mapStatusToKitsu(record.status),
        if (record.score > 0)
          'ratingTwenty': (record.score * 2).round().clamp(2, 20),
      };

      if (existing.isNotEmpty) {
        final entryId = existing.first['id'].toString();
        final patchRes = await _httpClient
            .patch(
              Uri.parse('https://kitsu.io/api/edge/library-entries/$entryId'),
              headers: headers,
              body: jsonEncode({
                'data': {
                  'id': entryId,
                  'type': 'libraryEntries',
                  'attributes': attrs,
                },
              }),
            )
            .timeout(const Duration(seconds: 10));
        return patchRes.statusCode >= 200 && patchRes.statusCode < 300;
      } else {
        final createRes = await _httpClient
            .post(
              Uri.parse('https://kitsu.io/api/edge/library-entries'),
              headers: headers,
              body: jsonEncode({
                'data': {
                  'type': 'libraryEntries',
                  'attributes': attrs,
                  'relationships': {
                    'user': {
                      'data': {'type': 'users', 'id': userId},
                    },
                    'manga': {
                      'data': {'type': 'manga', 'id': record.remoteId},
                    },
                  },
                },
              }),
            )
            .timeout(const Duration(seconds: 10));
        return createRes.statusCode >= 200 && createRes.statusCode < 300;
      }
    } catch (e) {
      AppLogger.warn('Kitsu updateProgress error', e);
      return false;
    }
  }

  Future<bool> _updateMangaUpdatesProgress(MangaTrackingRecord record) async {
    final tok = _trackerTokens['mangaupdates'];
    if (tok == null || tok.isEmpty) return false;
    final seriesId = int.tryParse(record.remoteId);
    if (seriesId == null) return false;

    final listId = switch (record.status.toLowerCase()) {
      'completed' => 1,
      'plan to read' || 'planning' => 2,
      'on hold' || 'paused' => 3,
      'dropped' => 4,
      _ => 0, // Reading list
    };

    final payload = [
      {
        'series': {'id': seriesId},
        'list_id': listId,
        'status': {'chapter': record.lastChapterRead},
      },
    ];
    final headers = {
      'Authorization': 'Bearer $tok',
      'Content-Type': 'application/json',
    };

    try {
      var res = await _httpClient
          .post(
            Uri.parse('https://api.mangaupdates.com/v1/lists/series/update'),
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 400 || res.statusCode == 404) {
        // Series not yet on list — add it
        res = await _httpClient
            .post(
              Uri.parse('https://api.mangaupdates.com/v1/lists/series'),
              headers: headers,
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 10));
      }
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      AppLogger.warn('MangaUpdates updateProgress error', e);
      return false;
    }
  }

  // -------------------------------------------------------------
  // ANILIST CORE API
  // -------------------------------------------------------------

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
      final res = await _httpClient
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
      final res = await _httpClient
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

  Future<bool> updateProgress({
    required int mediaId,
    required int chapterProgress,
    bool isCompleted = false,
    String? status,
    double? score,
  }) async {
    if (!isAuthenticated) return false;

    const mutation = '''
    mutation (\$mediaId: Int, \$progress: Int, \$status: MediaListStatus, \$scoreRaw: Int) {
      SaveMediaListEntry (mediaId: \$mediaId, progress: \$progress, status: \$status, scoreRaw: \$scoreRaw) {
        id
        progress
        status
      }
    }
    ''';

    try {
      final resolvedStatus = status != null && status.isNotEmpty
          ? _mapStatusToAniList(status)
          : (isCompleted ? 'COMPLETED' : 'CURRENT');
      final variables = <String, dynamic>{
        'mediaId': mediaId,
        'progress': chapterProgress,
        'status': resolvedStatus,
        if (score != null && score > 0)
          'scoreRaw': (score * 10).round().clamp(0, 100),
      };
      final res = await _httpClient
          .post(
            Uri.parse('https://graphql.anilist.co'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Authorization': 'Bearer $_token',
            },
            body: jsonEncode({
              'query': mutation,
              'variables': variables,
            }),
          )
          .timeout(const Duration(seconds: 10));

      return res.statusCode == 200;
    } catch (e) {
      AppLogger.warn('AniList updateProgress error', e);
      return false;
    }
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }
}
