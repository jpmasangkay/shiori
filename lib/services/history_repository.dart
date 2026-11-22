import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/app_logger.dart';

/// Repository managing reading progress, history entries, chapter bookmarks, and read states
/// (#1, #3, #4, #6, #18, #31, #33, #34, #38)
class HistoryRepository extends ChangeNotifier {
  final List<ReadHistoryEntry> _localHistory = [];
  final Map<String, ReadProgress> _localProgress = {};
  final Map<String, Set<String>> _readChapters = {};
  final Map<String, Set<String>> _pendingUnreadChapters = {};
  final Set<String> _bookmarkedChapterIds = {};
  final Set<String> _deletedChapterBookmarks = {};
  final Map<String, int> _mangaChapterCounts = {};

  SharedPreferences? _cachedPrefs;

  List<ReadHistoryEntry> get localHistory => List.unmodifiable(_localHistory);
  Map<String, ReadProgress> get localProgress =>
      Map.unmodifiable(_localProgress);
  Map<String, Set<String>> get readChapters => Map.unmodifiable(_readChapters);
  Set<String> get bookmarkedChapterIds =>
      Set.unmodifiable(_bookmarkedChapterIds);

  Future<void> init(SharedPreferences prefs) async {
    _cachedPrefs = prefs;
    _localHistory.clear();
    _localProgress.clear();
    _readChapters.clear();
    _pendingUnreadChapters.clear();
    _bookmarkedChapterIds.clear();
    _deletedChapterBookmarks.clear();

    // 1. Local History
    final localHistJson = prefs.getString('shiori_local_history');
    if (localHistJson != null && localHistJson.isNotEmpty) {
      try {
        final list = jsonDecode(localHistJson) as List<dynamic>;
        _localHistory.clear();
        for (final item in list) {
          if (item is Map) {
            _localHistory.add(
              ReadHistoryEntry.fromMap(Map<String, dynamic>.from(item)),
            );
          }
        }
      } catch (e) {
        AppLogger.warn('Failed to parse shiori_local_history', e);
      }
    }

    // 2. Local Progress
    final localProgJson = prefs.getString('shiori_local_progress');
    if (localProgJson != null && localProgJson.isNotEmpty) {
      try {
        final Map<String, dynamic> map = jsonDecode(localProgJson);
        _localProgress.clear();
        map.forEach((k, v) {
          if (v is Map) {
            _localProgress[k] = ReadProgress.fromMap(
              Map<String, dynamic>.from(v),
            );
          }
        });
      } catch (e) {
        AppLogger.warn('Failed to parse shiori_local_progress', e);
      }
    }

    // 3. Read Chapters (Unread Badges)
    final readChJson = prefs.getString('shiori_read_chapters');
    if (readChJson != null && readChJson.isNotEmpty) {
      try {
        final Map<String, dynamic> map = jsonDecode(readChJson);
        _readChapters.clear();
        map.forEach((k, v) {
          if (v is List) {
            _readChapters[k] = v.map((e) => e.toString()).toSet();
          }
        });
      } catch (e) {
        AppLogger.warn('Failed to parse shiori_read_chapters', e);
      }
    }

    // 4. Chapter Bookmarks
    final bookmarksJson = prefs.getString('shiori_chapter_bookmarks');
    if (bookmarksJson != null && bookmarksJson.isNotEmpty) {
      try {
        final List<dynamic> list = jsonDecode(bookmarksJson);
        _bookmarkedChapterIds.clear();
        _bookmarkedChapterIds.addAll(list.map((e) => e.toString()));
      } catch (e) {
        AppLogger.warn('Failed to parse shiori_chapter_bookmarks', e);
      }
    }

    // 5. Chapter Counts
    final countsJson = prefs.getString('shiori_manga_chapter_counts');
    if (countsJson != null && countsJson.isNotEmpty) {
      try {
        final Map<String, dynamic> map = jsonDecode(countsJson);
        _mangaChapterCounts.clear();
        map.forEach((k, v) {
          if (v is num) _mangaChapterCounts[k] = v.toInt();
        });
      } catch (e) {
        AppLogger.warn('Failed to parse shiori_manga_chapter_counts', e);
      }
    }

    // 6. Pending Unread Chapter Tombstones (offline mark-as-unread resilience)
    final pendingUnreadJson = prefs.getString('shiori_pending_unread_chapters');
    if (pendingUnreadJson != null && pendingUnreadJson.isNotEmpty) {
      try {
        final Map<String, dynamic> map = jsonDecode(pendingUnreadJson);
        _pendingUnreadChapters.clear();
        map.forEach((k, v) {
          if (v is List) {
            _pendingUnreadChapters[k] = v.map((e) => e.toString()).toSet();
          }
        });
      } catch (e) {
        AppLogger.warn('Failed to parse shiori_pending_unread_chapters', e);
      }
    }

    // 7. Deleted Chapter Bookmark Tombstones (offline unbookmark resilience)
    final deletedBmJson = prefs.getString('shiori_deleted_chapter_bookmarks');
    if (deletedBmJson != null && deletedBmJson.isNotEmpty) {
      try {
        final List<dynamic> list = jsonDecode(deletedBmJson);
        _deletedChapterBookmarks.clear();
        _deletedChapterBookmarks.addAll(list.map((e) => e.toString()));
      } catch (e) {
        AppLogger.warn('Failed to parse shiori_deleted_chapter_bookmarks', e);
      }
    }
  }

  Future<void> _persistPendingUnreadChapters() async {
    try {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      final map = <String, List<String>>{
        for (final entry in _pendingUnreadChapters.entries)
          if (entry.value.isNotEmpty) entry.key: entry.value.toList(),
      };
      await prefs.setString('shiori_pending_unread_chapters', jsonEncode(map));
    } catch (e) {
      AppLogger.warn('Failed to persist pending unread chapters', e);
    }
  }

  Future<void> _persistDeletedChapterBookmarks() async {
    try {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      await prefs.setString(
        'shiori_deleted_chapter_bookmarks',
        jsonEncode(_deletedChapterBookmarks.toList()),
      );
    } catch (e) {
      AppLogger.warn('Failed to persist deleted chapter bookmarks', e);
    }
  }

  Future<void> _persistLocalHistory() async {
    try {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      final list = _localHistory.map((e) => e.toMap()).toList();
      await prefs.setString('shiori_local_history', jsonEncode(list));
    } catch (e) {
      AppLogger.warn('Failed to persist local history', e);
    }
  }

  Future<void> _persistLocalProgress() async {
    try {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      final map = <String, Map<String, dynamic>>{
        for (final entry in _localProgress.entries)
          entry.key: entry.value.toMap(),
      };
      await prefs.setString('shiori_local_progress', jsonEncode(map));
    } catch (e) {
      AppLogger.warn('Failed to persist local progress', e);
    }
  }

  Future<void> _persistReadChapters() async {
    try {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      final map = <String, List<String>>{
        for (final entry in _readChapters.entries)
          entry.key: entry.value.toList(),
      };
      await prefs.setString('shiori_read_chapters', jsonEncode(map));
    } catch (e) {
      AppLogger.warn('Failed to persist read chapters', e);
    }
  }

  Future<void> _persistChapterBookmarks() async {
    try {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      await prefs.setString(
        'shiori_chapter_bookmarks',
        jsonEncode(_bookmarkedChapterIds.toList()),
      );
    } catch (e) {
      AppLogger.warn('Failed to persist chapter bookmarks', e);
    }
  }

  Future<void> _persistChapterCounts() async {
    try {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      await prefs.setString(
        'shiori_manga_chapter_counts',
        jsonEncode(_mangaChapterCounts),
      );
    } catch (e) {
      AppLogger.warn('Failed to persist chapter counts', e);
    }
  }

  // ---- Reading Progress (#6, #31, #33) ----

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
    DateTime? updatedAt,
    http.Client? client,
    String? baseUrl,
    Map<String, String>? headers,
  }) async {
    if (completed) {
      _readChapters.putIfAbsent(mangaId, () => <String>{}).add(chapterId);
      _persistReadChapters();
    }

    final entry = ReadProgress(
      mangaId: mangaId,
      chapterId: chapterId,
      mangaTitle: mangaTitle ?? '',
      cover: cover ?? '',
      source: source ?? 'mangadex',
      chapterNumber: chapterNumber ?? '',
      chapterTitle: chapterTitle ?? '',
      page: page,
      totalPages: totalPages,
      completed: completed,
      updatedAt: updatedAt ?? DateTime.now(),
    );

    _localProgress[mangaId] = entry;
    await _persistLocalProgress();

    final histEntry = ReadHistoryEntry(
      mangaId: mangaId,
      chapterId: chapterId,
      mangaTitle: mangaTitle ?? '',
      cover: cover ?? '',
      source: source ?? 'mangadex',
      chapterNumber: chapterNumber ?? '',
      chapterTitle: chapterTitle ?? '',
      page: page,
      totalPages: totalPages,
      completed: completed,
      updatedAt: entry.updatedAt,
    );

    _localHistory.removeWhere((e) => e.mangaId == mangaId);
    _localHistory.insert(0, histEntry);
    if (_localHistory.length > 100) {
      _localHistory.removeRange(100, _localHistory.length);
    }
    await _persistLocalHistory();
    notifyListeners();

    if (client != null && baseUrl != null && headers != null) {
      try {
        await client
            .post(
              Uri.parse('$baseUrl/progress'),
              headers: headers,
              body: jsonEncode(entry.toMap()),
            )
            .timeout(const Duration(seconds: 8));
      } catch (e) {
        AppLogger.warn('Cloud progress save failed for $mangaId', e);
      }
    }
  }

  Map<String, dynamic> getMangaProgress(String mangaId) {
    final localLast = _localProgress[mangaId];
    final readSet = _readChapters[mangaId] ?? <String>{};
    return {
      'mangaId': mangaId,
      'completedChapters': readSet.toList(),
      'completedChapterIds': readSet.toList(),
      'lastRead': localLast?.toMap(),
    };
  }

  // ---- Read & Unread Chapters Tracking (#34) ----

  bool isChapterRead(String mangaId, String chapterId) {
    return _readChapters[mangaId]?.contains(chapterId) ?? false;
  }

  Set<String> getReadChapterIds(String mangaId) {
    return Set<String>.from(_readChapters[mangaId] ?? const <String>{});
  }

  Future<void> markChapterRead(
    String mangaId,
    String chapterId, {
    bool read = true,
    http.Client? client,
    String? baseUrl,
    Map<String, String>? headers,
  }) async {
    final set = _readChapters.putIfAbsent(mangaId, () => <String>{});
    if (read) {
      set.add(chapterId);
      _pendingUnreadChapters[mangaId]?.remove(chapterId);
    } else {
      set.remove(chapterId);
      _pendingUnreadChapters
          .putIfAbsent(mangaId, () => <String>{})
          .add(chapterId);
    }
    await _persistReadChapters();
    await _persistPendingUnreadChapters();
    notifyListeners();

    // Silent background cloud sync for read status update (#34)
    if (client != null && baseUrl != null && headers != null) {
      try {
        final res = await client
            .post(
              Uri.parse('$baseUrl/progress/read-status'),
              headers: headers,
              body: jsonEncode({
                'mangaId': mangaId,
                'chapterId': chapterId,
                'read': read,
              }),
            )
            .timeout(const Duration(seconds: 6));
        if (!read && (res.statusCode == 200 || res.statusCode == 201)) {
          _pendingUnreadChapters[mangaId]?.remove(chapterId);
          unawaited(_persistPendingUnreadChapters());
        }
      } catch (e) {
        AppLogger.warn('Cloud markChapterRead failed for $chapterId', e);
      }
    }
  }

  Future<void> markChaptersRead(
    String mangaId,
    List<String> chapterIds, {
    bool read = true,
    http.Client? client,
    String? baseUrl,
    Map<String, String>? headers,
  }) async {
    final set = _readChapters.putIfAbsent(mangaId, () => <String>{});
    if (read) {
      set.addAll(chapterIds);
      _pendingUnreadChapters[mangaId]?.removeAll(chapterIds);
    } else {
      set.removeAll(chapterIds);
      _pendingUnreadChapters
          .putIfAbsent(mangaId, () => <String>{})
          .addAll(chapterIds);
    }
    await _persistReadChapters();
    await _persistPendingUnreadChapters();
    notifyListeners();

    // Silent background cloud sync for batch read status update (#34)
    if (client != null &&
        baseUrl != null &&
        headers != null &&
        chapterIds.isNotEmpty) {
      try {
        final res = await client
            .post(
              Uri.parse('$baseUrl/progress/read-status'),
              headers: headers,
              body: jsonEncode({
                'mangaId': mangaId,
                'chapterIds': chapterIds,
                'read': read,
              }),
            )
            .timeout(const Duration(seconds: 8));
        if (!read && (res.statusCode == 200 || res.statusCode == 201)) {
          _pendingUnreadChapters[mangaId]?.removeAll(chapterIds);
          unawaited(_persistPendingUnreadChapters());
        }
      } catch (e) {
        AppLogger.warn(
          'Cloud markChaptersRead failed for ${chapterIds.length} chapters',
          e,
        );
      }
    }
  }

  void recordChapterCount(String mangaId, int count) {
    if (count > 0 && (_mangaChapterCounts[mangaId] ?? 0) < count) {
      _mangaChapterCounts[mangaId] = count;
      _persistChapterCounts();
      notifyListeners();
    }
  }

  int getChapterCount(String mangaId) => _mangaChapterCounts[mangaId] ?? 0;

  int getUnreadCount(String mangaId) {
    final total = _mangaChapterCounts[mangaId] ?? 0;
    final read = _readChapters[mangaId]?.length ?? 0;
    final diff = total - read;
    return diff > 0 ? diff : 0;
  }

  // ---- Chapter Bookmarks ----

  bool isChapterBookmarked(String chapterId) {
    return _bookmarkedChapterIds.contains(chapterId);
  }

  Future<bool> toggleChapterBookmark(
    String chapterId, {
    http.Client? client,
    String? baseUrl,
    Map<String, String>? headers,
  }) async {
    final has = _bookmarkedChapterIds.contains(chapterId);
    if (has) {
      _bookmarkedChapterIds.remove(chapterId);
      _deletedChapterBookmarks.add(chapterId);
    } else {
      _bookmarkedChapterIds.add(chapterId);
      _deletedChapterBookmarks.remove(chapterId);
    }
    await _persistChapterBookmarks();
    await _persistDeletedChapterBookmarks();
    notifyListeners();

    // Silent background cloud sync for real-time chapter bookmark update
    if (client != null && baseUrl != null && headers != null) {
      try {
        unawaited(
          client
              .post(
                Uri.parse('$baseUrl/progress/chapter-bookmarks/toggle'),
                headers: headers,
                body: jsonEncode({'chapterId': chapterId}),
              )
              .timeout(const Duration(seconds: 5))
              .then((res) {
                if (has && (res.statusCode == 200 || res.statusCode == 201)) {
                  _deletedChapterBookmarks.remove(chapterId);
                  unawaited(_persistDeletedChapterBookmarks());
                }
              })
              .catchError((_) {}),
        );
      } catch (e) {
        AppLogger.warn('Cloud chapter bookmark toggle failed', e);
      }
    }

    return !has;
  }

  Future<void> setChapterBookmarked(
    String chapterId,
    bool bookmarked, {
    http.Client? client,
    String? baseUrl,
    Map<String, String>? headers,
  }) async {
    final has = _bookmarkedChapterIds.contains(chapterId);
    if (bookmarked) {
      _bookmarkedChapterIds.add(chapterId);
      _deletedChapterBookmarks.remove(chapterId);
    } else {
      _bookmarkedChapterIds.remove(chapterId);
      _deletedChapterBookmarks.add(chapterId);
    }
    await _persistChapterBookmarks();
    await _persistDeletedChapterBookmarks();
    notifyListeners();

    // Silent background cloud sync for real-time chapter bookmark update
    if (has != bookmarked &&
        client != null &&
        baseUrl != null &&
        headers != null) {
      try {
        unawaited(
          client
              .post(
                Uri.parse('$baseUrl/progress/chapter-bookmarks/toggle'),
                headers: headers,
                body: jsonEncode({'chapterId': chapterId}),
              )
              .timeout(const Duration(seconds: 5))
              .then((res) {
                if (!bookmarked &&
                    (res.statusCode == 200 || res.statusCode == 201)) {
                  _deletedChapterBookmarks.remove(chapterId);
                  unawaited(_persistDeletedChapterBookmarks());
                }
              })
              .catchError((_) {}),
        );
      } catch (e) {
        AppLogger.warn('Cloud setChapterBookmarked failed', e);
      }
    }
  }

  Set<String> getBookmarkedChapterIds() {
    return Set<String>.from(_bookmarkedChapterIds);
  }

  // ---- History Management & Deletion (#18) ----

  List<ReadHistoryEntry> getHistoryEntries() {
    return List<ReadHistoryEntry>.from(_localHistory);
  }

  List<Map<String, dynamic>> getHistoryAsMaps() {
    return _localHistory.map((e) => e.toMap()).toList();
  }

  Future<void> removeHistoryEntry(
    String chapterId, {
    http.Client? client,
    String? baseUrl,
    Map<String, String>? headers,
  }) async {
    _localHistory.removeWhere((e) => e.chapterId == chapterId);
    _localProgress.removeWhere((_, p) => p.chapterId == chapterId);
    await _persistLocalHistory();
    await _persistLocalProgress();
    notifyListeners();

    if (client != null && baseUrl != null && headers != null) {
      try {
        await client
            .delete(
              Uri.parse('$baseUrl/progress/history/$chapterId'),
              headers: headers,
            )
            .timeout(const Duration(seconds: 8));
      } catch (e) {
        AppLogger.warn('Cloud removeHistoryEntry failed for $chapterId', e);
      }
    }
  }

  Future<void> clearHistory({
    http.Client? client,
    String? baseUrl,
    Map<String, String>? headers,
  }) async {
    _localHistory.clear();
    _localProgress.clear();
    await _persistLocalHistory();
    await _persistLocalProgress();
    notifyListeners();

    if (client != null && baseUrl != null && headers != null) {
      try {
        await client
            .delete(Uri.parse('$baseUrl/progress/history'), headers: headers)
            .timeout(const Duration(seconds: 8));
      } catch (e) {
        AppLogger.warn('Cloud clearHistory failed', e);
      }
    }
  }

  // ---- Timestamp-Based Cloud Merge & Full Upload (#31, #33, #34) ----

  final Map<String, Set<String>> _recentlyFlushedUnreadChapters = {};
  final Set<String> _recentlyFlushedDeletedBookmarks = {};

  Future<void> uploadProgressAndHistory(
    http.Client client,
    String baseUrl,
    Map<String, String> headers,
  ) async {
    // 0. Flush any pending offline "mark as unread" mutations first
    if (_pendingUnreadChapters.isNotEmpty) {
      for (final entry in _pendingUnreadChapters.entries.toList()) {
        if (entry.value.isEmpty) continue;
        try {
          final res = await client
              .post(
                Uri.parse('$baseUrl/progress/read-status'),
                headers: headers,
                body: jsonEncode({
                  'mangaId': entry.key,
                  'chapterIds': entry.value.toList(),
                  'read': false,
                }),
              )
              .timeout(const Duration(seconds: 6));
          if (res.statusCode == 200 || res.statusCode == 201) {
            _recentlyFlushedUnreadChapters
                .putIfAbsent(entry.key, () => <String>{})
                .addAll(entry.value);
            _pendingUnreadChapters.remove(entry.key);
          }
        } catch (_) {}
      }
      await _persistPendingUnreadChapters();
    }

    if (_localProgress.isEmpty &&
        _localHistory.isEmpty &&
        _readChapters.isEmpty &&
        _bookmarkedChapterIds.isEmpty &&
        _deletedChapterBookmarks.isEmpty) {
      return;
    }

    final entriesToUpload = <Map<String, dynamic>>[];
    final seenChapters = <String>{};

    for (final p in _localProgress.values) {
      if (seenChapters.add(p.chapterId)) {
        entriesToUpload.add(p.toMap());
      }
    }
    for (final h in _localHistory) {
      if (seenChapters.add(h.chapterId)) {
        entriesToUpload.add(h.toMap());
      }
    }

    final readChaptersMap = <String, List<String>>{
      for (final e in _readChapters.entries) e.key: e.value.toList(),
    };

    try {
      await client
          .post(
            Uri.parse('$baseUrl/progress/batch'),
            headers: headers,
            body: jsonEncode({
              'entries': entriesToUpload,
              'readChaptersByManga': readChaptersMap,
              'chapterBookmarks': _bookmarkedChapterIds.toList(),
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (_bookmarkedChapterIds.isNotEmpty ||
          _deletedChapterBookmarks.isNotEmpty) {
        try {
          final res = await client
              .put(
                Uri.parse('$baseUrl/progress/chapter-bookmarks'),
                headers: headers,
                body: jsonEncode({
                  'chapterBookmarks': _bookmarkedChapterIds.toList(),
                }),
              )
              .timeout(const Duration(seconds: 6));
          if (res.statusCode == 200 || res.statusCode == 201) {
            _recentlyFlushedDeletedBookmarks.addAll(_deletedChapterBookmarks);
            _deletedChapterBookmarks.clear();
            await _persistDeletedChapterBookmarks();
          }
        } catch (_) {}
      }
    } catch (e) {
      AppLogger.warn('uploadProgressAndHistory failed', e);
    }
  }

  Future<void> downloadAndMergeSyncData(
    http.Client client,
    String baseUrl,
    Map<String, String> headers,
  ) async {
    // 1. Try /api/progress/sync first
    try {
      final syncRes = await client
          .get(Uri.parse('$baseUrl/progress/sync'), headers: headers)
          .timeout(const Duration(seconds: 8));
      if (syncRes.statusCode == 200) {
        final data = jsonDecode(syncRes.body) as Map<String, dynamic>;
        if (data.containsKey('history') ||
            data.containsKey('progressByManga') ||
            data.containsKey('chapterBookmarks')) {
          _mergeSyncPayload(data);
          await _persistLocalHistory();
          await _persistLocalProgress();
          await _persistReadChapters();
          await _persistChapterBookmarks();
          notifyListeners();
          return;
        }
      }
    } catch (_) {
      // Fall back to /api/progress/history
    }

    // 2. Fallback to /api/progress/history with timestamp comparison (#31)
    try {
      final histRes = await client
          .get(Uri.parse('$baseUrl/progress/history'), headers: headers)
          .timeout(const Duration(seconds: 8));
      if (histRes.statusCode == 200) {
        final data = jsonDecode(histRes.body) as Map<String, dynamic>;
        final list = data['items'] as List<dynamic>? ?? [];
        for (final item in list) {
          if (item is Map) {
            final cloudEntry = ReadHistoryEntry.fromMap(
              Map<String, dynamic>.from(item),
            );
            if (cloudEntry.mangaId.isEmpty) continue;
            _mergeHistoryEntryWithTimestamp(cloudEntry);
          }
        }
        await _persistLocalHistory();
        await _persistLocalProgress();
      }
    } catch (e) {
      AppLogger.warn('downloadAndMergeSyncData fallback failed', e);
    }

    // 3. Fallback check for chapter bookmarks if sync endpoint did not deliver them
    try {
      final bmRes = await client
          .get(
            Uri.parse('$baseUrl/progress/chapter-bookmarks'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 6));
      if (bmRes.statusCode == 200) {
        final data = jsonDecode(bmRes.body) as Map<String, dynamic>;
        final bms = data['chapterBookmarks'] as List<dynamic>?;
        if (bms != null) {
          for (final b in bms) {
            final bStr = b?.toString().trim();
            if (bStr != null && bStr.isNotEmpty) {
              _bookmarkedChapterIds.add(bStr);
            }
          }
          await _persistChapterBookmarks();
        }
      }
    } catch (_) {}

    notifyListeners();
  }

  void _mergeSyncPayload(Map<String, dynamic> data) {
    // 1. History items
    final historyList = data['history'] as List<dynamic>? ?? [];
    for (final item in historyList) {
      if (item is Map) {
        final cloudEntry = ReadHistoryEntry.fromMap(
          Map<String, dynamic>.from(item),
        );
        if (cloudEntry.mangaId.isNotEmpty) {
          _mergeHistoryEntryWithTimestamp(cloudEntry);
        }
      }
    }

    // 2. Progress per manga
    final progressMap = data['progressByManga'] as Map<String, dynamic>? ?? {};
    progressMap.forEach((mangaId, pData) {
      if (pData is Map) {
        final cloudProg = ReadProgress.fromMap(
          Map<String, dynamic>.from(pData),
        );
        final localProg = _localProgress[mangaId];
        if (localProg == null ||
            (cloudProg.updatedAt != null &&
                localProg.updatedAt != null &&
                cloudProg.updatedAt!.isAfter(localProg.updatedAt!))) {
          _localProgress[mangaId] = cloudProg;
        }
      }
    });

    // 3. Read chapter sets (Unread badges cross-device) (#34)
    final readChaptersMap =
        data['readChaptersByManga'] as Map<String, dynamic>? ?? {};
    readChaptersMap.forEach((mangaId, list) {
      if (list is List) {
        final pendingUnread =
            _pendingUnreadChapters[mangaId] ?? const <String>{};
        final recentlyFlushed =
            _recentlyFlushedUnreadChapters[mangaId] ?? const <String>{};
        final localSet = _readChapters.putIfAbsent(mangaId, () => <String>{});
        for (final e in list) {
          final chId = e.toString();
          if (!pendingUnread.contains(chId) &&
              !recentlyFlushed.contains(chId)) {
            localSet.add(chId);
          }
        }
      }
    });
    _recentlyFlushedUnreadChapters.clear();

    // 4. Chapter ribbon favorites cross-device cloud sync
    final chapterBookmarksList = data['chapterBookmarks'] as List<dynamic>?;
    if (chapterBookmarksList != null) {
      for (final b in chapterBookmarksList) {
        final bStr = b?.toString().trim();
        if (bStr != null &&
            bStr.isNotEmpty &&
            !_deletedChapterBookmarks.contains(bStr) &&
            !_recentlyFlushedDeletedBookmarks.contains(bStr)) {
          _bookmarkedChapterIds.add(bStr);
        }
      }
    }
    _recentlyFlushedDeletedBookmarks.clear();
  }

  void mergeRemoteHistory(List<dynamic> remoteItems) {
    for (final item in remoteItems) {
      if (item is Map) {
        final cloudEntry = ReadHistoryEntry.fromMap(
          Map<String, dynamic>.from(item),
        );
        if (cloudEntry.mangaId.isNotEmpty) {
          _mergeHistoryEntryWithTimestamp(cloudEntry);
        }
      } else if (item is ReadHistoryEntry) {
        _mergeHistoryEntryWithTimestamp(item);
      }
    }
    notifyListeners();
  }

  /// Timestamp-based merge (#31): compares `updatedAt` and keeps whichever is newer
  void _mergeHistoryEntryWithTimestamp(ReadHistoryEntry cloudEntry) {
    final idx = _localHistory.indexWhere(
      (h) => h.mangaId == cloudEntry.mangaId,
    );
    if (idx == -1) {
      _localHistory.add(cloudEntry);
    } else {
      final local = _localHistory[idx];
      final localDate =
          local.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final cloudDate =
          cloudEntry.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      if (cloudDate.isAfter(localDate)) {
        _localHistory[idx] = cloudEntry;
      }
    }

    final localProg = _localProgress[cloudEntry.mangaId];
    if (localProg == null) {
      _localProgress[cloudEntry.mangaId] = ReadProgress(
        mangaId: cloudEntry.mangaId,
        chapterId: cloudEntry.chapterId,
        mangaTitle: cloudEntry.mangaTitle,
        cover: cloudEntry.cover,
        source: cloudEntry.source,
        chapterNumber: cloudEntry.chapterNumber,
        chapterTitle: cloudEntry.chapterTitle,
        page: cloudEntry.page,
        totalPages: cloudEntry.totalPages,
        completed: cloudEntry.completed,
        updatedAt: cloudEntry.updatedAt,
      );
    } else {
      final localDate =
          localProg.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final cloudDate =
          cloudEntry.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      if (cloudDate.isAfter(localDate)) {
        _localProgress[cloudEntry.mangaId] = localProg.copyWith(
          chapterId: cloudEntry.chapterId,
          chapterNumber: cloudEntry.chapterNumber,
          chapterTitle: cloudEntry.chapterTitle,
          page: cloudEntry.page,
          totalPages: cloudEntry.totalPages,
          completed: cloudEntry.completed,
          updatedAt: cloudEntry.updatedAt,
        );
      }
    }
  }

  /// Wipes all local history, reading progress, and read marks from this device (#38)
  Future<void> clearLocalData() async {
    _localHistory.clear();
    _localProgress.clear();
    _readChapters.clear();
    _pendingUnreadChapters.clear();
    _bookmarkedChapterIds.clear();
    _deletedChapterBookmarks.clear();
    _mangaChapterCounts.clear();

    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.remove('shiori_local_history');
    await prefs.remove('shiori_local_progress');
    await prefs.remove('shiori_read_chapters');
    await prefs.remove('shiori_pending_unread_chapters');
    await prefs.remove('shiori_chapter_bookmarks');
    await prefs.remove('shiori_deleted_chapter_bookmarks');
    await prefs.remove('shiori_manga_chapter_counts');
    notifyListeners();
  }
}
