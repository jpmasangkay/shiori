import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/download_service.dart';
import 'package:manga_reader/services/extension_bridge.dart';
import 'package:manga_reader/services/extension_service.dart';
import 'package:manga_reader/services/scrapers/asura_scraper.dart';
import 'package:manga_reader/services/scrapers/flame_scraper.dart';
import 'package:manga_reader/services/scrapers/mangadex_service.dart';
import 'package:manga_reader/services/scrapers/mangakatana_scraper.dart';
import 'package:manga_reader/services/scrapers/mangapill_scraper.dart';
import 'package:manga_reader/services/scrapers/mangaread_scraper.dart';
import 'package:manga_reader/services/scrapers/web_extension_scraper.dart';
import 'package:manga_reader/services/scrapers/weeb_scraper.dart';

/// Central catalog service routing queries across direct web scrapers, MangaDex API,
/// and community extensions (#1)
class MangaCatalogService {
  final MangaDexService mangadex;
  final AsuraScraper asura;
  final FlameScraper flame;
  final WeebScraper weeb;
  final MangaPillScraper mangapill;
  final MangaKatanaScraper mangakatana;
  final MangaReadScraper mangaread;
  final WebExtensionScraper webExtension;
  final http.Client Function() _clientProvider;
  final String Function() _baseUrlProvider;

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  MangaCatalogService({
    required this.mangadex,
    required this.asura,
    required this.flame,
    required this.weeb,
    required this.mangapill,
    required this.mangakatana,
    required this.mangaread,
    required this.webExtension,
    required this._clientProvider,
    required this._baseUrlProvider,
  });

  http.Client get _client => _clientProvider();
  String get _baseUrl => _baseUrlProvider();

  Future<List<MangaItem>> searchManga({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
    String source = 'mangadex',
  }) async {
    final s = source.toLowerCase().trim();

    // 1. Built-in direct web scrapers
    if (s == 'flamecomics' || s == 'flame') {
      return flame.search(query: query, type: type, order: order, page: page, limit: limit);
    }
    if (s == 'weebcentral' || s == 'weeb') {
      return weeb.search(query: query, type: type, order: order, page: page, limit: limit);
    }
    if (s == 'mangapill' || s == 'pill') {
      return mangapill.search(query: query, type: type, page: page, limit: limit);
    }
    if (s == 'mangakatana' || s == 'katana') {
      return mangakatana.search(query: query, type: type, order: order, page: page, limit: limit);
    }
    if (s == 'mangaread' || s == 'mread') {
      return mangaread.search(query: query, type: type, order: order, page: page, limit: limit);
    }
    if (s == 'asura') {
      return asura.search(query: query, type: type, page: page);
    }

    // 2. MangaDex API
    if (s == 'mangadex') {
      return mangadex.searchCatalog(
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
          final webResults = await webExtension.search(
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

    if (ext != null && ext.homeUrl.isNotEmpty) {
      return webExtension.search(
        ext,
        sourcePkg: effectivePkg,
        query: query,
        order: order,
        page: page,
        limit: limit,
      );
    }

    return [];
  }

  Future<MangaItem> getManga(String id) async {
    if (id.startsWith('asura:')) return asura.getManga(id);
    if (id.startsWith('flame:')) return flame.getManga(id);
    if (id.startsWith('weeb:')) return weeb.getManga(id);
    if (id.startsWith('pill:')) return mangapill.getManga(id);
    if (id.startsWith('katana:')) return mangakatana.getManga(id);
    if (id.startsWith('mread:')) return mangaread.getManga(id);

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
          return webExtension.getManga(pkg, actualId, ext: ext);
        }
        rethrow;
      }
    }

    if (id.startsWith('mangadex:')) {
      return mangadex.getManga(id.substring('mangadex:'.length));
    }
    if (_uuidPattern.hasMatch(id)) {
      return mangadex.getManga(id);
    }

    throw Exception('Unknown or unsupported manga source for ID: $id');
  }

  Future<List<ChapterItem>> getChapters(
    String mangaId, {
    String lang = 'en',
    void Function(String mangaId, int count)? onChapterCount,
  }) async {
    final chapters = await _getChaptersInternal(mangaId, lang: lang);
    if (chapters.isNotEmpty && onChapterCount != null) {
      onChapterCount(mangaId, chapters.length);
    }
    return chapters;
  }

  Future<List<ChapterItem>> _getChaptersInternal(String mangaId, {String lang = 'en'}) async {
    if (mangaId.startsWith('asura:')) return asura.getChapters(mangaId);
    if (mangaId.startsWith('flame:')) return flame.getChapters(mangaId);
    if (mangaId.startsWith('weeb:')) return weeb.getChapters(mangaId);
    if (mangaId.startsWith('pill:')) return mangapill.getChapters(mangaId);
    if (mangaId.startsWith('katana:')) return mangakatana.getChapters(mangaId);
    if (mangaId.startsWith('mread:')) return mangaread.getChapters(mangaId);

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
            final webChapters = await webExtension.getChapters(pkg, actualId, ext: ext);
            if (webChapters.isNotEmpty) return webChapters;
          } catch (_) {}
        }
        rethrow;
      }

      final ext = ExtensionService.instance.getExtensionByPkg(pkg);
      if (ext != null && ext.homeUrl.isNotEmpty) {
        return webExtension.getChapters(pkg, actualId, ext: ext);
      }

      return [];
    }

    if (mangaId.startsWith('mangadex:')) {
      return mangadex.getChapters(mangaId.substring('mangadex:'.length), lang: lang);
    }
    if (_uuidPattern.hasMatch(mangaId)) {
      return mangadex.getChapters(mangaId, lang: lang);
    }

    return [];
  }

  Future<ChapterPages> getChapterPages(String chapterId, {bool forceRefresh = false}) async {
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

    if (chapterId.startsWith('asura:')) return asura.getChapterPages(chapterId);
    if (chapterId.startsWith('flame:')) return flame.getChapterPages(chapterId);
    if (chapterId.startsWith('weeb:')) return weeb.getChapterPages(chapterId);
    if (chapterId.startsWith('pill:')) return mangapill.getChapterPages(chapterId);
    if (chapterId.startsWith('katana:')) return mangakatana.getChapterPages(chapterId);
    if (chapterId.startsWith('mread:')) return mangaread.getChapterPages(chapterId);

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
          return webExtension.getChapterPages(pkg, actualChapterId, ext: ext);
        }
        rethrow;
      }

      final ext = ExtensionService.instance.getExtensionByPkg(pkg);
      if (ext != null && ext.homeUrl.isNotEmpty) {
        return webExtension.getChapterPages(pkg, actualChapterId, ext: ext);
      }

      throw Exception('Chapter reader not available for $pkg');
    }

    if (chapterId.startsWith('mangadex:')) {
      return mangadex.getChapterPages(chapterId.substring('mangadex:'.length));
    }
    if (_uuidPattern.hasMatch(chapterId)) {
      return mangadex.getChapterPages(chapterId);
    }

    throw Exception('Unknown or unsupported chapter source for ID: $chapterId');
  }

  Future<Map<String, dynamic>> getUpdates({
    required List<MangaItem> bookmarked,
    Map<String, String>? authHeaders,
  }) async {
    final bookmarkedIds = bookmarked.map((m) => m.id).toSet();
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

    // Try backend proxy first if headers provided
    if (authHeaders != null) {
      try {
        final res = await _client
            .get(Uri.parse('$_baseUrl/updates'), headers: authHeaders)
            .timeout(const Duration(seconds: 4));
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
    }

    // Direct multi-source fetch for top bookmarked titles
    final List<Map<String, dynamic>> allChapters = [];
    final now = DateTime.now();
    final todayStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final yesterday = now.subtract(const Duration(days: 1));
    final yesterdayStr =
        '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';

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
                          (manga.source == 'asura'
                              ? 'Asura Scans'
                              : manga.source == 'flamecomics'
                                  ? 'Flame Comics'
                                  : manga.source == 'weebcentral'
                                      ? 'Weeb Central'
                                      : manga.source == 'mangapill'
                                          ? 'MangaPill'
                                          : manga.source == 'mangakatana'
                                              ? 'MangaKatana'
                                              : manga.source == 'mangaread'
                                                  ? 'MangaRead'
                                                  : manga.source == 'mangadex'
                                                      ? 'MangaDex'
                                                      : manga.source))
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
}
