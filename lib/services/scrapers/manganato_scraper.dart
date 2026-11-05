import 'package:http/http.dart' as http;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/scrapers/html_scraper_utils.dart';
import 'package:manga_reader/widgets/common.dart';

/// Direct high-speed scraper for MangaNato / MangaKakalot / Manganelo archive (80,000+ manga)
class MangaNatoScraper {
  final http.Client Function() _clientProvider;
  final LruHttpCache? _cache;

  static const String _domain = 'manganato.com';
  static const String _readerDomain = 'chapmanganato.to';
  static const String _referer = 'https://chapmanganato.to/';
  static const String _userAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

  MangaNatoScraper({required this._clientProvider, this._cache});

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

  /// Search or browse popular/latest manga from MangaNato's catalog
  Future<List<MangaItem>> search({
    String? query,
    String? type,
    String order = 'popular',
    int page = 1,
    int limit = 24,
  }) async {
    final String url;
    if (query != null && query.trim().isNotEmpty) {
      final sanitized = query.trim().replaceAll(RegExp(r'\s+'), '_');
      url = 'https://$_domain/search/story/${Uri.encodeComponent(sanitized)}?page=$page';
    } else {
      final typeParam = order == 'latest' ? 'newest' : 'topview';
      if (type == 'manhwa') {
        url = 'https://$_domain/genre-44/$page?type=$typeParam';
      } else if (type == 'manhua') {
        url = 'https://$_domain/genre-43/$page?type=$typeParam';
      } else {
        url = 'https://$_domain/genre-all/$page?type=$typeParam';
      }
    }

    final res = await _getCached(Uri.parse(url));
    HtmlScraperUtils.checkResponseHealth(res, 'MangaNato');

    if (res.statusCode == 200) {
      final html = res.body;
      final items = <MangaItem>[];
      final seen = <String>{};

      // 1. Search card format
      final searchCardRegex = RegExp(
        r'<div class="search-story-item"[^>]*>[\s\S]*?<a class="item-img"[^>]*href="([^"]+)"[^>]*>([\s\S]*?<img\b[^>]*>)[\s\S]*?<a class="item-title"[^>]*>([^<]+)</a>',
        caseSensitive: false,
      );

      for (final m in searchCardRegex.allMatches(html)) {
        final mangaUrl = m.group(1)?.trim() ?? '';
        final imgBlock = m.group(2) ?? '';
        final title = HtmlScraperUtils.unescapeHtml(m.group(3)?.trim() ?? '');

        final imgTag = RegExp(r'<img\b[^>]*>', caseSensitive: false).firstMatch(imgBlock)?.group(0) ?? imgBlock;
        final cover = HtmlScraperUtils.extractImgFromTag(imgTag, baseUrl: 'https://$_domain', referer: _referer);
        final id = _extractIdFromUrl(mangaUrl);
        if (id.isEmpty || !seen.add(id)) continue;

        items.add(
          MangaItem(
            id: 'nato:$id',
            title: title.isNotEmpty ? title : 'Untitled',
            cover: cover,
            type: type ?? (mangaUrl.contains('manhwa') ? 'manhwa' : (mangaUrl.contains('manhua') ? 'manhua' : 'manga')),
            source: 'manganato',
          ),
        );
        if (items.length >= limit) return items;
      }

      // 2. Genre / Browse card format
      final genreCardRegex = RegExp(
        r'<div class="content-genres-item"[^>]*>[\s\S]*?<a class="genres-item-img"[^>]*href="([^"]+)"[^>]*>([\s\S]*?<img\b[^>]*>)[\s\S]*?<a class="genres-item-name"[^>]*>([^<]+)</a>',
        caseSensitive: false,
      );

      for (final m in genreCardRegex.allMatches(html)) {
        final mangaUrl = m.group(1)?.trim() ?? '';
        final imgBlock = m.group(2) ?? '';
        final title = HtmlScraperUtils.unescapeHtml(m.group(3)?.trim() ?? '');

        final imgTag = RegExp(r'<img\b[^>]*>', caseSensitive: false).firstMatch(imgBlock)?.group(0) ?? imgBlock;
        final cover = HtmlScraperUtils.extractImgFromTag(imgTag, baseUrl: 'https://$_domain', referer: _referer);
        final id = _extractIdFromUrl(mangaUrl);
        if (id.isEmpty || !seen.add(id)) continue;

        items.add(
          MangaItem(
            id: 'nato:$id',
            title: title.isNotEmpty ? title : 'Untitled',
            cover: cover,
            type: type ?? (mangaUrl.contains('manhwa') ? 'manhwa' : (mangaUrl.contains('manhua') ? 'manhua' : 'manga')),
            source: 'manganato',
          ),
        );
        if (items.length >= limit) return items;
      }

      return items;
    }

    return [];
  }

  /// Load manga metadata, authors, genres, and cover
  Future<MangaItem> getManga(String id) async {
    final cleanId = id.startsWith('nato:') ? id.substring(5) : id;
    final mangaUrl = _buildMangaUrl(cleanId);

    final res = await _getCached(Uri.parse(mangaUrl));
    HtmlScraperUtils.checkResponseHealth(res, 'MangaNato');

    if (res.statusCode == 200) {
      final html = res.body;

      // Title
      final titleMatch = RegExp(r'<h1>([^<]+)</h1>', caseSensitive: false).firstMatch(html) ??
          RegExp(r'<h1 class="entry-title">([^<]+)</h1>', caseSensitive: false).firstMatch(html);
      final title = HtmlScraperUtils.unescapeHtml(titleMatch?.group(1)?.trim() ?? 'Untitled');

      // Cover
      final imgMatch = RegExp(r'<span class="info-image-img">\s*<img\b[^>]*>', caseSensitive: false).firstMatch(html) ??
          RegExp(r'<div class="story-info-left">\s*<span[^>]*>\s*<img\b[^>]*>', caseSensitive: false).firstMatch(html);
      final cover = imgMatch != null
          ? HtmlScraperUtils.extractImgFromTag(imgMatch.group(0)!, baseUrl: 'https://$_domain', referer: _referer)
          : '';

      // Description
      final descMatch = RegExp(r'<div class="panel-story-info-description"[^>]*>([\s\S]*?)</div>', caseSensitive: false)
          .firstMatch(html);
      final rawDesc = descMatch?.group(1) ?? '';
      final desc = rawDesc.replaceAll(RegExp(r'<[^>]*>'), '').trim();

      // Status
      final statusMatch = RegExp(r'<td class="table-label">Status\s*:</td>\s*<td class="table-value">([^<]+)</td>', caseSensitive: false)
          .firstMatch(html);
      final status = statusMatch?.group(1)?.trim().toLowerCase() == 'completed' ? 'Completed' : 'Ongoing';

      // Authors
      final authorMatch = RegExp(r'<td class="table-label">Author\(s\)\s*:</td>\s*<td class="table-value">([\s\S]*?)</td>', caseSensitive: false)
          .firstMatch(html);
      final authors = <String>[];
      if (authorMatch != null) {
        for (final a in RegExp(r'<a[^>]*>([^<]+)</a>', caseSensitive: false).allMatches(authorMatch.group(1) ?? '')) {
          final name = a.group(1)?.trim();
          if (name != null && name.isNotEmpty && name != 'Updating') authors.add(name);
        }
      }

      // Genres
      final genreMatch = RegExp(r'<td class="table-label">Genres\s*:</td>\s*<td class="table-value">([\s\S]*?)</td>', caseSensitive: false)
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
        id: 'nato:$cleanId',
        title: title,
        cover: cover,
        description: desc,
        status: status,
        authors: authors,
        tags: genres,
        type: isManhwa ? 'manhwa' : (isManhua ? 'manhua' : 'manga'),
        source: 'manganato',
      );
    }

    throw Exception('Failed to load MangaNato details for $id (HTTP ${res.statusCode})');
  }

  /// Load chapter list for a manga
  Future<List<ChapterItem>> getChapters(String id) async {
    final cleanId = id.startsWith('nato:') ? id.substring(5) : id;
    final mangaUrl = _buildMangaUrl(cleanId);

    final res = await _getCached(Uri.parse(mangaUrl));
    HtmlScraperUtils.checkResponseHealth(res, 'MangaNato');

    if (res.statusCode == 200) {
      final html = res.body;
      final chapters = <ChapterItem>[];

      final chapterRegex = RegExp(
        r'<li class="a-h"[^>]*>[\s\S]*?<a class="chapter-name[^"]*" href="([^"]+)"[^>]*>([^<]+)</a>[\s\S]*?<span class="chapter-time[^"]*"[^>]*>([^<]*)</span>',
        caseSensitive: false,
      );

      for (final m in chapterRegex.allMatches(html)) {
        final chapterUrl = m.group(1)?.trim() ?? '';
        final chapterName = HtmlScraperUtils.unescapeHtml(m.group(2)?.trim() ?? '');
        final dateStr = m.group(3)?.trim() ?? '';

        final chId = _extractChapterIdFromUrl(chapterUrl);
        if (chId.isEmpty) continue;

        final numMatch = RegExp(r'(?:chapter|ch\.?)\s*([\d.]+)|\b(\d+(?:\.\d+)?)\b', caseSensitive: false)
            .firstMatch(chapterName);
        final chNumber = numMatch?.group(1) ?? numMatch?.group(2);

        chapters.add(
          ChapterItem(
            id: 'nato:$cleanId:$chId',
            title: chapterName,
            number: chNumber,
            publishAt: dateStr.isNotEmpty ? dateStr : null,
            source: 'manganato',
          ),
        );
      }

      return chapters;
    }

    return [];
  }

  /// Load image URLs for a chapter reader
  Future<ChapterPages> getChapterPages(String chapterId) async {
    // chapterId format: nato:manga-id:chapter-id
    final parts = chapterId.split(':');
    final String cleanMangaId;
    final String cleanChapterId;
    if (parts.length >= 3) {
      cleanMangaId = parts[1];
      cleanChapterId = parts[2];
    } else if (parts.length == 2) {
      cleanMangaId = parts[0] == 'nato' ? '' : parts[0];
      cleanChapterId = parts[1];
    } else {
      cleanMangaId = '';
      cleanChapterId = chapterId;
    }

    final chapterUrl = _buildChapterUrl(cleanMangaId, cleanChapterId);
    final res = await _getCached(Uri.parse(chapterUrl));
    HtmlScraperUtils.checkResponseHealth(res, 'MangaNato');

    if (res.statusCode == 200) {
      final html = res.body;
      final containerMatch = RegExp(
        r'<div class="container-chapter-reader"[^>]*>([\s\S]*?)</div>',
        caseSensitive: false,
      ).firstMatch(html);

      final block = containerMatch?.group(1) ?? html;
      final imgRegex = RegExp(r'<img\b[^>]+(?:src|data-src)="([^"]+)"', caseSensitive: false);
      final pages = <String>[];

      for (final m in imgRegex.allMatches(block)) {
        var u = m.group(1)?.trim() ?? '';
        if (u.isEmpty || u.contains('icon') || u.contains('logo')) continue;
        if (u.startsWith('//')) u = 'https:$u';
        pages.add(u);
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

  String _extractIdFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return '';
    final last = segments.last;
    return last;
  }

  String _extractChapterIdFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return '';
    return segments.last;
  }

  String _buildMangaUrl(String id) {
    if (id.startsWith('manga-')) {
      return 'https://$_readerDomain/$id';
    }
    return 'https://$_domain/$id';
  }

  String _buildChapterUrl(String mangaId, String chapterId) {
    if (mangaId.isNotEmpty) {
      return 'https://$_readerDomain/$mangaId/$chapterId';
    }
    return 'https://$_readerDomain/$chapterId';
  }
}
