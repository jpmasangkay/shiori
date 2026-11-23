import 'package:http/http.dart' as http;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/scrapers/html_scraper_utils.dart';

/// WeebCentral HTML scraper backed by `package:html` standards-compliant DOM parsing.
class WeebScraper {
  final http.Client Function() _clientProvider;
  final LruHttpCache? _cache;

  WeebScraper({required this._clientProvider, this._cache});

  http.Client get _client => _clientProvider();

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  Future<http.Response> _getCached(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final key = uri.toString();
    if (_cache != null) {
      return _cache.deduplicate(
        key,
        () async => _client.get(uri, headers: headers).timeout(timeout),
        shouldCache: (r) => r.statusCode == 200,
      );
    }
    return _client.get(uri, headers: headers).timeout(timeout);
  }

  Future<List<MangaItem>> search({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
  }) async {
    final String typeParam = switch (type) {
      'manhwa' => '&included_type=Manhwa',
      'manhua' => '&included_type=Manhua',
      'manga' => '&included_type=Manga',
      _ => '',
    };

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
        'User-Agent': _ua,
        'Accept': 'text/html',
        'HX-Request': 'true',
        'Referer': 'https://weebcentral.com/search',
      },
      timeout: const Duration(seconds: 10),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'Weeb Central');

    if (res.statusCode == 200) {
      final doc = HtmlScraperUtils.parseDocument(res.body);
      final seriesRe = RegExp(r'^(?:https://weebcentral\.com)?/series/([A-Z0-9]+)/([^#?]+)');
      final items = <MangaItem>[];
      final seen = <String>{};

      for (final art in doc.querySelectorAll('article')) {
        String? sId;
        String? slug;
        for (final a in art.querySelectorAll('a[href*="/series/"]')) {
          final m = seriesRe.firstMatch(a.attributes['href']?.trim() ?? '');
          if (m != null) {
            sId = m.group(1);
            slug = m.group(2);
            break;
          }
        }
        if (sId == null || slug == null) continue;
        final itemId = 'weeb:$sId:$slug';
        if (!seen.add(itemId)) continue;

        final sourceEl = art.querySelector('source[srcset]');
        var coverUrl = HtmlScraperUtils.normalizeImgUrl(
          sourceEl?.attributes['srcset'],
          baseUrl: 'https://weebcentral.com',
          referer: 'https://weebcentral.com/',
        );
        if (coverUrl.isEmpty) {
          final extracted = HtmlScraperUtils.extractImgFromElement(
            art.querySelector('img'),
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

        final titleEl =
            art.querySelector('a.link-hover') ??
            art.querySelector('a[href*="/series/"]');
        final rawTitle = titleEl?.text.trim() ?? '';
        final title = HtmlScraperUtils.unescapeHtml(
          rawTitle.isNotEmpty ? rawTitle : slug.replaceAll('-', ' '),
        );

        items.add(
          MangaItem(
            id: itemId,
            title: title,
            cover: coverUrl,
            type: type ?? 'manga',
            source: 'weebcentral',
          ),
        );
      }
      return items;
    }
    return [];
  }

  Future<MangaItem> getManga(String id) async {
    final parts = id.split(':');
    final sId = parts.length > 1 ? parts[1] : '';
    final slug = parts.length > 2 ? parts[2] : '';
    final url = slug.isNotEmpty
        ? 'https://weebcentral.com/series/$sId/$slug'
        : 'https://weebcentral.com/series/$sId';

    final res = await _getCached(
      Uri.parse(url),
      headers: const {'User-Agent': _ua, 'Accept': 'text/html'},
      timeout: const Duration(seconds: 10),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'Weeb Central');

    if (res.statusCode == 200) {
      final doc = HtmlScraperUtils.parseDocument(res.body);
      final title = HtmlScraperUtils.unescapeHtml(
        doc.querySelector('h1')?.text.trim() ?? slug.replaceAll('-', ' '),
      );
      final desc = HtmlScraperUtils.unescapeHtml(
        doc.querySelector('p.whitespace-pre-line')?.text.trim() ?? '',
      );

      final rawCover =
          doc.querySelector('picture source[srcset]')?.attributes['srcset'] ??
          doc.querySelector('meta[property="og:image"]')?.attributes['content'];
      var coverUrl = HtmlScraperUtils.normalizeImgUrl(
        rawCover,
        baseUrl: 'https://weebcentral.com',
        referer: 'https://weebcentral.com/',
      );
      if (coverUrl.isEmpty || coverUrl.contains('/static/')) {
        coverUrl = HtmlScraperUtils.normalizeImgUrl(
          'https://temp.compsci88.com/cover/normal/$sId.webp',
          referer: 'https://weebcentral.com/',
        );
      }

      final authors = doc
          .querySelectorAll('a[href*="author="]')
          .map((e) => HtmlScraperUtils.unescapeHtml(e.text.trim()))
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();
      final tags = doc
          .querySelectorAll('a[href*="included_tag="]')
          .map((e) => HtmlScraperUtils.unescapeHtml(e.text.trim()))
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
        'User-Agent': _ua,
        'Accept': 'text/html',
        'HX-Request': 'true',
        'Referer': 'https://weebcentral.com/series/$sId',
      },
      timeout: const Duration(seconds: 10),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'Weeb Central');

    if (res.statusCode == 200) {
      final doc = HtmlScraperUtils.parseDocument(res.body);
      final hrefRe = RegExp(
        r'^(?:https://weebcentral\.com)?/chapters/([A-Z0-9]+)',
        caseSensitive: false,
      );
      final numRe = RegExp(
        r'(?:Chapter|Episode|Ch\.?)\s*([\d\.]+)',
        caseSensitive: false,
      );
      final list = <ChapterItem>[];
      final seen = <String>{};

      for (final a in doc.querySelectorAll('a[href*="/chapters/"]')) {
        final href = a.attributes['href']?.trim() ?? '';
        final m = hrefRe.firstMatch(href);
        if (m == null) continue;
        final chId = m.group(1)!;
        if (!seen.add(chId)) continue;

        final spanEl = a.querySelector('span[class=""]') ?? a.querySelector('span');
        final rawText = (spanEl?.text ?? a.text).trim();
        final chText = HtmlScraperUtils.unescapeHtml(rawText);
        final chNum = numRe.firstMatch(chText)?.group(1);
        final publishAt = a.querySelector('time[datetime]')?.attributes['datetime'];

        list.add(
          ChapterItem(
            id: 'weeb:$chId',
            number: chNum,
            title: chText.isNotEmpty ? chText : 'Chapter',
            publishAt: publishAt,
            group: 'Weeb Central',
            source: 'weebcentral',
          ),
        );
      }
      return list;
    }
    return [];
  }

  Future<ChapterPages> getChapterPages(String chapterId) async {
    final cleanId = chapterId.replaceFirst('weeb:', '');
    final url =
        'https://weebcentral.com/chapters/$cleanId/images?is_prev=False&current_page=1&reading_style=long_strip';

    final res = await _client
        .get(
          Uri.parse(url),
          headers: {
            'User-Agent': _ua,
            'Accept': 'text/html',
            'HX-Request': 'true',
            'Referer': 'https://weebcentral.com/chapters/$cleanId',
          },
        )
        .timeout(const Duration(seconds: 12));

    HtmlScraperUtils.checkResponseHealth(res, 'Weeb Central');

    if (res.statusCode == 200) {
      final doc = HtmlScraperUtils.parseDocument(res.body);
      final pagesList = <String>[];
      final seen = <String>{};
      for (final img in doc.querySelectorAll('img')) {
        final u = HtmlScraperUtils.extractImgFromElement(
          img,
          baseUrl: 'https://weebcentral.com',
          referer: 'https://weebcentral.com/',
        );
        if (u.isEmpty ||
            u.contains('/static/') ||
            u.contains('logo') ||
            u.contains('avatar')) {
          continue;
        }
        if (seen.add(u)) {
          pagesList.add(u);
        }
      }

      if (pagesList.isNotEmpty) {
        return ChapterPages(
          chapterId: chapterId,
          pages: pagesList,
          dataSaver: pagesList,
        );
      }
    }
    throw Exception('Failed to load Weeb Central chapter pages');
  }
}
