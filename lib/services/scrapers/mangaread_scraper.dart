import 'package:http/http.dart' as http;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/scrapers/html_scraper_utils.dart';

class MangaReadScraper {
  final http.Client Function() _clientProvider;
  final LruHttpCache? _cache;

  MangaReadScraper({required this._clientProvider, this._cache});

  http.Client get _client => _clientProvider();

  Future<http.Response> _getCached(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 12),
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
    final sortParam = order == 'popular' ? 'views' : 'latest';
    final String url;
    if (query != null && query.trim().isNotEmpty) {
      url =
          'https://www.mangaread.org/page/$page/?s=${Uri.encodeComponent(query.trim())}&post_type=wp-manga';
    } else if (type == 'manhwa') {
      url =
          'https://www.mangaread.org/genres/manhwa/page/$page/?m_orderby=$sortParam';
    } else if (type == 'manhua') {
      url =
          'https://www.mangaread.org/genres/manhua/page/$page/?m_orderby=$sortParam';
    } else if (type == 'manga') {
      url =
          'https://www.mangaread.org/genres/manga/page/$page/?m_orderby=$sortParam';
    } else {
      url = 'https://www.mangaread.org/manga/page/$page/?m_orderby=$sortParam';
    }

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://www.mangaread.org/',
      },
      timeout: const Duration(seconds: 12),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaRead');

    if (res.statusCode == 200) {
      final html = res.body;
      final cardRegex = RegExp(
        r'<div[^>]*class="[^"]*(?:item-thumb|tab-thumb)[^"]*"[^>]*>[\s\S]*?<a href="https://www\.mangaread\.org/manga/([^/]+)/"[^>]*title="([^"]*)"[^>]*>([\s\S]*?<img\b[^>]*>)',
        caseSensitive: false,
      );

      final matches = cardRegex.allMatches(html);
      final items = <MangaItem>[];
      final seen = <String>{};

      for (final m in matches) {
        final slug = m.group(1)!;
        final title = HtmlScraperUtils.unescapeHtml(m.group(2)!.trim());
        final imgBlock = m.group(3)!;
        final imgTag =
            RegExp(
              r'<img\b[^>]*>',
              caseSensitive: false,
            ).firstMatch(imgBlock)?.group(0) ??
            '';
        final cover = HtmlScraperUtils.extractImgFromTag(
          imgTag,
          baseUrl: 'https://www.mangaread.org',
          referer: 'https://www.mangaread.org/',
        );

        final id = 'mread:$slug';
        if (!seen.add(id)) continue;

        items.add(
          MangaItem(
            id: id,
            title: title,
            cover: cover,
            type:
                type ??
                (url.contains('manhwa')
                    ? 'manhwa'
                    : (url.contains('manhua') ? 'manhua' : 'manga')),
            source: 'mangaread',
          ),
        );
        if (items.length >= limit) break;
      }
      return items;
    }
    return [];
  }

  Future<MangaItem> getManga(String id) async {
    final slug = id.replaceFirst('mread:', '');
    final url = 'https://www.mangaread.org/manga/$slug/';

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://www.mangaread.org/',
      },
      timeout: const Duration(seconds: 12),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaRead');

    if (res.statusCode == 200) {
      final html = res.body;
      final titleMatch = RegExp(
        r'<div class="post-title">[\s\S]*?<h1>([^<]+)</h1>',
      ).firstMatch(html);
      final title = HtmlScraperUtils.unescapeHtml(
        titleMatch?.group(1)?.trim() ?? slug.replaceAll('-', ' '),
      );

      final descMatch = RegExp(
        r'<div class="description-summary">[\s\S]*?<p>([\s\S]*?)</p>',
      ).firstMatch(html);
      final desc = HtmlScraperUtils.unescapeHtml(
        descMatch?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '',
      );

      final coverDivMatch = RegExp(
        r'<div class="summary_image"[^>]*>[\s\S]*?(<img\b[^>]*>)',
        caseSensitive: false,
      ).firstMatch(html);
      var cover = coverDivMatch != null
          ? HtmlScraperUtils.extractImgFromTag(
              coverDivMatch.group(1)!,
              baseUrl: 'https://www.mangaread.org',
              referer: 'https://www.mangaread.org/',
            )
          : '';
      if (cover.isEmpty) {
        final ogMatch = RegExp(
          r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"',
          caseSensitive: false,
        ).firstMatch(html);
        cover = HtmlScraperUtils.normalizeImgUrl(
          ogMatch?.group(1),
          baseUrl: 'https://www.mangaread.org',
          referer: 'https://www.mangaread.org/',
        );
      }

      final authorBlock =
          RegExp(
            r'<div class="author-content">([\s\S]*?)</div>',
          ).firstMatch(html)?.group(1) ??
          '';
      final authors = RegExp(r'<a[^>]*>([^<]+)</a>')
          .allMatches(authorBlock)
          .map((m) => HtmlScraperUtils.unescapeHtml(m.group(1)!.trim()))
          .where((s) => s.isNotEmpty)
          .toList();

      final genreBlock =
          RegExp(
            r'<div class="genres-content">([\s\S]*?)</div>',
          ).firstMatch(html)?.group(1) ??
          '';
      final tags = RegExp(r'<a[^>]*>([^<]+)</a>')
          .allMatches(genreBlock)
          .map((m) => HtmlScraperUtils.unescapeHtml(m.group(1)!.trim()))
          .where((s) => s.isNotEmpty)
          .toList();

      return MangaItem(
        id: id,
        title: title,
        description: desc,
        cover: cover,
        authors: authors,
        tags: tags,
        source: 'mangaread',
      );
    }
    throw Exception('Failed to load MangaRead series details');
  }

  Future<List<ChapterItem>> getChapters(String mangaId) async {
    final slug = mangaId.replaceFirst('mread:', '');
    final url = 'https://www.mangaread.org/manga/$slug/';

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://www.mangaread.org/',
      },
      timeout: const Duration(seconds: 12),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaRead');

    if (res.statusCode == 200) {
      final html = res.body;
      final chapterRegex = RegExp(
        r'<li class="wp-manga-chapter[^>]*>[\s\S]*?<a href="https://www\.mangaread\.org/manga/[^/]+/([^/]+)/"[^>]*>([^<]+)</a>',
        caseSensitive: false,
      );

      final matches = chapterRegex.allMatches(html);
      final chapters = <ChapterItem>[];

      for (final m in matches) {
        final cSlug = m.group(1)!;
        final rawTitle = HtmlScraperUtils.unescapeHtml(m.group(2)!.trim());
        final numMatch = RegExp(
          r'Chapter\s+([0-9.]+)',
          caseSensitive: false,
        ).firstMatch(rawTitle);
        final num = numMatch?.group(1);

        chapters.add(
          ChapterItem(
            id: 'mread:$slug:$cSlug',
            title: rawTitle,
            number: num,
            group: 'MangaRead',
            source: 'mangaread',
          ),
        );
      }
      return chapters;
    }
    return [];
  }

  Future<ChapterPages> getChapterPages(String chapterId) async {
    final parts = chapterId.split(':');
    final slug = parts.length > 1 ? parts[1] : '';
    final cSlug = parts.length > 2 ? parts[2] : '';
    final url = 'https://www.mangaread.org/manga/$slug/$cSlug/';

    final res = await _client
        .get(
          Uri.parse(url),
          headers: const {
            'User-Agent':
                'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
            'Accept': 'text/html,application/xhtml+xml',
            'Referer': 'https://www.mangaread.org/',
          },
        )
        .timeout(const Duration(seconds: 12));

    HtmlScraperUtils.checkResponseHealth(res, 'MangaRead');

    if (res.statusCode == 200) {
      final html = res.body;
      final pageRegex = RegExp(
        r'<div class="page-break[^>]*>[\s\S]*?(<img\b[^>]*>)',
        caseSensitive: false,
      );
      final matches = pageRegex.allMatches(html);

      final pages = <String>[];
      for (final m in matches) {
        final imgUrl = HtmlScraperUtils.extractImgFromTag(
          m.group(1)!,
          baseUrl: 'https://www.mangaread.org',
          referer: 'https://www.mangaread.org/',
        );
        if (imgUrl.isNotEmpty) {
          pages.add(imgUrl);
        }
      }

      if (pages.isNotEmpty) {
        return ChapterPages(
          chapterId: chapterId,
          pages: pages,
          dataSaver: pages,
        );
      }
    }
    throw Exception('Failed to load MangaRead chapter pages');
  }
}
