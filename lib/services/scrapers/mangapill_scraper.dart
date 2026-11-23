import 'package:http/http.dart' as http;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/scrapers/html_scraper_utils.dart';

/// MangaPill HTML scraper backed by `package:html` standards-compliant DOM parsing.
class MangaPillScraper {
  final http.Client Function() _clientProvider;
  final LruHttpCache? _cache;

  MangaPillScraper({required this._clientProvider, this._cache});

  http.Client get _client => _clientProvider();

  static const _defaultHeaders = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
    'Accept': 'text/html',
    'Referer': 'https://mangapill.com/',
  };

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
    int page = 1,
    int limit = 24,
  }) async {
    if (type == 'manhwa' || type == 'manhua') {
      return [];
    }

    final String url = (query != null && query.trim().isNotEmpty)
        ? 'https://mangapill.com/search?q=${Uri.encodeComponent(query.trim())}&page=$page'
        : 'https://mangapill.com/mangas/new?page=$page';

    final res = await _getCached(
      Uri.parse(url),
      headers: _defaultHeaders,
      timeout: const Duration(seconds: 10),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaPill');

    if (res.statusCode == 200) {
      final doc = HtmlScraperUtils.parseDocument(res.body);
      final items = <MangaItem>[];
      final seen = <String>{};
      final hrefRe = RegExp(r'^/manga/(\d+)/([^/?#]+)');

      for (final a in doc.querySelectorAll('a[href^="/manga/"]')) {
        final href = a.attributes['href']?.trim() ?? '';
        final m = hrefRe.firstMatch(href);
        if (m == null) continue;
        final mId = m.group(1)!;
        final slug = m.group(2)!;
        final id = 'pill:$mId:$slug';

        final imgEl = a.querySelector('img');
        final cover = HtmlScraperUtils.extractImgFromElement(
          imgEl,
          baseUrl: 'https://mangapill.com',
          referer: 'https://mangapill.com/',
        );

        var title = a.querySelector('.font-black, .line-clamp-2')?.text.trim() ?? '';
        if (title.isEmpty) {
          title = imgEl?.attributes['alt']?.trim() ?? '';
        }
        if (title.isEmpty) {
          title = a.text.trim();
        }
        if (title.isEmpty) continue;
        if (!seen.add(id)) continue;

        items.add(
          MangaItem(
            id: id,
            title: HtmlScraperUtils.unescapeHtml(title),
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
      headers: _defaultHeaders,
      timeout: const Duration(seconds: 10),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaPill');

    if (res.statusCode == 200) {
      final doc = HtmlScraperUtils.parseDocument(res.body);
      final title =
          doc.querySelector('h1')?.text.trim() ?? slug.replaceAll('-', ' ');
      final desc = doc.querySelector('p.text-sm')?.text.trim() ?? '';

      var cover = HtmlScraperUtils.extractImgFromElement(
        doc.querySelector('figure img'),
        baseUrl: 'https://mangapill.com',
        referer: 'https://mangapill.com/',
      );
      if (cover.isEmpty) {
        final ogContent = doc
            .querySelector('meta[property="og:image"]')
            ?.attributes['content'];
        cover = HtmlScraperUtils.normalizeImgUrl(
          ogContent,
          baseUrl: 'https://mangapill.com',
          referer: 'https://mangapill.com/',
        );
      }

      final tags = doc
          .querySelectorAll('a[href^="/search?genre="]')
          .map((e) => HtmlScraperUtils.unescapeHtml(e.text.trim()))
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
      headers: _defaultHeaders,
      timeout: const Duration(seconds: 10),
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaPill');

    if (res.statusCode == 200) {
      final doc = HtmlScraperUtils.parseDocument(res.body);
      final hrefRe = RegExp(r'^/chapters/([0-9-]+)/([^/?#]+)');
      final numRe = RegExp(r'Chapter\s+([0-9.]+)', caseSensitive: false);
      final chapters = <ChapterItem>[];
      final seen = <String>{};

      for (final a in doc.querySelectorAll('a[href^="/chapters/"]')) {
        final href = a.attributes['href']?.trim() ?? '';
        final m = hrefRe.firstMatch(href);
        if (m == null) continue;
        final cId = m.group(1)!;
        final cSlug = m.group(2)!;
        final chId = 'pill:$cId:$cSlug';
        if (!seen.add(chId)) continue;

        final rawTitle = HtmlScraperUtils.unescapeHtml(a.text.trim());
        final num = numRe.firstMatch(rawTitle)?.group(1);

        chapters.add(
          ChapterItem(
            id: chId,
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
        .get(Uri.parse(url), headers: _defaultHeaders)
        .timeout(const Duration(seconds: 12));

    HtmlScraperUtils.checkResponseHealth(res, 'MangaPill');

    if (res.statusCode == 200) {
      final doc = HtmlScraperUtils.parseDocument(res.body);
      final pages = <String>[];
      for (final img in doc.querySelectorAll('img.js-page')) {
        final imgUrl = HtmlScraperUtils.extractImgFromElement(
          img,
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
