import 'package:http/http.dart' as http;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/scrapers/html_scraper_utils.dart';

class MangaKatanaScraper {
  final http.Client Function() _clientProvider;
  final LruHttpCache? _cache;

  MangaKatanaScraper({
    required this._clientProvider,
    this._cache,
  });

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
    final String url;
    if (query != null && query.trim().isNotEmpty) {
      url = 'https://mangakatana.com/page/$page?search=${Uri.encodeComponent(query.trim())}&search_by=book_name';
    } else if (type == 'manhwa') {
      url = 'https://mangakatana.com/genre/manhwa/page/$page';
    } else if (type == 'manhua') {
      url = 'https://mangakatana.com/genre/manhua/page/$page';
    } else {
      url = 'https://mangakatana.com/manga?filter=1&order=latest&page=$page';
    }

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://mangakatana.com/',
      },
      timeout: const Duration(seconds: 12),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaKatana');

    if (res.statusCode == 200) {
      final html = res.body;
      final bookListIdx = html.indexOf('id="book_list"');
      final sidebarIdx = bookListIdx >= 0 ? html.indexOf('id="hot_', bookListIdx) : -1;
      final listHtml = bookListIdx >= 0
          ? html.substring(bookListIdx, sidebarIdx > bookListIdx ? sidebarIdx : null)
          : html;

      final cardRegex = RegExp(
        r'<div class="item"[^>]*>[\s\S]*?<a href="(https://mangakatana\.com/manga/([^.]+)\.(\d+))"[^>]*>([\s\S]*?<img\b(?:"[^"]*"|' "'" r"[^']*'|[^'" '"' r'>])*>)[\s\S]*?<h3 class="title">\s*<a[^>]*>([^<]+)</a>',
        caseSensitive: false,
      );

      var matches = cardRegex.allMatches(listHtml).toList();
      if (matches.isEmpty && bookListIdx >= 0) {
        matches = cardRegex.allMatches(html).toList();
      }
      final items = <MangaItem>[];
      final seen = <String>{};

      for (final m in matches) {
        final slug = m.group(2)!;
        final mId = m.group(3)!;
        final imgBlock = m.group(4)!;
        final imgTag = RegExp(
              r'<img\b(?:"[^"]*"|' "'" r"[^']*'|[^'" '"' r'>])*>',
              caseSensitive: false,
            ).firstMatch(imgBlock)?.group(0) ??
            imgBlock;
        final cover = HtmlScraperUtils.extractImgFromTag(
          imgTag,
          baseUrl: 'https://mangakatana.com',
          referer: 'https://mangakatana.com/',
        );
        if (cover.isEmpty) continue;
        final title = HtmlScraperUtils.unescapeHtml(m.group(5)!.trim());

        final id = 'katana:$slug:$mId';
        if (!seen.add(id)) continue;

        items.add(MangaItem(
          id: id,
          title: title,
          cover: cover,
          type: type ?? (url.contains('manhwa') ? 'manhwa' : (url.contains('manhua') ? 'manhua' : 'manga')),
          source: 'mangakatana',
        ));
        if (items.length >= limit) break;
      }

      if (items.isNotEmpty) return items;

      // Handle redirect to manga detail page
      final canonicalMatch = RegExp(
        r'<link\s+rel="canonical"\s+href="https://mangakatana\.com/manga/([^.]+)\.(\d+)"',
        caseSensitive: false,
      ).firstMatch(html) ??
          RegExp(
            r'<meta\s+property="og:url"\s+content="https://mangakatana\.com/manga/([^.]+)\.(\d+)"',
            caseSensitive: false,
          ).firstMatch(html);

      if (canonicalMatch != null) {
        final slug = canonicalMatch.group(1)!;
        final mId = canonicalMatch.group(2)!;
        final titleMatch = RegExp(r'<h1 class="heading">\s*([^<]+)\s*</h1>', caseSensitive: false).firstMatch(html) ??
            RegExp(r'<meta\s+property="og:title"\s+content="([^"]+)"', caseSensitive: false).firstMatch(html);
        final title = HtmlScraperUtils.unescapeHtml(
            titleMatch?.group(1)?.trim() ?? query?.trim() ?? slug.replaceAll('-', ' '));

        final coverDivMatch = RegExp(r'<div class="cover"[^>]*>[\s\S]*?(<img\b[^>]*>)', caseSensitive: false)
            .firstMatch(html);
        var cover = coverDivMatch != null
            ? HtmlScraperUtils.extractImgFromTag(
                coverDivMatch.group(1)!,
                baseUrl: 'https://mangakatana.com',
                referer: 'https://mangakatana.com/',
              )
            : '';
        if (cover.isEmpty) {
          final ogMatch = RegExp(r'<meta\s+property="og:image"\s+content="([^"]+)"', caseSensitive: false)
              .firstMatch(html);
          cover = HtmlScraperUtils.normalizeImgUrl(ogMatch?.group(1),
              baseUrl: 'https://mangakatana.com', referer: 'https://mangakatana.com/');
        }

        items.add(MangaItem(
          id: 'katana:$slug:$mId',
          title: title,
          cover: cover,
          type: type ?? 'manga',
          source: 'mangakatana',
        ));
      }

      return items;
    }
    return [];
  }

  Future<MangaItem> getManga(String id) async {
    final parts = id.split(':');
    final slug = parts.length > 1 ? parts[1] : '';
    final mId = parts.length > 2 ? parts[2] : '';
    final url = 'https://mangakatana.com/manga/$slug.$mId';

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://mangakatana.com/',
      },
      timeout: const Duration(seconds: 12),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaKatana');

    if (res.statusCode == 200) {
      final html = res.body;
      final titleMatch = RegExp(r'<h1 class="heading">([^<]+)</h1>').firstMatch(html);
      final title = HtmlScraperUtils.unescapeHtml(titleMatch?.group(1)?.trim() ?? slug.replaceAll('-', ' '));

      final descMatch = RegExp(r'<div class="summary">[\s\S]*?<p>([\s\S]*?)</p>').firstMatch(html);
      final desc = HtmlScraperUtils.unescapeHtml(descMatch?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '');

      final coverDivMatch = RegExp(r'<div class="cover"[^>]*>[\s\S]*?(<img\b[^>]*>)', caseSensitive: false)
          .firstMatch(html);
      var cover = coverDivMatch != null
          ? HtmlScraperUtils.extractImgFromTag(
              coverDivMatch.group(1)!,
              baseUrl: 'https://mangakatana.com',
              referer: 'https://mangakatana.com/',
            )
          : '';
      if (cover.isEmpty) {
        final ogMatch = RegExp(r'<meta\s+property="og:image"\s+content="([^"]+)"', caseSensitive: false)
            .firstMatch(html);
        cover = HtmlScraperUtils.normalizeImgUrl(ogMatch?.group(1),
            baseUrl: 'https://mangakatana.com', referer: 'https://mangakatana.com/');
      }

      final authorMatches = RegExp(r'<a class="author"[^>]*>([^<]+)</a>').allMatches(html);
      final authors = authorMatches.map((m) => HtmlScraperUtils.unescapeHtml(m.group(1)!.trim())).toList();

      final genreBlock = RegExp(r'<div class="genres">([\s\S]*?)</div>').firstMatch(html)?.group(1) ?? '';
      final tags = RegExp(r'<a[^>]*>([^<]+)</a>')
          .allMatches(genreBlock)
          .map((m) => HtmlScraperUtils.unescapeHtml(m.group(1)!.trim()))
          .where((s) => s.isNotEmpty)
          .toList();

      final status = html.contains('status completed') ? 'completed' : 'ongoing';

      return MangaItem(
        id: id,
        title: title,
        description: desc,
        cover: cover,
        authors: authors,
        status: status,
        tags: tags,
        source: 'mangakatana',
      );
    }
    throw Exception('Failed to load MangaKatana manga details');
  }

  Future<List<ChapterItem>> getChapters(String mangaId) async {
    final parts = mangaId.split(':');
    final slug = parts.length > 1 ? parts[1] : '';
    final mId = parts.length > 2 ? parts[2] : '';
    final url = 'https://mangakatana.com/manga/$slug.$mId';

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://mangakatana.com/',
      },
      timeout: const Duration(seconds: 12),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaKatana');

    if (res.statusCode == 200) {
      final html = res.body;
      final chapterRegex = RegExp(
        r'<div class="chapter">\s*<a href="https://mangakatana\.com/manga/[^/]+/c([^"]+)"[^>]*>([^<]+)</a>',
        caseSensitive: false,
      );

      final matches = chapterRegex.allMatches(html);
      final chapters = <ChapterItem>[];

      for (final m in matches) {
        final cNum = m.group(1)!;
        final rawTitle = HtmlScraperUtils.unescapeHtml(m.group(2)!.trim());

        chapters.add(ChapterItem(
          id: 'katana:$slug:$mId:c$cNum',
          title: rawTitle,
          number: cNum,
          group: 'MangaKatana',
          source: 'mangakatana',
        ));
      }
      return chapters;
    }
    return [];
  }

  Future<ChapterPages> getChapterPages(String chapterId) async {
    final parts = chapterId.split(':');
    final slug = parts.length > 1 ? parts[1] : '';
    final mId = parts.length > 2 ? parts[2] : '';
    final cPart = parts.length > 3 ? parts[3] : '';
    final url = 'https://mangakatana.com/manga/$slug.$mId/$cPart';

    final res = await _client.get(
      Uri.parse(url),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': 'https://mangakatana.com/',
      },
    ).timeout(const Duration(seconds: 12));

    HtmlScraperUtils.checkResponseHealth(res, 'MangaKatana');

    if (res.statusCode == 200) {
      final html = res.body;
      final arrayMatch = RegExp(r'var\s+thzq\s*=\s*\[([^\]]+)\]').firstMatch(html) ??
          RegExp(r'var\s+ytaw\s*=\s*\[([^\]]+)\]').firstMatch(html);

      if (arrayMatch != null) {
        final content = arrayMatch.group(1)!;
        final urlMatches = RegExp(r'''['"]((?:https?:)?//[^'"]+)['"]''').allMatches(content);
        final pages = <String>[];
        for (final m in urlMatches) {
          final pUrl = HtmlScraperUtils.normalizeImgUrl(
            m.group(1),
            baseUrl: 'https://mangakatana.com',
            referer: 'https://mangakatana.com/',
          );
          if (pUrl.isNotEmpty) pages.add(pUrl);
        }

        if (pages.isNotEmpty) {
          return ChapterPages(chapterId: chapterId, pages: pages, dataSaver: pages);
        }
      }
    }
    throw Exception('Failed to load MangaKatana chapter pages');
  }
}
