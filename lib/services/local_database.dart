import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class ReadingStatsSummary {
  final int totalMangaInLibrary;
  final int totalChaptersRead;
  final int totalPagesRead;
  final int totalReadingSeconds;
  final int readingStreakDays;
  final Map<String, int> topGenres;
  final Map<String, int> byType;
  final Map<String, int> byStatus;

  const ReadingStatsSummary({
    required this.totalMangaInLibrary,
    required this.totalChaptersRead,
    required this.totalPagesRead,
    required this.totalReadingSeconds,
    required this.readingStreakDays,
    required this.topGenres,
    required this.byType,
    required this.byStatus,
  });
}

/// Normalized, indexed SQLite persistence store powered by `sqflite`.
///
/// Replaces monolithic JSON blobs in `SharedPreferences` (especially the
/// up-to-300×2500 `shiori_local_chapters_v1` blob) with indexed relational tables
/// and ACID incremental writes. Gracefully degrades to no-op on Web or in unit
/// tests where no SQLite database factory is registered.
class LocalDatabase {
  LocalDatabase._();
  static final LocalDatabase instance = LocalDatabase._();

  static const String _dbName = 'shiori_v1.db';
  static const int _dbVersion = 1;

  Database? _db;
  bool _attemptedInit = false;

  bool get isAvailable => _db != null && _db!.isOpen;

  /// Optional override for deterministic in-memory SQLite testing via `sqflite_common_ffi`.
  @visibleForTesting
  Future<void> openForTesting(Database db) async {
    _db = db;
    _attemptedInit = true;
    await _createSchema(db);
  }

  Future<void> closeForTesting() async {
    try {
      await _db?.close();
    } catch (_) {}
    _db = null;
    _attemptedInit = false;
  }

  Future<bool> init() async {
    if (isAvailable) return true;
    if (kIsWeb || _attemptedInit) return isAvailable;
    _attemptedInit = true;
    try {
      final dbDir = await getDatabasesPath();
      final dbPath = p.join(dbDir, _dbName);
      _db = await openDatabase(
        dbPath,
        version: _dbVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await db.execute('PRAGMA journal_mode = WAL');
        },
        onCreate: (db, version) async {
          await _createSchema(db);
        },
      );
      return true;
    } catch (e) {
      // Expected in widget/unit tests running on VM without sqflite_common_ffi
      AppLogger.info('LocalDatabase unavailable (using SharedPreferences fallback): $e');
      _db = null;
      return false;
    }
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS manga (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        cover TEXT NOT NULL DEFAULT '',
        authors_json TEXT NOT NULL DEFAULT '[]',
        status TEXT NOT NULL DEFAULT '',
        type TEXT NOT NULL DEFAULT 'manga',
        tags_json TEXT NOT NULL DEFAULT '[]',
        year TEXT,
        last_chapter TEXT,
        source TEXT NOT NULL DEFAULT 'mangadex',
        in_library INTEGER NOT NULL DEFAULT 1,
        added_at INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS chapters (
        manga_id TEXT NOT NULL,
        chapter_id TEXT NOT NULL,
        number TEXT,
        volume TEXT,
        title TEXT NOT NULL DEFAULT '',
        pages INTEGER NOT NULL DEFAULT 0,
        grp TEXT NOT NULL DEFAULT '',
        publish_at TEXT,
        source TEXT NOT NULL DEFAULT 'mangadex',
        ord INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (manga_id, chapter_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_chapters_manga_ord ON chapters (manga_id, ord)',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS categories (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        ord INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS manga_categories (
        manga_id TEXT NOT NULL,
        category_id TEXT NOT NULL,
        PRIMARY KEY (manga_id, category_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_mc_cat ON manga_categories (category_id)',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS reading_progress (
        manga_id TEXT PRIMARY KEY,
        chapter_id TEXT NOT NULL,
        manga_title TEXT NOT NULL DEFAULT '',
        cover TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT '',
        chapter_number TEXT,
        chapter_title TEXT NOT NULL DEFAULT '',
        page INTEGER NOT NULL DEFAULT 1,
        total_pages INTEGER NOT NULL DEFAULT 0,
        completed INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_prog_updated ON reading_progress (updated_at DESC)',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS read_chapters (
        manga_id TEXT NOT NULL,
        chapter_id TEXT NOT NULL,
        PRIMARY KEY (manga_id, chapter_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS chapter_bookmarks (
        chapter_id TEXT PRIMARY KEY
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS reading_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        manga_id TEXT NOT NULL,
        chapter_id TEXT NOT NULL,
        started_at TEXT NOT NULL,
        duration_seconds INTEGER NOT NULL DEFAULT 0,
        pages_read INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sessions_started ON reading_sessions (started_at DESC)',
    );
  }

  // ---- Library & Chapters ----

  Future<void> upsertManga(MangaItem m, {bool inLibrary = true}) async {
    final db = _db;
    if (db == null || !db.isOpen) return;
    await db.rawInsert(
      '''
      INSERT INTO manga (
        id, title, description, cover, authors_json, status, type,
        tags_json, year, last_chapter, source, in_library, added_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        title = excluded.title,
        description = excluded.description,
        cover = excluded.cover,
        authors_json = excluded.authors_json,
        status = excluded.status,
        type = excluded.type,
        tags_json = excluded.tags_json,
        year = excluded.year,
        last_chapter = excluded.last_chapter,
        source = excluded.source,
        in_library = excluded.in_library
      ''',
      [
        m.id,
        m.title,
        m.description,
        m.cover,
        jsonEncode(m.authors),
        m.status,
        m.type,
        jsonEncode(m.tags),
        m.year,
        m.lastChapter,
        m.source,
        inLibrary ? 1 : 0,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> upsertMangas(
    Iterable<MangaItem> items, {
    bool inLibrary = true,
  }) async {
    final db = _db;
    if (db == null || !db.isOpen) return;
    final list = items.where((m) => m.id.isNotEmpty).toList();
    if (list.isEmpty) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final m in list) {
        batch.rawInsert(
          '''
          INSERT INTO manga (
            id, title, description, cover, authors_json, status, type,
            tags_json, year, last_chapter, source, in_library, added_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            description = excluded.description,
            cover = excluded.cover,
            authors_json = excluded.authors_json,
            status = excluded.status,
            type = excluded.type,
            tags_json = excluded.tags_json,
            year = excluded.year,
            last_chapter = excluded.last_chapter,
            source = excluded.source,
            in_library = excluded.in_library
          ''',
          [
            m.id,
            m.title,
            m.description,
            m.cover,
            jsonEncode(m.authors),
            m.status,
            m.type,
            jsonEncode(m.tags),
            m.year,
            m.lastChapter,
            m.source,
            inLibrary ? 1 : 0,
            nowMs,
          ],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> deleteLibraryManga(String mangaId) async {
    final db = _db;
    if (db == null || !db.isOpen) return;
    await db.delete('manga', where: 'id = ?', whereArgs: [mangaId]);
    await db.delete('manga_categories', where: 'manga_id = ?', whereArgs: [mangaId]);
  }

  Future<List<MangaItem>> loadLibraryManga() async {
    final db = _db;
    if (db == null || !db.isOpen) return const [];
    final rows = await db.query('manga', where: 'in_library = 1', orderBy: 'added_at DESC');
    return rows.map(_mangaFromRow).toList();
  }

  static MangaItem _mangaFromRow(Map<String, Object?> r) {
    List<String> decodeStrList(Object? raw) {
      if (raw is! String || raw.isEmpty) return const [];
      try {
        return (jsonDecode(raw) as List<dynamic>).map((e) => e.toString()).toList();
      } catch (_) {
        return const [];
      }
    }

    return MangaItem(
      id: r['id']?.toString() ?? '',
      title: r['title']?.toString() ?? 'Untitled',
      description: r['description']?.toString() ?? '',
      cover: r['cover']?.toString() ?? '',
      authors: decodeStrList(r['authors_json']),
      status: r['status']?.toString() ?? '',
      type: r['type']?.toString() ?? 'manga',
      tags: decodeStrList(r['tags_json']),
      year: r['year']?.toString(),
      lastChapter: r['last_chapter']?.toString(),
      source: r['source']?.toString() ?? 'mangadex',
    );
  }

  /// Replaces cached chapters for a single manga inside a fast SQLite transaction
  /// (O(chapters_for_manga) instead of re-encoding all 300 mangas to SharedPreferences!).
  Future<void> replaceChaptersForManga(
    String mangaId,
    List<ChapterItem> chapters,
  ) async {
    final db = _db;
    if (db == null || !db.isOpen || mangaId.isEmpty) return;
    await db.transaction((txn) async {
      await txn.delete('chapters', where: 'manga_id = ?', whereArgs: [mangaId]);
      final batch = txn.batch();
      for (var i = 0; i < chapters.length; i++) {
        final c = chapters[i];
        batch.insert(
          'chapters',
          {
            'manga_id': mangaId,
            'chapter_id': c.id,
            'number': c.number,
            'volume': c.volume,
            'title': c.title,
            'pages': c.pages,
            'grp': c.group,
            'publish_at': c.publishAt,
            'source': c.source,
            'ord': i,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<ChapterItem>> loadChaptersForManga(String mangaId) async {
    final db = _db;
    if (db == null || !db.isOpen || mangaId.isEmpty) return const [];
    final rows = await db.query(
      'chapters',
      where: 'manga_id = ?',
      whereArgs: [mangaId],
      orderBy: 'ord ASC',
    );
    return rows
        .map(
          (r) => ChapterItem(
            id: r['chapter_id']?.toString() ?? '',
            number: r['number']?.toString(),
            volume: r['volume']?.toString(),
            title: r['title']?.toString() ?? '',
            pages: (r['pages'] as num?)?.toInt() ?? 0,
            group: r['grp']?.toString() ?? '',
            publishAt: r['publish_at']?.toString(),
            source: r['source']?.toString() ?? 'mangadex',
          ),
        )
        .toList();
  }

  Future<Map<String, List<ChapterItem>>> loadAllCachedChapters({int maxMangas = 300}) async {
    final db = _db;
    if (db == null || !db.isOpen) return const {};
    final rows = await db.query('chapters', orderBy: 'manga_id ASC, ord ASC');
    final map = <String, List<ChapterItem>>{};
    for (final r in rows) {
      final mid = r['manga_id']?.toString() ?? '';
      if (mid.isEmpty) continue;
      if (!map.containsKey(mid) && map.length >= maxMangas) continue;
      (map[mid] ??= <ChapterItem>[]).add(
        ChapterItem(
          id: r['chapter_id']?.toString() ?? '',
          number: r['number']?.toString(),
          volume: r['volume']?.toString(),
          title: r['title']?.toString() ?? '',
          pages: (r['pages'] as num?)?.toInt() ?? 0,
          group: r['grp']?.toString() ?? '',
          publishAt: r['publish_at']?.toString(),
          source: r['source']?.toString() ?? 'mangadex',
        ),
      );
    }
    return map;
  }

  // ---- Categories ----

  Future<void> replaceCategories(List<CategoryItem> categories) async {
    final db = _db;
    if (db == null || !db.isOpen) return;
    await db.transaction((txn) async {
      await txn.delete('categories');
      final batch = txn.batch();
      for (final c in categories) {
        batch.insert('categories', {'id': c.id, 'name': c.name, 'ord': c.order});
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> setMangaCategories(String mangaId, List<String> categoryIds) async {
    final db = _db;
    if (db == null || !db.isOpen) return;
    await db.transaction((txn) async {
      await txn.delete('manga_categories', where: 'manga_id = ?', whereArgs: [mangaId]);
      final batch = txn.batch();
      for (final cid in categoryIds) {
        batch.insert(
          'manga_categories',
          {'manga_id': mangaId, 'category_id': cid},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  // ---- Reading Progress & Sessions (Stats) ----

  Future<void> upsertProgress(ReadProgress p) async {
    final db = _db;
    if (db == null || !db.isOpen) return;
    await db.insert(
      'reading_progress',
      {
        'manga_id': p.mangaId,
        'chapter_id': p.chapterId,
        'manga_title': p.mangaTitle,
        'cover': p.cover,
        'source': p.source,
        'chapter_number': p.chapterNumber,
        'chapter_title': p.chapterTitle,
        'page': p.page,
        'total_pages': p.totalPages,
        'completed': p.completed ? 1 : 0,
        'updated_at': (p.updatedAt ?? DateTime.now()).toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertProgressBatch(Iterable<ReadProgress> items) async {
    final db = _db;
    if (db == null || !db.isOpen) return;
    final list = items.where((p) => p.mangaId.isNotEmpty && p.chapterId.isNotEmpty).toList();
    if (list.isEmpty) return;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final p in list) {
        batch.insert(
          'reading_progress',
          {
            'manga_id': p.mangaId,
            'chapter_id': p.chapterId,
            'manga_title': p.mangaTitle,
            'cover': p.cover,
            'source': p.source,
            'chapter_number': p.chapterNumber,
            'chapter_title': p.chapterTitle,
            'page': p.page,
            'total_pages': p.totalPages,
            'completed': p.completed ? 1 : 0,
            'updated_at': (p.updatedAt ?? DateTime.now()).toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<Map<String, ReadProgress>> loadAllProgress() async {
    final db = _db;
    if (db == null || !db.isOpen) return const {};
    final rows = await db.query('reading_progress', orderBy: 'updated_at DESC');
    final map = <String, ReadProgress>{};
    for (final r in rows) {
      final mid = r['manga_id']?.toString() ?? '';
      final cid = r['chapter_id']?.toString() ?? '';
      if (mid.isEmpty || cid.isEmpty) continue;
      map[mid] = ReadProgress(
        mangaId: mid,
        chapterId: cid,
        mangaTitle: r['manga_title']?.toString() ?? '',
        cover: r['cover']?.toString() ?? '',
        source: r['source']?.toString() ?? '',
        chapterNumber: r['chapter_number']?.toString() ?? '',
        chapterTitle: r['chapter_title']?.toString() ?? '',
        page: (r['page'] as num?)?.toInt() ?? 1,
        totalPages: (r['total_pages'] as num?)?.toInt() ?? 0,
        completed: ((r['completed'] as num?)?.toInt() ?? 0) != 0,
        updatedAt: DateTime.tryParse(r['updated_at']?.toString() ?? ''),
      );
    }
    return map;
  }

  Future<void> deleteProgressByChapter(String chapterId) async {
    final db = _db;
    if (db == null || !db.isOpen || chapterId.isEmpty) return;
    await db.delete(
      'reading_progress',
      where: 'chapter_id = ?',
      whereArgs: [chapterId],
    );
  }

  Future<Map<String, Set<String>>> loadAllReadChapters() async {
    final db = _db;
    if (db == null || !db.isOpen) return const {};
    final rows = await db.query('read_chapters');
    final map = <String, Set<String>>{};
    for (final r in rows) {
      final mid = r['manga_id']?.toString() ?? '';
      final cid = r['chapter_id']?.toString() ?? '';
      if (mid.isEmpty || cid.isEmpty) continue;
      (map[mid] ??= <String>{}).add(cid);
    }
    return map;
  }

  Future<void> mergeReadChaptersBatch(Map<String, Set<String>> readChapters) async {
    final db = _db;
    if (db == null || !db.isOpen || readChapters.isEmpty) return;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in readChapters.entries) {
        if (entry.key.isEmpty || entry.value.isEmpty) continue;
        for (final cid in entry.value) {
          if (cid.isEmpty) continue;
          batch.insert(
            'read_chapters',
            {'manga_id': entry.key, 'chapter_id': cid},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> setChaptersRead(String mangaId, List<String> chapterIds, bool read) async {
    final db = _db;
    if (db == null || !db.isOpen || chapterIds.isEmpty) return;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final cid in chapterIds) {
        if (read) {
          batch.insert(
            'read_chapters',
            {'manga_id': mangaId, 'chapter_id': cid},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        } else {
          batch.delete(
            'read_chapters',
            where: 'manga_id = ? AND chapter_id = ?',
            whereArgs: [mangaId, cid],
          );
        }
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> recordReadingSession({
    required String mangaId,
    required String chapterId,
    required int durationSeconds,
    required int pagesRead,
    DateTime? startedAt,
  }) async {
    final db = _db;
    if (db == null || !db.isOpen) return;
    if (durationSeconds <= 0 && pagesRead <= 0) return;
    await db.insert('reading_sessions', {
      'manga_id': mangaId,
      'chapter_id': chapterId,
      'started_at': (startedAt ?? DateTime.now()).toUtc().toIso8601String(),
      'duration_seconds': durationSeconds.clamp(0, 86400),
      'pages_read': pagesRead.clamp(0, 5000),
    });
  }

  Future<({int totalSeconds, int totalPages, int streakDays})> loadReadingSessionStats() async {
    final db = _db;
    if (db == null || !db.isOpen) {
      return (totalSeconds: 0, totalPages: 0, streakDays: 0);
    }
    final agg = await db.rawQuery(
      'SELECT COALESCE(SUM(duration_seconds), 0) AS s, COALESCE(SUM(pages_read), 0) AS p FROM reading_sessions',
    );
    final totalSec = (agg.first['s'] as num?)?.toInt() ?? 0;
    final totalPages = (agg.first['p'] as num?)?.toInt() ?? 0;

    final dayRows = await db.rawQuery(
      'SELECT DISTINCT substr(started_at, 1, 10) AS day FROM reading_sessions ORDER BY day DESC LIMIT 365',
    );
    var streak = 0;
    if (dayRows.isNotEmpty) {
      var expected = DateTime.now().toUtc();
      var expectedStr = expected.toIso8601String().substring(0, 10);
      final days = dayRows.map((r) => r['day']?.toString() ?? '').where((d) => d.isNotEmpty).toSet();
      if (!days.contains(expectedStr)) {
        // Allow streak to continue if user read yesterday
        expected = expected.subtract(const Duration(days: 1));
        expectedStr = expected.toIso8601String().substring(0, 10);
      }
      while (days.contains(expectedStr)) {
        streak++;
        expected = expected.subtract(const Duration(days: 1));
        expectedStr = expected.toIso8601String().substring(0, 10);
      }
    }
    return (totalSeconds: totalSec, totalPages: totalPages, streakDays: streak);
  }

  Future<void> clearLibraryTables() async {
    final db = _db;
    if (db == null || !db.isOpen) return;
    await db.transaction((txn) async {
      await txn.delete('manga');
      await txn.delete('chapters');
      await txn.delete('categories');
      await txn.delete('manga_categories');
    });
  }

  Future<void> clearHistoryTables({bool includeReadChapters = true}) async {
    final db = _db;
    if (db == null || !db.isOpen) return;
    await db.transaction((txn) async {
      await txn.delete('reading_progress');
      if (includeReadChapters) {
        await txn.delete('read_chapters');
        await txn.delete('chapter_bookmarks');
      }
    });
  }

  Future<void> clearAll() async {
    final db = _db;
    if (db == null || !db.isOpen) return;
    await db.transaction((txn) async {
      await txn.delete('manga');
      await txn.delete('chapters');
      await txn.delete('categories');
      await txn.delete('manga_categories');
      await txn.delete('reading_progress');
      await txn.delete('read_chapters');
      await txn.delete('chapter_bookmarks');
    });
  }
}
