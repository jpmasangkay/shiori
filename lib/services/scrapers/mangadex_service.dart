import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/scrapers/html_scraper_utils.dart';
import 'package:manga_reader/widgets/common.dart';

class MangaDexService {
  final http.Client Function() _clientProvider;
  final LruHttpCache? _cache;
  final String Function()? _baseUrlProvider;

  MangaDexService({
    required this._clientProvider,
    this._cache,
    this._baseUrlProvider,
  });

  http.Client get _client => _clientProvider();
  String get _baseUrl =>
      _baseUrlProvider?.call() ?? 'https://shiori-n5hd.onrender.com/api';

  Future<http.Response> _getCached(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final key = uri.toString();
    if (_cache != null) {
      return _cache.deduplicate(key, () async {
        return await _client.get(uri, headers: headers).timeout(timeout);
      });
    }
    return await _client.get(uri, headers: headers).timeout(timeout);
  }

  Future<List<MangaItem>> searchCatalog({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
    String? lang,
  }) async {
    // 1. Direct MangaDex API first
    try {
      final qParams = <String, dynamic>{
        'limit': limit.clamp(1, 50).toString(),
        'offset': ((page - 1) * limit).toString(),
        'includes[]': ['cover_art', 'author', 'artist'],
        'contentRating[]': ['safe', 'suggestive', 'erotica'],
        'hasAvailableChapters': 'true',
      };
      if (query != null && query.trim().isNotEmpty) {
        qParams['title'] = query.trim();
        qParams['order[relevance]'] = 'desc';
      } else if (order == 'popular') {
        qParams['order[followedCount]'] = 'desc';
      } else if (order == 'latest') {
        qParams['order[latestUploadedChapter]'] = 'desc';
      } else if (order == 'rating') {
        qParams['order[rating]'] = 'desc';
      } else {
        qParams['order[createdAt]'] = 'desc';
      }

      if (type == 'manhwa') {
        qParams['originalLanguage[]'] = ['ko'];
      } else if (type == 'manhua') {
        qParams['originalLanguage[]'] = ['zh', 'zh-hk'];
      } else if (type == 'manga') {
        qParams['originalLanguage[]'] = ['ja'];
      }

      if (lang != null && lang.isNotEmpty && lang.toLowerCase() != 'all') {
        qParams['availableTranslatedLanguage[]'] = [lang.toLowerCase()];
      } else {
        qParams['availableTranslatedLanguage[]'] = ['en'];
      }

      final uri = Uri.https('api.mangadex.org', '/manga', qParams);
      final res = await _getCached(
        uri,
        headers: const {
          'User-Agent': 'ShioriApp/1.0',
          'Accept': 'application/json',
        },
        timeout: const Duration(seconds: 8),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['data'] as List<dynamic>?) ?? [];
        return list
            .map((m) => normalizeDirectManga(m as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('_searchMangaCatalog direct error: $e');
    }

    // 2. Fallback to Backend proxy if direct API is unreachable
    try {
      final qParams = <String, String>{
        if (query != null && query.isNotEmpty) 'q': query,
        if (type != null && type.isNotEmpty && type != 'all') 'type': type,
        'order': order,
        'page': page.toString(),
        'limit': limit.toString(),
        if (lang != null && lang.isNotEmpty && lang.toLowerCase() != 'all')
          'lang': lang.toLowerCase(),
      };
      final uri = Uri.parse(
        '$_baseUrl/manga/search',
      ).replace(queryParameters: qParams);
      final res = await _client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['items'] as List<dynamic>?) ?? [];
        if (list.isNotEmpty) {
          return list
              .map((e) => MangaItem.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      }
    } catch (_) {}

    return [];
  }

  Future<MangaItem> getManga(String actualId) async {
    // 1. Direct MangaDex API first
    try {
      final uri = Uri.https('api.mangadex.org', '/manga/$actualId', {
        'includes[]': ['cover_art', 'author', 'artist'],
      });
      final res = await _getCached(
        uri,
        headers: const {
          'User-Agent': 'ShioriApp/1.0',
          'Accept': 'application/json',
        },
        timeout: const Duration(seconds: 8),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final m = data['data'] as Map<String, dynamic>? ?? {};
        return normalizeDirectManga(m);
      }
    } catch (_) {}

    // 2. Fallback to Backend
    try {
      final res = await _client
          .get(
            Uri.parse('$_baseUrl/manga/$actualId'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        return MangaItem.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
    } catch (_) {}

    throw Exception('Failed to load manga details');
  }

  Future<List<ChapterItem>> getChapters(
    String actualId, {
    String lang = 'en',
  }) async {
    // 1. Direct MangaDex API first
    try {
      final qParams = <String, dynamic>{
        'limit': '300',
        'order[chapter]': 'desc',
        'contentRating[]': ['safe', 'suggestive', 'erotica'],
        'includes[]': ['scanlation_group'],
      };
      if (lang.isNotEmpty && lang != 'all') {
        qParams['translatedLanguage[]'] = [lang];
      }
      final uri = Uri.https(
        'api.mangadex.org',
        '/manga/$actualId/feed',
        qParams,
      );
      final res = await _getCached(
        uri,
        headers: const {
          'User-Agent': 'ShioriApp/1.0',
          'Accept': 'application/json',
        },
        timeout: const Duration(seconds: 9),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['data'] as List<dynamic>?) ?? [];
        final parsed = <ChapterItem>[];
        for (final c in list) {
          final a = c['attributes'] as Map<String, dynamic>? ?? {};
          final pagesCount = (a['pages'] as num?)?.toInt() ?? 0;
          final extUrl = a['externalUrl']?.toString() ?? '';
          if (extUrl.isNotEmpty && pagesCount == 0) continue;

          final rels = (c['relationships'] as List<dynamic>?) ?? [];
          final grpRel = rels.firstWhere(
            (r) => r['type'] == 'scanlation_group',
            orElse: () => null,
          );
          final groupName = grpRel != null && grpRel['attributes'] != null
              ? grpRel['attributes']['name']?.toString() ?? ''
              : '';
          parsed.add(
            ChapterItem(
              id: c['id']?.toString() ?? '',
              number: a['chapter']?.toString(),
              volume: a['volume']?.toString(),
              title: a['title']?.toString() ?? '',
              pages: pagesCount,
              group: groupName,
              publishAt:
                  a['publishAt']?.toString() ?? a['readableAt']?.toString(),
              source: 'mangadex',
            ),
          );
        }
        return parsed;
      }
    } catch (_) {}

    // 2. Fallback to Backend
    try {
      final uri = Uri.parse(
        '$_baseUrl/manga/$actualId/chapters',
      ).replace(queryParameters: {if (lang.isNotEmpty) 'lang': lang});
      final res = await _client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['chapters'] as List<dynamic>?) ?? [];
        return list
            .map((e) => ChapterItem.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}

    return [];
  }

  Future<ChapterPages> getChapterPages(String actualChapterId) async {
    // 1. Direct MangaDex@Home server resolution first
    try {
      final res = await _client
          .get(
            Uri.parse(
              'https://api.mangadex.org/at-home/server/$actualChapterId',
            ),
            headers: const {
              'User-Agent': 'ShioriApp/1.0',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final baseUrl =
            data['baseUrl']?.toString() ?? 'https://uploads.mangadex.org';
        final chapterObj = data['chapter'] as Map<String, dynamic>? ?? {};
        final hash = chapterObj['hash']?.toString() ?? '';
        final dataList = (chapterObj['data'] as List<dynamic>?) ?? [];
        final dataSaverList = (chapterObj['dataSaver'] as List<dynamic>?) ?? [];
        final pages = dataList.map((fn) {
          final u = '$baseUrl/data/$hash/$fn';
          ImageReferers.register(u, 'https://mangadex.org/');
          return u;
        }).toList();

        final saverHost = baseUrl == 'https://uploads.mangadex.org'
            ? baseUrl
            : 'https://uploads.mangadex.org';
        final saver = dataSaverList.map((fn) {
          final u = '$saverHost/data-saver/$hash/$fn';
          ImageReferers.register(u, 'https://mangadex.org/');
          return u;
        }).toList();
        return ChapterPages(
          chapterId: actualChapterId,
          pages: pages,
          dataSaver: saver,
        );
      }
    } catch (_) {}

    // 2. Fallback to Backend
    try {
      final res = await _client
          .get(
            Uri.parse('$_baseUrl/manga/chapter/$actualChapterId/pages'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        return ChapterPages.fromJson(
          jsonDecode(res.body) as Map<String, dynamic>,
        );
      }
    } catch (_) {}

    throw Exception('Failed to load chapter pages');
  }

  MangaItem normalizeDirectManga(Map<String, dynamic> m) {
    final a = m['attributes'] as Map<String, dynamic>? ?? {};
    final rels = (m['relationships'] as List<dynamic>?) ?? [];
    final coverRel = rels.firstWhere(
      (r) => r['type'] == 'cover_art',
      orElse: () => null,
    );
    final fileName = coverRel != null && coverRel['attributes'] != null
        ? coverRel['attributes']['fileName']?.toString()
        : null;
    final id = m['id']?.toString() ?? '';

    String title = '';
    final titleMap = a['title'];
    if (titleMap is Map) {
      title =
          titleMap['en']?.toString() ??
          (titleMap.isNotEmpty ? titleMap.values.first.toString() : '');
    }
    if (title.isEmpty) {
      final alt = (a['altTitles'] as List<dynamic>?) ?? [];
      for (final t in alt) {
        if (t is Map && t['en'] != null) {
          title = t['en'].toString();
          break;
        }
      }
    }
    if (title.isEmpty) title = 'Untitled';

    String desc = '';
    final descMap = a['description'];
    if (descMap is Map) {
      desc =
          descMap['en']?.toString() ??
          (descMap.isNotEmpty ? descMap.values.first.toString() : '');
    }

    final origLang = a['originalLanguage']?.toString() ?? '';
    final type = origLang == 'ko'
        ? 'manhwa'
        : (origLang.startsWith('zh') ? 'manhua' : 'manga');
    final coverUrl = (fileName != null && fileName.isNotEmpty)
        ? HtmlScraperUtils.normalizeImgUrl(
            'https://uploads.mangadex.org/covers/$id/$fileName.512.jpg',
            referer: 'https://mangadex.org/',
          )
        : '';

    final authors = rels
        .where((r) => r['type'] == 'author' || r['type'] == 'artist')
        .map(
          (r) =>
              (r['attributes'] as Map<String, dynamic>?)?['name']?.toString() ??
              '',
        )
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList();

    final tags = ((a['tags'] as List<dynamic>?) ?? [])
        .map((t) => (t['attributes']?['name'] as Map?)?['en']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();

    return MangaItem(
      id: id,
      title: title,
      description: desc,
      cover: coverUrl,
      authors: authors,
      tags: tags,
      status: a['status']?.toString() ?? '',
      type: type,
      lastChapter: a['lastChapter']?.toString(),
      source: 'mangadex',
    );
  }
}
