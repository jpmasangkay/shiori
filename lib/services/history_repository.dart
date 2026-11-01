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
  final Set<String> _bookmarkedChapterIds = {};
  final Map<String, int> _mangaChapterCounts = {};

  SharedPreferences? _cachedPrefs;

  List<ReadHistoryEntry> get localHistory => List.unmodifiable(_localHistory);
  Map<String, ReadProgress> get localProgress => Map.unmodifiable(_localProgress);
  Map<String, Set<String>> get readChapters => Map.unmodifiable(_readChapters);
  Set<String> get bookmarkedChapterIds => Set.unmodifiable(_bookmarkedChapterIds);

  Future<void> init(SharedPreferences prefs) async {
    _cachedPrefs = prefs;
    _localHistory.clear();
    _localProgress.clear();
    _readChapters.clear();
    _bookmarkedChapterIds.clear();

    // 1. Local History
    final localHistJson = prefs.getString('shiori_local_history');
    if (localHistJson != null && localHistJson.isNotEmpty) {
      try {
        final list = jsonDecode(localHistJson) as List<dynamic>;
        _localHistory.clear();
        for (final item in list) {
          if (item is Map) {
            _localHistory.add(ReadHistoryEntry.fromMap(Map<String, dynamic>.from(item)));
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
            _localProgress[k] = ReadProgress.fromMap(Map<String, dynamic>.from(v));
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
        for (final entry in _localProgress.entries) entry.key: entry.value.toMap(),
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
        for (final entry in _readChapters.entries) entry.key: entry.value.toList(),
      };
      await prefs.setString('shiori_read_chapters', jsonEncode(map));
    } catch (e) {
      AppLogger.warn('Failed to persist read chapters', e);
    }
  }

  Future<void> _persistChapterBookmarks() async {
    try {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      await prefs.setString('shiori_chapter_bookmarks', jsonEncode(_bookmarkedChapterIds.toList()));
    } catch (e) {
      AppLogger.warn('Failed to persist chapter bookmarks', e);
    }
  }

  Future<void> _persistChapterCounts() async {
    try {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      await prefs.setString('shiori_manga_chapter_counts', jsonEncode(_mangaChapterCounts));
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
            .delete(Uri.parse('$baseUrl/progress/history/$chapterId'), headers: headers)
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

  Future<void> uploadProgressAndHistory(
    http.Client client,
    String baseUrl,
    Map<String, String> headers,
  ) async {
    if (_localProgress.isEmpty && _localHistory.isEmpty && _readChapters.isEmpty) return;

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
            }),
          )
          .timeout(const Duration(seconds: 10));
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
        if (data.containsKey('history') || data.containsKey('progressByManga')) {
          _mergeSyncPayload(data);
          await _persistLocalHistory();
          await _persistLocalProgress();
          await _persistReadChapters();
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
            final cloudEntry = ReadHistoryEntry.fromMap(Map<String, dynamic>.from(item));
            if (cloudEntry.mangaId.isEmpty) continue;
            _mergeHistoryEntryWithTimestamp(cloudEntry);
          }
        }
        await _persistLocalHistory();
        await _persistLocalProgress();
        notifyListeners();
      }
    } catch (e) {
      AppLogger.warn('downloadAndMergeSyncData fallback failed', e);
    }
  }

  void _mergeSyncPayload(Map<String, dynamic> data) {
    // 1. History items
    final historyList = data['history'] as List<dynamic>? ?? [];
    for (final item in historyList) {
      if (item is Map) {
        final cloudEntry = ReadHistoryEntry.fromMap(Map<String, dynamic>.from(item));
        if (cloudEntry.mangaId.isNotEmpty) {
          _mergeHistoryEntryWithTimestamp(cloudEntry);
        }
      }
    }

    // 2. Progress per manga
    final progressMap = data['progressByManga'] as Map<String, dynamic>? ?? {};
    progressMap.forEach((mangaId, pData) {
      if (pData is Map) {
        final cloudProg = ReadProgress.fromMap(Map<String, dynamic>.from(pData));
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
    final readChaptersMap = data['readChaptersByManga'] as Map<String, dynamic>? ?? {};
    readChaptersMap.forEach((mangaId, list) {
      if (list is List) {
        final localSet = _readChapters.putIfAbsent(mangaId, () => <String>{});
        localSet.addAll(list.map((e) => e.toString()));
      }
    });
  }

  void mergeRemoteHistory(List<dynamic> remoteItems) {
    for (final item in remoteItems) {
      if (item is Map) {
        final cloudEntry = ReadHistoryEntry.fromMap(Map<String, dynamic>.from(item));
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
    final idx = _localHistory.indexWhere((h) => h.mangaId == cloudEntry.mangaId);
    if (idx == -1) {
      _localHistory.add(cloudEntry);
    } else {
      final local = _localHistory[idx];
      final localDate = local.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final cloudDate = cloudEntry.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
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
      final localDate = localProg.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final cloudDate = cloudEntry.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
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
    _bookmarkedChapterIds.clear();
    _mangaChapterCounts.clear();

    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.remove('shiori_local_history');
    await prefs.remove('shiori_local_progress');
    await prefs.remove('shiori_read_chapters');
    await prefs.remove('shiori_chapter_bookmarks');
    await prefs.remove('shiori_manga_chapter_counts');
    notifyListeners();
  }
}
