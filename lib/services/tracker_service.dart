import 'dart:async';
import 'dart:convert';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:manga_reader/models/tracking_models.dart';
import 'package:manga_reader/services/app_logger.dart';
import 'package:manga_reader/services/secure_token_store.dart';

class AniListUser {
  final int id;
  final String name;
  final String? avatarUrl;

  const AniListUser({required this.id, required this.name, this.avatarUrl});
}

/// Multi-tracker tracking service supporting AniList, MyAnimeList, Kitsu, MangaUpdates, etc.
class TrackerService extends ChangeNotifier {
  TrackerService._();
  static final TrackerService instance = TrackerService._();

  static const String _keyToken = 'anilist_access_token';
  static const String _keyUserName = 'anilist_user_name';
  static const String _keyUserAvatar = 'anilist_user_avatar';
  static const String _keyAutoUpdate = 'tracker_auto_update_enabled';
  static const String _keyUpdateWhenMarkedRead = 'tracker_update_when_marked_read';
  static const String _keyMangaRecordsPrefix = 'manga_tracking_records_v1_';

  // Default Shiori AniList Client ID
  static const String defaultClientId = '17865';

  final SecureTokenStore _tokenStore = SecureTokenStore.instance;
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;

  SharedPreferences? _cachedPrefs;
  String? _token;
  AniListUser? _currentUser;
  bool _autoUpdateEnabled = true;
  String _updateProgressWhenMarkedRead = 'Always'; // 'Always', 'Never'

  // Per-tracker tokens / usernames
  final Map<String, String> _trackerTokens = {};
  final Map<String, String> _trackerUsernames = {};

  // Per-manga tracked records in-memory cache: mangaId -> List<MangaTrackingRecord>
  final Map<String, List<MangaTrackingRecord>> _recordsCache = {};

  bool get isAuthenticated => _token != null && _token!.isNotEmpty;
  AniListUser? get currentUser => _currentUser;
  bool get autoUpdateEnabled => _autoUpdateEnabled;
  bool get updateProgressAfterReading => _autoUpdateEnabled;
  String get updateProgressWhenMarkedRead => _updateProgressWhenMarkedRead;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _cachedPrefs = prefs;

      // Migrate legacy prefs if present
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

      // Load known tracker tokens
      for (final t in TrackerServiceMeta.all) {
        if (t.id == 'anilist') continue;
        final tok = prefs.getString('tracker_token_${t.id}');
        final usr = prefs.getString('tracker_username_${t.id}');
        if (tok != null && tok.isNotEmpty) _trackerTokens[t.id] = tok;
        if (usr != null && usr.isNotEmpty) _trackerUsernames[t.id] = usr;
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

  /// Handles incoming `shiori://auth/anilist#access_token=...` callback
  Future<bool> handleAuthRedirect(Uri uri) async {
    if (uri.scheme == 'shiori' && uri.host == 'auth') {
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

  Future<bool> loginTracker(String trackerId, String token,
      {String? username}) async {
    if (trackerId == 'anilist') {
      return await loginWithToken(token);
    }
    final cleanTok = token.trim();
    if (cleanTok.isEmpty) return false;
    _trackerTokens[trackerId] = cleanTok;
    if (username != null) _trackerUsernames[trackerId] = username.trim();

    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.setString('tracker_token_$trackerId', cleanTok);
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
    try {
      return records.firstWhere((r) => r.trackerId == trackerId);
    } catch (_) {
      return null;
    }
  }

  bool isMangaTracked(String mangaId) {
    return getTrackingRecordsForManga(mangaId).isNotEmpty;
  }

  Future<void> saveTrackingRecord(MangaTrackingRecord record) async {
    final list = List<MangaTrackingRecord>.from(
        getTrackingRecordsForManga(record.mangaId));
    list.removeWhere((r) => r.trackerId == record.trackerId);
    list.add(record);
    _recordsCache[record.mangaId] = list;

    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(list.map((r) => r.toJson()).toList());
    await prefs.setString('$_keyMangaRecordsPrefix${record.mangaId}', jsonStr);

    // If tracker is AniList and authenticated, sync to remote API
    if (record.trackerId == 'anilist' && isAuthenticated) {
      final mediaId = int.tryParse(record.remoteId);
      if (mediaId != null) {
        await updateProgress(
          mediaId: mediaId,
          chapterProgress: record.lastChapterRead,
          isCompleted: record.status.toUpperCase() == 'COMPLETED',
        );
      }
    }

    notifyListeners();
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
  // AUTOMATIC UPDATES (READING & MARKING READ)
  // -------------------------------------------------------------

  /// Called when a chapter is finished in the reader
  Future<void> onChapterFinished({
    required String mangaTitle,
    required String? chapterNumber,
    String? mangaId,
  }) async {
    if (!_autoUpdateEnabled) return;
    if (chapterNumber == null || chapterNumber.isEmpty) return;

    final numVal = double.tryParse(chapterNumber)?.floor();
    if (numVal == null || numVal <= 0) return;

    try {
      // 1. Sync AniList if user is logged in
      if (isAuthenticated) {
        final mediaId = await searchMangaId(mangaTitle);
        if (mediaId != null) {
          await updateProgress(mediaId: mediaId, chapterProgress: numVal);
          AppLogger.info(
            'TrackerService: Updated AniList for $mangaTitle to Ch. $numVal',
          );
        }
      }

      // 2. Sync any explicitly linked trackers for this manga
      if (mangaId != null && mangaId.isNotEmpty) {
        final records = getTrackingRecordsForManga(mangaId);
        for (final r in records) {
          if (numVal > r.lastChapterRead) {
            final updated = r.copyWith(
              lastChapterRead: numVal,
              updatedAt: DateTime.now(),
            );
            await saveTrackingRecord(updated);
          }
        }
      }
    } catch (e) {
      AppLogger.warn('TrackerService onChapterFinished error', e);
    }
  }

  /// Called when chapters are marked read from DetailScreen
  Future<void> onChaptersMarkedRead({
    required String mangaId,
    required String mangaTitle,
    required int maxChapterRead,
  }) async {
    if (_updateProgressWhenMarkedRead != 'Always') return;
    if (maxChapterRead <= 0) return;

    try {
      final records = getTrackingRecordsForManga(mangaId);
      for (final r in records) {
        if (maxChapterRead > r.lastChapterRead) {
          final updated = r.copyWith(
            lastChapterRead: maxChapterRead,
            updatedAt: DateTime.now(),
          );
          await saveTrackingRecord(updated);
        }
      }

      if (isAuthenticated) {
        final mediaId = await searchMangaId(mangaTitle);
        if (mediaId != null) {
          await updateProgress(
            mediaId: mediaId,
            chapterProgress: maxChapterRead,
          );
        }
      }
    } catch (e) {
      AppLogger.warn('TrackerService onChaptersMarkedRead error', e);
    }
  }

  // -------------------------------------------------------------
  // REMOTE SEARCH API IMPLEMENTATIONS
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
        // Fallback simulated result for MangaBaka / Hikka
        return [
          TrackerSearchResult(
            trackerId: trackerId,
            remoteId: 'local_${cleanQuery.hashCode.abs()}',
            title: cleanQuery,
            status: 'Publishing',
            score: 8.5,
          ),
        ];
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
      final res = await http
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
          'https://api.jikan.moe/v4/manga?q=${Uri.encodeComponent(query)}&limit=15');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
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
          'https://kitsu.io/api/edge/manga?filter[text]=${Uri.encodeComponent(query)}&page[limit]=15');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
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
      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
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
          'https://shikimori.one/api/mangas?search=${Uri.encodeComponent(query)}&limit=15');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
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
          'https://api.bgm.tv/search/subject/${Uri.encodeComponent(query)}?type=1&responseGroup=small&max_results=15');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
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

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }
}
