import 'package:http/http.dart' as http;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/scrapers/html_scraper_utils.dart';
import 'package:manga_reader/widgets/common.dart';

/// Direct high-speed scraper for MangaFox / FanFox (50,000+ manga)
class MangaFoxScraper {
  final http.Client Function() _clientProvider;
  final LruHttpCache? _cache;

  static const String _domain = 'fanfox.net';
  static const String _referer = 'https://fanfox.net/';
  static const String _userAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

  MangaFoxScraper({required this._clientProvider, this._cache});

  http.Client get _client => _clientProvider();

  Future<http.Response> _getCached(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final key = uri.toString();
    final reqHeaders = {
      'User-Agent': _userAgent,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Referer': _referer,
      ...?headers,
    };
    if (_cache != null) {
      return _cache.deduplicate(key, () async {
        return await _client.get(uri, headers: reqHeaders).timeout(timeout);
      });
    }
    return await _client.get(uri, headers: reqHeaders).timeout(timeout);
  }

  /// Search or browse popular/latest manga from MangaFox catalog
  Future<List<MangaItem>> search({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
  }) async {
    final String url;
    if (query != null && query.trim().isNotEmpty) {
      url = 'https://$_domain/search?title=${Uri.encodeComponent(query.trim())}&page=$page';
    } else {
      url = page <= 1 ? 'https://$_domain/directory/' : 'https://$_domain/directory/$page.html';
    }

    final res = await _getCached(Uri.parse(url));
    HtmlScraperUtils.checkResponseHealth(res, 'MangaFox');

    if (res.statusCode == 200) {
      final html = res.body;
      final items = <MangaItem>[];
      final seen = <String>{};

      final cardRegex = RegExp(
        r'<li[^>]*>[\s\S]*?<a\s+href="(/manga/[^"]+/)"\s+title="([^"]+)"[\s\S]*?<img[^>]+src="([^"]+)"',
        caseSensitive: false,
      );

      for (final m in cardRegex.allMatches(html)) {
        final path = m.group(1)?.trim() ?? '';
        final title = HtmlScraperUtils.unescapeHtml(m.group(2)?.trim() ?? '');
        var cover = m.group(3)?.trim() ?? '';
        if (cover.startsWith('//')) cover = 'https:$cover';

        final slug = _extractSlug(path);
        if (slug.isEmpty || !seen.add(slug)) continue;

        items.add(
          MangaItem(
            id: 'fox:$slug',
            title: title.isNotEmpty ? title : 'Untitled',
            cover: cover,
            type: type ?? (slug.contains('manhwa') ? 'manhwa' : (slug.contains('manhua') ? 'manhua' : 'manga')),
            source: 'mangafox',
          ),
        );
        if (items.length >= limit) return items;
      }

      // Secondary fallback regex if directory list markup differs
      if (items.isEmpty) {
        final altRegex = RegExp(
          r'<a\s+href="(/manga/[^"]+/)"\s+title="([^"]+)"',
          caseSensitive: false,
        );
        for (final m in altRegex.allMatches(html)) {
          final path = m.group(1)?.trim() ?? '';
          final title = HtmlScraperUtils.unescapeHtml(m.group(2)?.trim() ?? '');
          final slug = _extractSlug(path);
          if (slug.isEmpty || !seen.add(slug)) continue;

          items.add(
            MangaItem(
              id: 'fox:$slug',
              title: title.isNotEmpty ? title : 'Untitled',
              cover: '',
              type: type ?? 'manga',
              source: 'mangafox',
            ),
          );
          if (items.length >= limit) return items;
        }
      }

      return items;
    }

    return [];
  }

  /// Load manga metadata, authors, genres, and cover
  Future<MangaItem> getManga(String id) async {
    final cleanId = id.startsWith('fox:') ? id.substring(4) : id;
    final mangaUrl = 'https://$_domain/manga/$cleanId/';

    final res = await _getCached(Uri.parse(mangaUrl));
    HtmlScraperUtils.checkResponseHealth(res, 'MangaFox');

    if (res.statusCode == 200) {
      final html = res.body;

      // Title
      final titleMatch = RegExp(r'<span class="detail-info-right-title-font">([^<]+)</span>', caseSensitive: false)
              .firstMatch(html) ??
          RegExp(r'<h1[^>]*>([^<]+)</h1>', caseSensitive: false).firstMatch(html);
      final title = HtmlScraperUtils.unescapeHtml(titleMatch?.group(1)?.trim() ?? 'Untitled');

      // Cover
      final imgMatch = RegExp(r'<img[^>]+class="detail-info-cover-img"[^>]+src="([^"]+)"', caseSensitive: false)
              .firstMatch(html) ??
          RegExp(r'<div class="detail-info-cover">\s*<img[^>]+src="([^"]+)"', caseSensitive: false).firstMatch(html);
      var cover = imgMatch?.group(1)?.trim() ?? '';
      if (cover.startsWith('//')) cover = 'https:$cover';

      // Description
      final descMatch = RegExp(r'<p class="fullcontent"[^>]*>([\s\S]*?)</p>', caseSensitive: false).firstMatch(html) ??
          RegExp(r'<p class="detail-info-right-content"[^>]*>([\s\S]*?)</p>', caseSensitive: false).firstMatch(html);
      final rawDesc = descMatch?.group(1) ?? '';
      final desc = rawDesc.replaceAll(RegExp(r'<[^>]*>'), '').trim();

      // Status
      final statusMatch = RegExp(r'<span class="detail-info-right-title-tip">([^<]+)</span>', caseSensitive: false)
          .firstMatch(html);
      final status = statusMatch?.group(1)?.trim().toLowerCase().contains('completed') == true ? 'Completed' : 'Ongoing';

      // Authors
      final authorMatch = RegExp(r'<p class="detail-info-right-say">\s*Author\(s\):([\s\S]*?)</p>', caseSensitive: false)
          .firstMatch(html);
      final authors = <String>[];
      if (authorMatch != null) {
        for (final a in RegExp(r'<a[^>]*>([^<]+)</a>', caseSensitive: false).allMatches(authorMatch.group(1) ?? '')) {
          final name = a.group(1)?.trim();
          if (name != null && name.isNotEmpty) authors.add(name);
        }
      }

      // Genres
      final genreMatch = RegExp(r'<p class="detail-info-right-tag-list">([\s\S]*?)</p>', caseSensitive: false)
          .firstMatch(html);
      final genres = <String>[];
      if (genreMatch != null) {
        for (final g in RegExp(r'<a[^>]*>([^<]+)</a>', caseSensitive: false).allMatches(genreMatch.group(1) ?? '')) {
          final tag = g.group(1)?.trim();
          if (tag != null && tag.isNotEmpty) genres.add(tag);
        }
      }

      final isManhwa = genres.any((g) => g.toLowerCase() == 'manhwa');
      final isManhua = genres.any((g) => g.toLowerCase() == 'manhua');

      return MangaItem(
        id: 'fox:$cleanId',
        title: title,
        cover: cover,
        description: desc,
        status: status,
        authors: authors,
        tags: genres,
        type: isManhwa ? 'manhwa' : (isManhua ? 'manhua' : 'manga'),
        source: 'mangafox',
      );
    }

    throw Exception('Failed to load MangaFox details for $id (HTTP ${res.statusCode})');
  }

  /// Load chapter list for a manga
  Future<List<ChapterItem>> getChapters(String id) async {
    final cleanId = id.startsWith('fox:') ? id.substring(4) : id;
    final mangaUrl = 'https://$_domain/manga/$cleanId/';

    final res = await _getCached(Uri.parse(mangaUrl));
    HtmlScraperUtils.checkResponseHealth(res, 'MangaFox');

    if (res.statusCode == 200) {
      final html = res.body;
      final chapters = <ChapterItem>[];
      final seen = <String>{};

      final chapterRegex = RegExp(
        r'<a\s+href="(/manga/[^"]+/([^"/]+/[^"/]+\.html))"[^>]*title="([^"]+)"',
        caseSensitive: false,
      );

      for (final m in chapterRegex.allMatches(html)) {
        final path = m.group(1)?.trim() ?? '';
        final chSlug = m.group(2)?.trim() ?? '';
        final chapterName = HtmlScraperUtils.unescapeHtml(m.group(3)?.trim() ?? '');

        if (chSlug.isEmpty || !seen.add(chSlug)) continue;

        final numMatch = RegExp(r'(?:chapter|ch\.?)\s*([\d.]+)|\b(\d+(?:\.\d+)?)\b', caseSensitive: false)
            .firstMatch(chapterName);
        final chNumber = numMatch?.group(1) ?? numMatch?.group(2);

        // Encode chapter slug in ID
        final cleanChKey = Uri.encodeComponent(path);

        chapters.add(
          ChapterItem(
            id: 'fox:$cleanId:$cleanChKey',
            title: chapterName,
            number: chNumber,
            source: 'mangafox',
          ),
        );
      }

      return chapters;
    }

    return [];
  }

  /// Load image URLs for a chapter reader
  Future<ChapterPages> getChapterPages(String chapterId) async {
    // chapterId format: fox:manga-slug:encoded-chapter-path
    final parts = chapterId.split(':');
    final String pathPart;
    if (parts.length >= 3) {
      pathPart = Uri.decodeComponent(parts.sublist(2).join(':'));
    } else if (parts.length == 2) {
      pathPart = Uri.decodeComponent(parts[1]);
    } else {
      pathPart = chapterId;
    }

    final String chapterUrl;
    if (pathPart.startsWith('http')) {
      chapterUrl = pathPart;
    } else if (pathPart.startsWith('/')) {
      chapterUrl = 'https://$_domain$pathPart';
    } else {
      chapterUrl = 'https://$_domain/manga/$pathPart';
    }

    final res = await _getCached(Uri.parse(chapterUrl));
    HtmlScraperUtils.checkResponseHealth(res, 'MangaFox');

    if (res.statusCode == 200) {
      final html = res.body;

      // Extract total page count from reader dropdown / script: var imagecount=21;
      final countMatch = RegExp(r'var\s+imagecount\s*=\s*(\d+)', caseSensitive: false).firstMatch(html);
      final count = countMatch != null ? int.tryParse(countMatch.group(1)!) ?? 0 : 0;

      // Extract base chapter path
      final baseUri = Uri.parse(chapterUrl);
      final baseSegments = baseUri.pathSegments.where((s) => s.isNotEmpty).toList();
      baseSegments.removeLast(); // remove '1.html'
      final basePath = baseSegments.join('/');

      // Extract first page image URL
      final firstImgMatch = RegExp(r'<img[^>]+class="reader-main-img"[^>]+src="([^"]+)"', caseSensitive: false)
              .firstMatch(html) ??
          RegExp(r'<img[^>]+id="image"[^>]+src="([^"]+)"', caseSensitive: false).firstMatch(html);

      final pages = <String>[];
      if (firstImgMatch != null) {
        var firstUrl = firstImgMatch.group(1)!.trim();
        if (firstUrl.startsWith('//')) firstUrl = 'https:$firstUrl';
        pages.add(firstUrl);

        // If we know the pattern and total count, generate predictable page URLs
        if (count > 1 && firstUrl.contains('/1.')) {
          final extIdx = firstUrl.lastIndexOf('.');
          final prefix = firstUrl.substring(0, firstUrl.lastIndexOf('/1.') + 1);
          final ext = extIdx != -1 ? firstUrl.substring(extIdx) : '.jpg';

          for (var p = 2; p <= count; p++) {
            pages.add('$prefix$p$ext');
          }
        }
      }

      if (pages.isNotEmpty) {
        ImageReferers.registerAll(pages, _referer);
        return ChapterPages(
          chapterId: chapterId,
          pages: pages,
          dataSaver: pages,
        );
      }
    }

    throw Exception('Failed to extract chapter pages for $chapterId');
  }

  String _extractSlug(String path) {
    final clean = path.replaceAll(RegExp(r'^/manga/|/$'), '');
    return clean;
  }
}
