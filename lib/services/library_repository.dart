import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/app_logger.dart';
import 'package:manga_reader/services/source_resolver.dart';

/// Repository managing local bookmarks, custom categories, and cloud library synchronization
/// (#1, #3, #4, #11, #32, #35, #38)
class LibraryRepository extends ChangeNotifier {
  final Map<String, MangaItem> _localLibrary = {};
  final Map<String, MangaItem> _knownManga = {};
  final List<CategoryItem> _userCategories = [];
  final Map<String, List<String>> _mangaCategories = {};

  SharedPreferences? _cachedPrefs;

  Map<String, MangaItem> get localLibrary => Map.unmodifiable(_localLibrary);
  Map<String, MangaItem> get knownManga => Map.unmodifiable(_knownManga);
  List<CategoryItem> get userCategories => List.unmodifiable(_userCategories);
  Map<String, List<String>> get mangaCategories => Map.unmodifiable(_mangaCategories);

  bool isInLibrary(String mangaId) => _localLibrary.containsKey(mangaId);

  void cacheKnownManga(MangaItem manga) {
    if (manga.id.isNotEmpty) {
      _knownManga[manga.id] = manga;
    }
  }

  Future<void> init(SharedPreferences prefs) async {
    _cachedPrefs = prefs;
    _localLibrary.clear();
    _userCategories.clear();
    _mangaCategories.clear();

    // 1. Local Library
    final localLibJson = prefs.getString('shiori_local_library');
    if (localLibJson != null && localLibJson.isNotEmpty) {
      try {
        final list = jsonDecode(localLibJson) as List<dynamic>;
        for (final item in list) {
          if (item is Map) {
            final m = MangaItem.fromJson(Map<String, dynamic>.from(item));
            if (m.id.isNotEmpty) {
              _localLibrary[m.id] = m;
              _knownManga[m.id] = m;
            }
          }
        }
      } catch (e) {
        AppLogger.warn('Failed to parse shiori_local_library', e);
      }
    }

    // 2. User Categories
    final catsJson = prefs.getString('shiori_user_categories');
    if (catsJson != null && catsJson.isNotEmpty) {
      try {
        final list = jsonDecode(catsJson) as List<dynamic>;
        _userCategories.clear();
        for (final item in list) {
          if (item is Map) {
            _userCategories.add(CategoryItem.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      } catch (e) {
        AppLogger.warn('Failed to parse shiori_user_categories', e);
      }
    }
    if (_userCategories.isEmpty) {
      _userCategories.addAll(const [
        CategoryItem(id: 'reading', name: 'Reading', order: 0),
        CategoryItem(id: 'completed', name: 'Completed', order: 1),
        CategoryItem(id: 'plan_to_read', name: 'Plan to Read', order: 2),
        CategoryItem(id: 'favorites', name: 'Favorites', order: 3),
      ]);
    }

    // 3. Manga Category Assignments
    final mangaCatsJson = prefs.getString('shiori_manga_categories');
    if (mangaCatsJson != null && mangaCatsJson.isNotEmpty) {
      try {
        final Map<String, dynamic> map = jsonDecode(mangaCatsJson);
        map.forEach((k, v) {
          if (v is List) {
            _mangaCategories[k] = v.map((e) => e.toString()).toList();
          }
        });
      } catch (e) {
        AppLogger.warn('Failed to parse shiori_manga_categories', e);
      }
    }
  }

  Future<void> _persistLocalLibrary() async {
    try {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      final list = _localLibrary.values.map((e) => e.toJson()).toList();
      await prefs.setString('shiori_local_library', jsonEncode(list));
    } catch (e) {
      AppLogger.warn('Failed to persist local library', e);
    }
  }

  Future<void> _persistUserCategories() async {
    try {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      final list = _userCategories.map((e) => e.toJson()).toList();
      await prefs.setString('shiori_user_categories', jsonEncode(list));
    } catch (e) {
      AppLogger.warn('Failed to persist user categories', e);
    }
  }

  Future<void> _persistMangaCategories() async {
    try {
      final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
      await prefs.setString('shiori_manga_categories', jsonEncode(_mangaCategories));
    } catch (e) {
      AppLogger.warn('Failed to persist manga categories', e);
    }
  }

  List<MangaItem> getLibraryItems({String? type}) {
    var items = _localLibrary.values.toList();
    if (type != null && type.isNotEmpty && type != 'all') {
      items = items.where((m) => m.type == type).toList();
    }
    return items;
  }

  Future<void> addToLibrary(
    MangaItem manga, {
    http.Client? client,
    String? baseUrl,
    Map<String, String>? headers,
  }) async {
    final existing = _localLibrary[manga.id];
    final effective = (existing != null && manga.cover.isEmpty && existing.cover.isNotEmpty)
        ? manga.copyWith(cover: existing.cover)
        : manga;

    _localLibrary[manga.id] = effective;
    _knownManga[manga.id] = effective;
    await _persistLocalLibrary();
    notifyListeners();

    if (client != null && baseUrl != null && headers != null) {
      try {
        final cats = _mangaCategories[effective.id];
        await client
            .post(
              Uri.parse('$baseUrl/library'),
              headers: headers,
              body: jsonEncode({
                'mangaId': effective.id,
                'title': effective.title,
                'cover': effective.cover,
                'type': effective.type,
                'status': effective.status,
                'source': effective.source,
                'latestChapter': effective.lastChapter ?? '',
                if (cats != null && cats.isNotEmpty) 'categories': cats,
              }),
            )
            .timeout(const Duration(seconds: 8));
      } catch (e) {
        AppLogger.warn('Cloud addToLibrary failed for ${effective.id}', e);
      }
    }
  }

  Future<void> removeFromLibrary(
    String mangaId, {
    http.Client? client,
    String? baseUrl,
    Map<String, String>? headers,
  }) async {
    _localLibrary.remove(mangaId);
    await _persistLocalLibrary();
    notifyListeners();

    if (client != null && baseUrl != null && headers != null) {
      try {
        await client
            .delete(Uri.parse('$baseUrl/library/$mangaId'), headers: headers)
            .timeout(const Duration(seconds: 8));
      } catch (e) {
        AppLogger.warn('Cloud removeFromLibrary failed for $mangaId', e);
      }
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
    if (changed) notifyListeners();
  }

  // ---- Custom Categories Management (#35) ----

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

  Future<void> ensureInLibraryWhenCategorizing(String mangaId, {MangaItem? manga}) async {
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
          source: SourceResolver.resolve(mangaId),
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
      await ensureInLibraryWhenCategorizing(mangaId, manga: manga);
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
      list.remove(categoryId);
    } else {
      await ensureInLibraryWhenCategorizing(mangaId, manga: manga);
      if (!list.contains(categoryId)) {
        list.add(categoryId);
      }
    }
    await _persistMangaCategories();
    notifyListeners();
  }

  // ---- Fast Parallel Batch Cloud Sync (#11, #32, #35) ----

  Future<void> uploadLibraryBookmarks(
    http.Client client,
    String baseUrl,
    Map<String, String> headers,
  ) async {
    final items = _localLibrary.values.toList();
    if (items.isEmpty) return;

    // Try batch endpoint first (/api/library/batch) (#11, #32)
    try {
      final batchPayload = {
        'items': items
            .map((m) => {
                  'mangaId': m.id,
                  'title': m.title,
                  'cover': m.cover,
                  'type': m.type,
                  'status': m.status,
                  'source': m.source,
                  'latestChapter': m.lastChapter ?? '',
                  'categories': _mangaCategories[m.id] ?? <String>[],
                })
            .toList(),
      };
      final batchRes = await client
          .post(
            Uri.parse('$baseUrl/library/batch'),
            headers: headers,
            body: jsonEncode(batchPayload),
          )
          .timeout(const Duration(seconds: 10));

      if (batchRes.statusCode == 200 || batchRes.statusCode == 201) {
        return;
      }
    } catch (_) {
      // Fallback to chunked parallel uploads with concurrency limiter
    }

    // Fallback: chunk into parallel batches of 6 concurrent requests
    const chunkSize = 6;
    for (var i = 0; i < items.length; i += chunkSize) {
      final chunk = items.sublist(i, (i + chunkSize > items.length) ? items.length : i + chunkSize);
      await Future.wait(chunk.map((manga) async {
        try {
          await client
              .post(
                Uri.parse('$baseUrl/library'),
                headers: headers,
                body: jsonEncode({
                  'mangaId': manga.id,
                  'title': manga.title,
                  'cover': manga.cover,
                  'type': manga.type,
                  'status': manga.status,
                  'source': manga.source,
                  'latestChapter': manga.lastChapter ?? '',
                  'categories': _mangaCategories[manga.id] ?? <String>[],
                }),
              )
              .timeout(const Duration(seconds: 4));
        } catch (_) {}
      }));
    }
  }

  Future<void> syncCategoriesWithCloud(
    http.Client client,
    String baseUrl,
    Map<String, String> headers,
  ) async {
    try {
      // 1. Upload local custom categories and manga mappings (#35)
      await client
          .put(
            Uri.parse('$baseUrl/library/categories'),
            headers: headers,
            body: jsonEncode({
              'categories': _userCategories.map((c) => c.toJson()).toList(),
              'mangaCategories': _mangaCategories,
            }),
          )
          .timeout(const Duration(seconds: 6));

      // 2. Download and merge cloud categories
      final res = await client
          .get(Uri.parse('$baseUrl/library/categories'), headers: headers)
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final cloudCats = data['categories'] as List<dynamic>?;
        if (cloudCats != null) {
          final existingIds = _userCategories.map((c) => c.id).toSet();
          for (final c in cloudCats) {
            if (c is Map) {
              final item = CategoryItem.fromJson(Map<String, dynamic>.from(c));
              if (!existingIds.contains(item.id)) {
                _userCategories.add(item);
                existingIds.add(item.id);
              }
            }
          }
          await _persistUserCategories();
        }

        final cloudMangaCats = data['mangaCategories'] as Map<String, dynamic>?;
        if (cloudMangaCats != null) {
          cloudMangaCats.forEach((mangaId, cats) {
            if (cats is List) {
              final catList = cats.map((e) => e.toString()).toList();
              final current = _mangaCategories[mangaId];
              if (current == null || current.isEmpty) {
                _mangaCategories[mangaId] = catList;
              }
            }
          });
          await _persistMangaCategories();
        }
      }
    } catch (e) {
      AppLogger.warn('syncCategoriesWithCloud failed', e);
    }
  }

  Future<void> downloadLibraryBookmarks(
    http.Client client,
    String baseUrl,
    Map<String, String> headers,
  ) async {
    try {
      final res = await client
          .get(Uri.parse('$baseUrl/library'), headers: headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['items'] as List<dynamic>?) ?? [];
        for (final e in list) {
          final id = e['mangaId']?.toString() ?? e['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          final source = SourceResolver.resolve(id, e['source']?.toString());
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

          if (e['categories'] is List) {
            final cats = (e['categories'] as List).map((c) => c.toString()).toList();
            if (cats.isNotEmpty) {
              _mangaCategories[m.id] = cats;
            }
          }
        }
        await _persistLocalLibrary();
        await _persistMangaCategories();
      }
    } catch (e) {
      AppLogger.warn('downloadLibraryBookmarks failed', e);
    }
  }

  /// Wipes all local library bookmarks and custom categories from this device (#38)
  Future<void> clearLocalData() async {
    _localLibrary.clear();
    _userCategories.clear();
    _mangaCategories.clear();
    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.remove('shiori_local_library');
    await prefs.remove('shiori_user_categories');
    await prefs.remove('shiori_manga_categories');
    notifyListeners();
  }
}
