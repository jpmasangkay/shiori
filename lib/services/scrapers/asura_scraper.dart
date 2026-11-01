import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/scrapers/html_scraper_utils.dart';

class AsuraScraper {
  final http.Client Function() _clientProvider;
  final LruHttpCache? _cache;

  AsuraScraper({
    required this._clientProvider,
    this._cache,
  });

  http.Client get _client => _clientProvider();

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

  Future<List<MangaItem>> search({String? query, String? type, int page = 1}) async {
    if (type != null && type.isNotEmpty && type != 'all' && type != 'manhwa') {
      return [];
    }
    final uri = Uri.parse('https://api.asurascans.com/api/series').replace(queryParameters: {
      if (query != null && query.trim().isNotEmpty) 'search': query.trim(),
      'page': page.toString(),
    });
    final res = await _getCached(
      uri,
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'application/json',
      },
      timeout: const Duration(seconds: 8),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'Asura Scans');

    if (res.statusCode == 200) {
      final clean = res.body.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
      final data = jsonDecode(clean) as Map<String, dynamic>;
      final list = (data['data'] as List<dynamic>?) ?? [];
      return list.map((item) {
        final latest = item['latest_chapters'] as List<dynamic>?;
        final chNum = latest != null && latest.isNotEmpty ? latest[0]['number']?.toString() : null;
        final desc = (item['description']?.toString() ?? '').replaceAll(RegExp(r'<[^>]*>'), '').trim();
        final cover = HtmlScraperUtils.normalizeImgUrl(
          item['cover']?.toString() ?? item['thumb']?.toString(),
          baseUrl: 'https://asurascans.com',
          referer: 'https://asurascans.com/',
        );
        return MangaItem(
          id: 'asura:${item['slug']}',
          title: HtmlScraperUtils.unescapeHtml(item['title']?.toString() ?? 'Untitled'),
          description: HtmlScraperUtils.unescapeHtml(desc),
          cover: cover,
          status: item['status']?.toString() ?? '',
          type: item['type']?.toString() ?? 'manhwa',
          lastChapter: chNum,
          source: 'asura',
        );
      }).toList();
    }
    return [];
  }

  Future<MangaItem> getManga(String id) async {
    final cleanSlug = id.replaceFirst('asura:', '');
    final uri = Uri.parse('https://api.asurascans.com/api/series/$cleanSlug');
    final res = await _getCached(
      uri,
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'application/json',
      },
      timeout: const Duration(seconds: 8),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'Asura Scans');

    if (res.statusCode == 200) {
      final clean = res.body.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
      final data = jsonDecode(clean) as Map<String, dynamic>;
      final rawInner = data['data'];
      final s = (rawInner is Map<String, dynamic>
              ? (rawInner['series'] as Map<String, dynamic>? ?? rawInner)
              : null) ??
          (data['series'] as Map<String, dynamic>?) ??
          data;
      final desc = (s['description']?.toString() ?? s['synopsis']?.toString() ?? '')
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .trim();
      final genres = (s['genres'] as List<dynamic>?)
              ?.map((g) => (g is Map ? g['name']?.toString() : g?.toString()) ?? '')
              .where((g) => g.isNotEmpty)
              .toList() ??
          [];
      final cover = HtmlScraperUtils.normalizeImgUrl(
        s['cover']?.toString() ??
            s['thumb']?.toString() ??
            s['cover_url']?.toString() ??
            s['poster']?.toString() ??
            s['image']?.toString(),
        baseUrl: 'https://asurascans.com',
        referer: 'https://asurascans.com/',
      );
      return MangaItem(
        id: 'asura:$cleanSlug',
        title: HtmlScraperUtils.unescapeHtml(s['title']?.toString() ?? 'Untitled'),
        description: HtmlScraperUtils.unescapeHtml(desc),
        cover: cover,
        status: s['status']?.toString() ?? '',
        type: s['type']?.toString() ?? 'manhwa',
        authors: [if (s['author'] != null && s['author'].toString().isNotEmpty) s['author'].toString()],
        tags: genres,
        source: 'asura',
      );
    }
    throw Exception('Failed to load Asura series details');
  }

  Future<List<ChapterItem>> getChapters(String id) async {
    final cleanSlug = id.replaceFirst('asura:', '');
    final uri = Uri.parse('https://api.asurascans.com/api/series/$cleanSlug/chapters');
    final res = await _getCached(
      uri,
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'application/json',
      },
      timeout: const Duration(seconds: 8),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'Asura Scans');

    if (res.statusCode == 200) {
      final clean = res.body.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
      final data = jsonDecode(clean) as Map<String, dynamic>;
      final list = (data['data'] as List<dynamic>?) ?? [];
      final chapters = <ChapterItem>[];
      for (final ch in list) {
        if (ch['is_locked'] == true || ch['is_premium'] == true) continue;
        final chSlug = ch['slug']?.toString() ?? '';
        if (chSlug.isEmpty) continue;
        chapters.add(ChapterItem(
          id: 'asura:$cleanSlug:$chSlug',
          number: ch['number']?.toString(),
          title: ch['title']?.toString() ?? '',
          group: 'Asura Scans',
          publishAt: ch['published_at']?.toString(),
          pages: (ch['page_count'] as num?)?.toInt() ?? 0,
          source: 'asura',
        ));
      }

      chapters.sort((a, b) {
        final na = double.tryParse(a.number ?? '') ?? -1.0;
        final nb = double.tryParse(b.number ?? '') ?? -1.0;
        return nb.compareTo(na);
      });
      return chapters;
    }
    return [];
  }

  Future<ChapterPages> getChapterPages(String chapterId) async {
    final parts = chapterId.split(':');
    if (parts.length < 3) throw Exception('Invalid Asura chapter ID');
    final seriesSlug = parts[1];
    final chapterSlug = parts[2];
    final uri = Uri.parse('https://api.asurascans.com/api/series/$seriesSlug/chapters/$chapterSlug');
    final res = await _client.get(uri, headers: const {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      'Accept': 'application/json',
      'Referer': 'https://asurascans.com/',
    }).timeout(const Duration(seconds: 10));

    HtmlScraperUtils.checkResponseHealth(res, 'Asura Scans');

    if (res.statusCode == 200) {
      final clean = res.body.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
      final data = jsonDecode(clean) as Map<String, dynamic>;
      final chapterObj = data['data']?['chapter'] as Map<String, dynamic>?;
      final pagesList = (chapterObj?['pages'] as List<dynamic>?)
              ?.map((p) => HtmlScraperUtils.normalizeImgUrl(
                    p['url']?.toString(),
                    baseUrl: 'https://asurascans.com',
                    referer: 'https://asurascans.com/',
                  ))
              .where((u) => u.isNotEmpty)
              .toList() ??
          [];
      if (pagesList.isEmpty && chapterObj?['is_locked'] == true) {
        throw Exception('This chapter is currently Early Access / locked on Asura Scans.');
      }
      return ChapterPages(chapterId: chapterId, pages: pagesList, dataSaver: pagesList);
    }
    throw Exception('Failed to load Asura chapter pages');
  }
}
