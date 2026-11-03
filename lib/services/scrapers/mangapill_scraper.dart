import 'package:http/http.dart' as http;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/scrapers/html_scraper_utils.dart';

class MangaPillScraper {
  final http.Client Function() _clientProvider;
  final LruHttpCache? _cache;

  MangaPillScraper({required this._clientProvider, this._cache});

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
    int page = 1,
    int limit = 24,
  }) async {
    if (type == 'manhwa' || type == 'manhua') {
      return [];
    }

    final String url;
    if (query != null && query.trim().isNotEmpty) {
      url =
          'https://mangapill.com/search?q=${Uri.encodeComponent(query.trim())}&page=$page';
    } else {
      url = 'https://mangapill.com/mangas/new?page=$page';
    }

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'Referer': 'https://mangapill.com/',
      },
      timeout: const Duration(seconds: 10),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaPill');

    if (res.statusCode == 200) {
      final html = res.body;
      final cardRegex = RegExp(
        r'<a\s+href="/manga/(\d+)/([^"]+)"[^>]*>([\s\S]*?<img\b[^>]*>)[\s\S]*?<div class="mt-3 font-black leading-tight line-clamp-2">([^<]+)</div>',
        caseSensitive: false,
      );

      final matches = cardRegex.allMatches(html);
      final items = <MangaItem>[];
      final seen = <String>{};

      for (final m in matches) {
        final mId = m.group(1)!;
        final slug = m.group(2)!;
        final imgSub = m.group(3)!;
        final imgTag =
            RegExp(
              r'<img\b[^>]*>',
              caseSensitive: false,
            ).firstMatch(imgSub)?.group(0) ??
            '';
        final cover = HtmlScraperUtils.extractImgFromTag(
          imgTag,
          baseUrl: 'https://mangapill.com',
          referer: 'https://mangapill.com/',
        );
        final title = HtmlScraperUtils.unescapeHtml(m.group(4)!.trim());

        final id = 'pill:$mId:$slug';
        if (!seen.add(id)) continue;

        items.add(
          MangaItem(
            id: id,
            title: title,
            cover: cover,
            type: 'manga',
            source: 'mangapill',
          ),
        );
        if (items.length >= limit) break;
      }
      return items;
    }
    return [];
  }

  Future<MangaItem> getManga(String id) async {
    final parts = id.split(':');
    final mId = parts.length > 1 ? parts[1] : '';
    final slug = parts.length > 2 ? parts[2] : '';
    final url = 'https://mangapill.com/manga/$mId/$slug';

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'Referer': 'https://mangapill.com/',
      },
      timeout: const Duration(seconds: 10),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaPill');

    if (res.statusCode == 200) {
      final html = res.body;
      final titleMatch = RegExp(r'<h1[^>]*>([^<]+)</h1>').firstMatch(html);
      final title = titleMatch?.group(1)?.trim() ?? slug.replaceAll('-', ' ');

      final descMatch = RegExp(
        r'<p class="text-sm[^"]*">([\s\S]*?)</p>',
      ).firstMatch(html);
      final desc =
          descMatch?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '';

      final figImgMatch = RegExp(
        r'<figure[^>]*>[\s\S]*?(<img\b[^>]*>)',
        caseSensitive: false,
      ).firstMatch(html);
      var cover = figImgMatch != null
          ? HtmlScraperUtils.extractImgFromTag(
              figImgMatch.group(1)!,
              baseUrl: 'https://mangapill.com',
              referer: 'https://mangapill.com/',
            )
          : '';
      if (cover.isEmpty) {
        final ogMatch = RegExp(
          r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"',
          caseSensitive: false,
        ).firstMatch(html);
        cover = HtmlScraperUtils.normalizeImgUrl(
          ogMatch?.group(1),
          baseUrl: 'https://mangapill.com',
          referer: 'https://mangapill.com/',
        );
      }

      final tags =
          RegExp(
                r'<a[^>]+href="/search\?genre=[^"]+"[^>]*>([^<]+)</a>',
                caseSensitive: false,
              )
              .allMatches(html)
              .map((m) => HtmlScraperUtils.unescapeHtml(m.group(1)!.trim()))
              .where((s) => s.isNotEmpty)
              .toSet()
              .toList();

      return MangaItem(
        id: id,
        title: HtmlScraperUtils.unescapeHtml(title),
        description: HtmlScraperUtils.unescapeHtml(desc),
        cover: cover,
        tags: tags,
        source: 'mangapill',
      );
    }
    throw Exception('Failed to load MangaPill manga details');
  }

  Future<List<ChapterItem>> getChapters(String mangaId) async {
    final parts = mangaId.split(':');
    final mId = parts.length > 1 ? parts[1] : '';
    final slug = parts.length > 2 ? parts[2] : '';
    final url = 'https://mangapill.com/manga/$mId/$slug';

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html',
        'Referer': 'https://mangapill.com/',
      },
      timeout: const Duration(seconds: 10),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaPill');

    if (res.statusCode == 200) {
      final html = res.body;
      final chapterRegex = RegExp(
        r'<a[^>]+href="/chapters/([0-9-]+)/([^"]+)"[^>]*>([^<]+)</a>',
        caseSensitive: false,
      );

      final matches = chapterRegex.allMatches(html);
      final chapters = <ChapterItem>[];

      for (final m in matches) {
        final cId = m.group(1)!;
        final cSlug = m.group(2)!;
        final rawTitle = HtmlScraperUtils.unescapeHtml(m.group(3)!.trim());

        final numMatch = RegExp(
          r'Chapter\s+([0-9.]+)',
          caseSensitive: false,
        ).firstMatch(rawTitle);
        final num = numMatch?.group(1);

        chapters.add(
          ChapterItem(
            id: 'pill:$cId:$cSlug',
            title: rawTitle,
            number: num,
            group: 'MangaPill',
            source: 'mangapill',
          ),
        );
      }
      return chapters;
    }
    return [];
  }

  Future<ChapterPages> getChapterPages(String chapterId) async {
    final parts = chapterId.split(':');
    final cId = parts.length > 1 ? parts[1] : '';
    final cSlug = parts.length > 2 ? parts[2] : '';
    final url = 'https://mangapill.com/chapters/$cId/$cSlug';

    final res = await _client
        .get(
          Uri.parse(url),
          headers: const {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
            'Accept': 'text/html',
            'Referer': 'https://mangapill.com/',
          },
        )
        .timeout(const Duration(seconds: 12));

    HtmlScraperUtils.checkResponseHealth(res, 'MangaPill');

    if (res.statusCode == 200) {
      final html = res.body;
      final pageTagRegex = RegExp(
        r'<img\b[^>]*class="[^"]*js-page[^"]*"[^>]*>',
        caseSensitive: false,
      );
      final matches = pageTagRegex.allMatches(html);

      final pages = <String>[];
      for (final m in matches) {
        final imgUrl = HtmlScraperUtils.extractImgFromTag(
          m.group(0)!,
          baseUrl: 'https://mangapill.com',
          referer: 'https://mangapill.com/',
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
    throw Exception('Failed to load MangaPill chapter pages');
  }
}
