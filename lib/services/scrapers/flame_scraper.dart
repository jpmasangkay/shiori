import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/scrapers/html_scraper_utils.dart';

class FlameScraper {
  final http.Client Function() _clientProvider;
  final LruHttpCache? _cache;

  List<MangaItem>? _flameSeriesCache;
  DateTime? _flameCacheExpiresAt;

  FlameScraper({required this._clientProvider, this._cache});

  http.Client get _client => _clientProvider();

  void clearCache() {
    _flameSeriesCache = null;
    _flameCacheExpiresAt = null;
  }

  Future<http.Response> _getCached(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
    Duration ttl = const Duration(minutes: 3),
  }) async {
    final key = uri.toString();
    if (_cache != null) {
      return _cache.deduplicate(key, () async {
        return await _client.get(uri, headers: headers).timeout(timeout);
      });
    }
    return await _client.get(uri, headers: headers).timeout(timeout);
  }

  Future<List<MangaItem>> loadSeriesList() async {
    final now = DateTime.now();
    if (_flameSeriesCache != null &&
        _flameCacheExpiresAt != null &&
        now.isBefore(_flameCacheExpiresAt!)) {
      return _flameSeriesCache!;
    }

    final res = await _getCached(
      Uri.parse('https://flamecomics.xyz/browse'),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
      timeout: const Duration(seconds: 10),
      ttl: const Duration(minutes: 3),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'Flame Comics');

    if (res.statusCode == 200) {
      final html = res.body;
      final idx = html.indexOf('<script id="__NEXT_DATA__"');
      if (idx == -1) return [];
      final end = html.indexOf('</script>', idx);
      if (end == -1) return [];
      final jsonStr = html.substring(html.indexOf('>', idx) + 1, end);
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final seriesList =
          (data['props']?['pageProps']?['series'] as List<dynamic>?) ?? [];

      final items = seriesList.map((item) {
        final sId = item['series_id']?.toString() ?? '';
        final coverFile = item['cover']?.toString() ?? '';
        final rawCover = coverFile.startsWith('http')
            ? coverFile
            : (coverFile.isNotEmpty
                  ? 'https://cdn.flamecomics.xyz/uploads/images/series/$sId/$coverFile'
                  : '');
        final coverUrl = HtmlScraperUtils.normalizeImgUrl(
          rawCover,
          referer: 'https://flamecomics.xyz/',
        );
        final cats =
            (item['categories'] as List<dynamic>?)
                ?.map((c) => c.toString())
                .toList() ??
            <String>[];
        final authors =
            (item['author'] as List<dynamic>?)
                ?.map((a) => a.toString())
                .toList() ??
            <String>[];

        return MangaItem(
          id: 'flame:$sId',
          title: HtmlScraperUtils.unescapeHtml(
            item['title']?.toString() ?? 'Untitled',
          ),
          description: HtmlScraperUtils.unescapeHtml(
            (item['description']?.toString() ?? '')
                .replaceAll(RegExp(r'<[^>]*>'), '')
                .trim(),
          ),
          cover: coverUrl,
          status: item['status']?.toString() ?? '',
          type: item['type']?.toString().toLowerCase() ?? 'manhwa',
          tags: cats,
          authors: authors,
          source: 'flamecomics',
        );
      }).toList();

      if (items.isNotEmpty) {
        _flameSeriesCache = items;
        _flameCacheExpiresAt = DateTime.now().add(const Duration(minutes: 3));
      }
      return items;
    }
    return [];
  }

  Future<List<MangaItem>> search({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
  }) async {
    var items = List<MangaItem>.from(await loadSeriesList());
    if (items.isEmpty) return [];

    if (type != null && type.isNotEmpty && type != 'all') {
      final t = type.toLowerCase();
      items = items.where((m) {
        final mt = m.type.toLowerCase();
        if (t == 'manhwa') {
          return mt.contains('manhwa') || mt == 'webtoon' || mt == 'comic';
        }
        if (t == 'manga') return mt.contains('manga');
        if (t == 'manhua') return mt.contains('manhua');
        return mt == t;
      }).toList();
    }

    if (query != null && query.trim().isNotEmpty) {
      final q = query.trim().toLowerCase();
      items = items
          .where(
            (m) =>
                m.title.toLowerCase().contains(q) ||
                m.description.toLowerCase().contains(q),
          )
          .toList();
      items.sort((a, b) {
        final aTitle = a.title.toLowerCase().contains(q) ? 0 : 1;
        final bTitle = b.title.toLowerCase().contains(q) ? 0 : 1;
        return aTitle.compareTo(bTitle);
      });
    }

    final start = (page - 1) * limit;
    if (start >= items.length) return [];
    return items.skip(start).take(limit).toList();
  }

  Future<MangaItem> getManga(String id) async {
    final sId = id.replaceFirst('flame:', '');
    final res = await _getCached(
      Uri.parse('https://flamecomics.xyz/series/$sId'),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
      timeout: const Duration(seconds: 10),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'Flame Comics');

    if (res.statusCode == 200) {
      final html = res.body;
      final idx = html.indexOf('<script id="__NEXT_DATA__"');
      if (idx != -1) {
        final end = html.indexOf('</script>', idx);
        final jsonStr = html.substring(html.indexOf('>', idx) + 1, end);
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        final s =
            data['props']?['pageProps']?['series'] as Map<String, dynamic>? ??
            {};
        final coverFile = s['cover']?.toString() ?? '';
        final rawCover = coverFile.startsWith('http')
            ? coverFile
            : (coverFile.isNotEmpty
                  ? 'https://cdn.flamecomics.xyz/uploads/images/series/$sId/$coverFile'
                  : '');
        final coverUrl = HtmlScraperUtils.normalizeImgUrl(
          rawCover,
          referer: 'https://flamecomics.xyz/',
        );
        final cats =
            (s['categories'] as List<dynamic>?)
                ?.map((c) => c.toString())
                .toList() ??
            <String>[];
        final authors =
            (s['author'] as List<dynamic>?)
                ?.map((a) => a.toString())
                .toList() ??
            <String>[];

        return MangaItem(
          id: id,
          title: HtmlScraperUtils.unescapeHtml(
            s['title']?.toString() ?? 'Untitled',
          ),
          description: HtmlScraperUtils.unescapeHtml(
            (s['description']?.toString() ?? '')
                .replaceAll(RegExp(r'<[^>]*>'), '')
                .trim(),
          ),
          cover: coverUrl,
          status: s['status']?.toString() ?? '',
          type: s['type']?.toString().toLowerCase() ?? 'manhwa',
          tags: cats,
          authors: authors,
          source: 'flamecomics',
        );
      }
    }
    throw Exception('Failed to load Flame Comics series details');
  }

  Future<List<ChapterItem>> getChapters(String id) async {
    final sId = id.replaceFirst('flame:', '');
    final res = await _getCached(
      Uri.parse('https://flamecomics.xyz/series/$sId'),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
      timeout: const Duration(seconds: 10),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'Flame Comics');

    if (res.statusCode == 200) {
      final html = res.body;
      final idx = html.indexOf('<script id="__NEXT_DATA__"');
      if (idx != -1) {
        final end = html.indexOf('</script>', idx);
        final jsonStr = html.substring(html.indexOf('>', idx) + 1, end);
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        final chs =
            (data['props']?['pageProps']?['chapters'] as List<dynamic>?) ?? [];

        final list = chs.map((c) {
          final token = c['token']?.toString() ?? '';
          final chNum = c['chapter']?.toString();
          final title = c['title']?.toString() ?? '';
          final rel = c['release_date']?.toString();
          return ChapterItem(
            id: 'flame:$sId:$token',
            number: chNum,
            title: title,
            group: 'Flame Comics',
            source: 'flamecomics',
            publishAt: rel,
          );
        }).toList();

        list.sort((a, b) {
          final na = double.tryParse(a.number ?? '') ?? -1.0;
          final nb = double.tryParse(b.number ?? '') ?? -1.0;
          return nb.compareTo(na);
        });
        return list;
      }
    }
    return [];
  }

  Future<ChapterPages> getChapterPages(String chapterId) async {
    final parts = chapterId.split(':');
    if (parts.length < 3) throw Exception('Invalid Flame chapter ID');
    final sId = parts[1];
    final token = parts[2];
    final res = await _client
        .get(
          Uri.parse('https://flamecomics.xyz/series/$sId/$token'),
          headers: const {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
            'Accept': 'text/html',
            'Referer': 'https://flamecomics.xyz/',
          },
        )
        .timeout(const Duration(seconds: 10));

    HtmlScraperUtils.checkResponseHealth(res, 'Flame Comics');

    if (res.statusCode == 200) {
      final html = res.body;
      final idx = html.indexOf('<script id="__NEXT_DATA__"');
      if (idx != -1) {
        final end = html.indexOf('</script>', idx);
        final jsonStr = html.substring(html.indexOf('>', idx) + 1, end);
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        final imgsObj = data['props']?['pageProps']?['chapter']?['images'];
        final pagesList = <String>[];
        if (imgsObj is Map<String, dynamic>) {
          final sortedKeys = imgsObj.keys.toList()
            ..sort(
              (a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0),
            );
          for (final k in sortedKeys) {
            final imgMap = imgsObj[k];
            if (imgMap is Map<String, dynamic>) {
              final name = imgMap['name']?.toString() ?? '';
              if (name.isNotEmpty) {
                final u = HtmlScraperUtils.normalizeImgUrl(
                  'https://cdn.flamecomics.xyz/uploads/images/series/$sId/$token/$name',
                  referer: 'https://flamecomics.xyz/',
                );
                if (u.isNotEmpty) pagesList.add(u);
              }
            }
          }
        } else if (imgsObj is List) {
          for (final entry in imgsObj) {
            final name = entry is Map
                ? entry['name']?.toString() ?? ''
                : entry.toString();
            if (name.isNotEmpty) {
              final u = HtmlScraperUtils.normalizeImgUrl(
                name.startsWith('http')
                    ? name
                    : 'https://cdn.flamecomics.xyz/uploads/images/series/$sId/$token/$name',
                referer: 'https://flamecomics.xyz/',
              );
              if (u.isNotEmpty) pagesList.add(u);
            }
          }
        }
        return ChapterPages(
          chapterId: chapterId,
          pages: pagesList,
          dataSaver: pagesList,
        );
      }
    }
    throw Exception('Failed to load Flame Comics chapter pages');
  }
}
