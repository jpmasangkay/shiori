import 'package:http/http.dart' as http;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/scrapers/html_scraper_utils.dart';

class WeebScraper {
  final http.Client Function() _clientProvider;
  final LruHttpCache? _cache;

  WeebScraper({
    required this._clientProvider,
    this._cache,
  });

  http.Client get _client => _clientProvider();

  Future<http.Response> _getCached(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final key = uri.toString();
    if (_cache != null) {
      return _cache.deduplicate(key, () async {
        return await _client.get(uri, headers: headers).timeout(timeout);
      });
    }
    return await _client.get(uri, headers: headers).timeout(timeout);
  }

  Future<List<MangaItem>> search({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
  }) async {
    final String typeParam;
    if (type == 'manhwa') {
      typeParam = '&included_type=Manhwa';
    } else if (type == 'manhua') {
      typeParam = '&included_type=Manhua';
    } else if (type == 'manga') {
      typeParam = '&included_type=Manga';
    } else {
      typeParam = '';
    }

    final offset = (page - 1) * limit;
    final String url;
    if (query != null && query.trim().isNotEmpty) {
      url =
          'https://weebcentral.com/search/data?limit=$limit&offset=$offset&text=${Uri.encodeComponent(query.trim())}&sort=Best%20Match&order=Descending&display_mode=Full%20Display$typeParam';
    } else {
      final sort = order == 'latest' ? 'Updated%20At' : 'Popularity';
      url =
          'https://weebcentral.com/search/data?limit=$limit&offset=$offset&sort=$sort&order=Descending&display_mode=Full%20Display$typeParam';
    }
    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'HX-Request': 'true',
        'Referer': 'https://weebcentral.com/search',
      },
      timeout: const Duration(seconds: 10),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'Weeb Central');

    if (res.statusCode == 200) {
      final html = res.body;
      final articles = html.split('<article').skip(1);
      final items = <MangaItem>[];
      final seen = <String>{};

      for (final art in articles) {
        final seriesMatch = RegExp(r'href="(?:https://weebcentral\.com)?/series/([A-Z0-9]+)/([^"#?]+)"').firstMatch(art);
        if (seriesMatch == null) continue;
        final sId = seriesMatch.group(1)!;
        final slug = seriesMatch.group(2)!;
        final itemId = 'weeb:$sId:$slug';
        if (!seen.add(itemId)) continue;

        final sourceMatch = RegExp(r'<source[^>]+srcset="([^"]+)"').firstMatch(art);
        final imgTagMatch = RegExp(r'<img\b[^>]*>').firstMatch(art);
        var coverUrl = HtmlScraperUtils.normalizeImgUrl(
          sourceMatch?.group(1),
          baseUrl: 'https://weebcentral.com',
          referer: 'https://weebcentral.com/',
        );
        if (coverUrl.isEmpty && imgTagMatch != null) {
          final extracted = HtmlScraperUtils.extractImgFromTag(
            imgTagMatch.group(0)!,
            baseUrl: 'https://weebcentral.com',
            referer: 'https://weebcentral.com/',
          );
          if (!extracted.contains('/static/')) coverUrl = extracted;
        }
        if (coverUrl.isEmpty) {
          coverUrl = HtmlScraperUtils.normalizeImgUrl(
            'https://temp.compsci88.com/cover/normal/$sId.webp',
            referer: 'https://weebcentral.com/',
          );
        }

        final titleMatch = RegExp(r'<a[^>]+class="[^"]*link-hover[^"]*"[^>]*>([\s\S]*?)</a>').firstMatch(art) ??
            RegExp(r'href="(?:https://weebcentral\.com)?/series/[^/]+/[^"]+">([^<]+)</a>').firstMatch(art);
        final rawTitle = titleMatch?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '';
        final title = HtmlScraperUtils.unescapeHtml(rawTitle.isNotEmpty ? rawTitle : slug.replaceAll('-', ' '));

        items.add(MangaItem(
          id: itemId,
          title: title,
          cover: coverUrl,
          type: type ?? 'manga',
          source: 'weebcentral',
        ));
      }
      return items;
    }
    return [];
  }

  Future<MangaItem> getManga(String id) async {
    final parts = id.split(':');
    final sId = parts.length > 1 ? parts[1] : '';
    final slug = parts.length > 2 ? parts[2] : '';
    final url = 'https://weebcentral.com/series/$sId/$slug';

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
      },
      timeout: const Duration(seconds: 10),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'Weeb Central');

    if (res.statusCode == 200) {
      final html = res.body;
      final titleMatch = RegExp(r'<h1[^>]*>([^<]+)</h1>').firstMatch(html);
      final title = HtmlScraperUtils.unescapeHtml(titleMatch?.group(1)?.trim() ?? slug.replaceAll('-', ' '));

      final descMatch = RegExp(r'<p class="whitespace-pre-line[^"]*">([\s\S]*?)</p>').firstMatch(html);
      final desc = HtmlScraperUtils.unescapeHtml(descMatch?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '');

      final picMatch = RegExp(r'<picture[^>]*>[\s\S]*?<source[^>]+srcset="([^"]+)"').firstMatch(html) ??
          RegExp(r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"').firstMatch(html);
      var coverUrl = HtmlScraperUtils.normalizeImgUrl(
        picMatch?.group(1),
        baseUrl: 'https://weebcentral.com',
        referer: 'https://weebcentral.com/',
      );
      if (coverUrl.isEmpty || coverUrl.contains('/static/')) {
        coverUrl = HtmlScraperUtils.normalizeImgUrl(
          'https://temp.compsci88.com/cover/normal/$sId.webp',
          referer: 'https://weebcentral.com/',
        );
      }

      final authors = RegExp(r'href="[^"]*author=[^"]*"[^>]*>([^<]+)</a>')
          .allMatches(html)
          .map((m) => HtmlScraperUtils.unescapeHtml(m.group(1)!.trim()))
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();
      final tags = RegExp(r'href="[^"]*included_tag=[^"]*"[^>]*>([^<]+)</a>')
          .allMatches(html)
          .map((m) => HtmlScraperUtils.unescapeHtml(m.group(1)!.trim()))
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();

      return MangaItem(
        id: id,
        title: title,
        description: desc,
        cover: coverUrl,
        authors: authors,
        tags: tags,
        source: 'weebcentral',
      );
    }
    throw Exception('Failed to load Weeb Central series details');
  }

  Future<List<ChapterItem>> getChapters(String id) async {
    final parts = id.split(':');
    final sId = parts.length > 1 ? parts[1] : '';
    final url = 'https://weebcentral.com/series/$sId/full-chapter-list';

    final res = await _getCached(
      Uri.parse(url),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'HX-Request': 'true',
        'Referer': 'https://weebcentral.com/series/$sId',
      },
      timeout: const Duration(seconds: 10),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'Weeb Central');

    if (res.statusCode == 200) {
      final html = res.body;
      final regex = RegExp(
        r'<a[^>]+href="(?:https://weebcentral\.com)?/chapters/([A-Z0-9]+)"[^>]*>([\s\S]*?)</a>',
        caseSensitive: false,
      );
      final matches = regex.allMatches(html);
      final list = <ChapterItem>[];
      final seen = <String>{};

      for (final m in matches) {
        final chId = m.group(1)!;
        if (!seen.add(chId)) continue;
        final block = m.group(2)!;
        final spanMatch = RegExp(r'<span class="">([^<]+)</span>').firstMatch(block);
        final chText = HtmlScraperUtils.unescapeHtml(
          (spanMatch?.group(1) ?? block.replaceAll(RegExp(r'<[^>]*>'), '')).trim(),
        );
        final numMatch = RegExp(r'(?:Chapter|Episode|Ch\.?)\s*([\d\.]+)', caseSensitive: false).firstMatch(chText);
        final chNum = numMatch?.group(1);
        final timeMatch = RegExp(r'datetime="([^"]+)"').firstMatch(block);

        list.add(ChapterItem(
          id: 'weeb:$chId',
          number: chNum,
          title: chText.isNotEmpty ? chText : 'Chapter',
          publishAt: timeMatch?.group(1),
          group: 'Weeb Central',
          source: 'weebcentral',
        ));
      }
      return list;
    }
    return [];
  }

  Future<ChapterPages> getChapterPages(String chapterId) async {
    final cleanId = chapterId.replaceFirst('weeb:', '');
    final url =
        'https://weebcentral.com/chapters/$cleanId/images?is_prev=False&current_page=1&reading_style=long_strip';

    final res = await _client.get(
      Uri.parse(url),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'HX-Request': 'true',
        'Referer': 'https://weebcentral.com/chapters/$cleanId',
      },
    ).timeout(const Duration(seconds: 12));

    HtmlScraperUtils.checkResponseHealth(res, 'Weeb Central');

    if (res.statusCode == 200) {
      final html = res.body;
      final imgTags = RegExp(r'<img\b[^>]*>', caseSensitive: false).allMatches(html);
      final pagesList = <String>[];
      final seen = <String>{};
      for (final m in imgTags) {
        final u = HtmlScraperUtils.extractImgFromTag(
          m.group(0)!,
          baseUrl: 'https://weebcentral.com',
          referer: 'https://weebcentral.com/',
        );
        if (u.isEmpty || u.contains('/static/') || u.contains('logo') || u.contains('avatar')) {
          continue;
        }
        if (seen.add(u)) {
          pagesList.add(u);
        }
      }

      if (pagesList.isNotEmpty) {
        return ChapterPages(chapterId: chapterId, pages: pagesList, dataSaver: pagesList);
      }
    }
    throw Exception('Failed to load Weeb Central chapter pages');
  }
}
