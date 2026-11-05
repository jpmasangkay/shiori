import 'package:http/http.dart' as http;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/scrapers/html_scraper_utils.dart';
import 'package:manga_reader/widgets/common.dart';

class MangaDemonScraper {
  final http.Client Function() clientProvider;
  final LruHttpCache? cache;

  static const String _domain = 'demonicscans.org';
  static const String _referer = 'https://demonicscans.org/';

  MangaDemonScraper({required this.clientProvider, this.cache});

  http.Client get _client => clientProvider();

  Future<http.Response> _getCached(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final key = uri.toString();
    final c = cache;
    if (c != null) {
      return c.deduplicate(key, () async {
        return await _client.get(uri, headers: headers).timeout(timeout);
      });
    }
    return await _client.get(uri, headers: headers).timeout(timeout);
  }

  /// Browse catalog or search manga
  Future<List<MangaItem>> search({
    String? query,
    String? type,
    int page = 1,
    int limit = 24,
  }) async {
    final String url;
    if (query != null && query.trim().isNotEmpty) {
      url = 'https://$_domain/search.php?manga=${Uri.encodeComponent(query.trim())}';
    } else {
      url = 'https://$_domain/lastupdates.php';
    }

    final res = await _getCached(
      Uri.parse(url),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml',
        'Referer': _referer,
      },
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaDemon');

    if (res.statusCode == 200) {
      final html = res.body;
      final items = <MangaItem>[];
      final seen = <String>{};

      // Search results format: <a href="/manga/Martial-Peak"...>
      // Latest updates format: <a href="/manga/Memory-in-the-Maze"...>
      final mangaRegex = RegExp(
        r'<a[^>]+href="(?:\/)?manga\/([^"/?#]+)"[^>]*>([\s\S]*?)<\/a>',
        caseSensitive: false,
      );

      for (final m in mangaRegex.allMatches(html)) {
        final slug = m.group(1)?.trim() ?? '';
        if (slug.isEmpty) continue;

        final rawText = m.group(2) ?? '';
        var title = HtmlScraperUtils.unescapeHtml(
          rawText.replaceAll(RegExp(r'<[^>]+>'), '').trim().split('\n').first.trim(),
        );

        String cover = '';
        final imgMatch = RegExp(r'src="([^"]+)"', caseSensitive: false).firstMatch(rawText);
        if (imgMatch != null) {
          cover = imgMatch.group(1)!.trim();
          if (cover.startsWith('/')) cover = 'https://$_domain$cover';
        }

        if (title.isEmpty) {
          final altMatch = RegExp(r'(?:title|alt)="([^";]+)', caseSensitive: false).firstMatch(rawText);
          if (altMatch != null) {
            title = HtmlScraperUtils.unescapeHtml(altMatch.group(1)!.trim());
          }
        }
        if (title.isEmpty) {
          title = slug.replaceAll('-', ' ');
        }

        if (!seen.add(slug)) continue;
        if (title.isEmpty || title.length > 120 || title == 'HOME') continue;

        if (cover.isEmpty) {
          final cleanTitle = slug.replaceAll('-', ' ');
          cover = 'https://readermc.org/images/thumbnails/$cleanTitle.webp';
        }

        final lowerTitle = title.toLowerCase();
        final lowerSlug = slug.toLowerCase();
        final isManhwa = lowerTitle.contains('manhwa') ||
            lowerSlug.contains('level') ||
            lowerSlug.contains('ranker') ||
            lowerSlug.contains('regress') ||
            lowerSlug.contains('hunter');
        final isManhua = lowerTitle.contains('martial') ||
            lowerTitle.contains('cultivat') ||
            lowerSlug.contains('martial') ||
            lowerSlug.contains('god');

        items.add(
          MangaItem(
            id: 'demon:$slug',
            title: title,
            cover: cover,
            type: isManhwa ? 'manhwa' : (isManhua ? 'manhua' : 'manga'),
            source: 'mangademon',
          ),
        );

        if (items.length >= limit) break;
      }

      return items;
    }

    return [];
  }

  /// Get manga details
  Future<MangaItem> getManga(String id) async {
    final cleanId = id.startsWith('demon:') ? id.substring(6) : id;
    final mangaUrl = 'https://$_domain/manga/$cleanId';

    final res = await _getCached(
      Uri.parse(mangaUrl),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        'Referer': _referer,
      },
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaDemon');

    if (res.statusCode == 200) {
      final html = res.body;

      final titleMatch = RegExp(r'<h1[^>]*>([^<]+)<\/h1>', caseSensitive: false).firstMatch(html) ??
          RegExp(r'<title>([^<]+)<\/title>', caseSensitive: false).firstMatch(html);
      final rawTitle = titleMatch?.group(1)?.trim() ?? cleanId.replaceAll('-', ' ');
      final title = HtmlScraperUtils.unescapeHtml(
        rawTitle.replaceAll(RegExp(r'\s*-\s*Read.*$', caseSensitive: false), '').trim(),
      );

      // Cover extraction
      String cover = '';
      final coverMatch = RegExp(r'<img[^>]+src="([^"]+)"[^>]*alt="[^"]*"', caseSensitive: false).firstMatch(html) ??
          RegExp(r'https:\/\/readermc\.org\/images\/thumbnails\/[^"]+', caseSensitive: false).firstMatch(html);
      if (coverMatch != null) {
        cover = coverMatch.group(1) ?? coverMatch.group(0) ?? '';
        if (cover.startsWith('/')) cover = 'https://$_domain$cover';
      }
      if (cover.isEmpty) {
        cover = 'https://readermc.org/images/thumbnails/${cleanId.replaceAll('-', ' ')}.webp';
      }

      // Description
      String desc = '';
      final descMatch = RegExp(r'<p[^>]*class="[^"]*description[^"]*"[^>]*>([\s\S]*?)<\/p>', caseSensitive: false)
              .firstMatch(html) ??
          RegExp(r'<div[^>]*class="[^"]*description[^"]*"[^>]*>([\s\S]*?)<\/div>', caseSensitive: false)
              .firstMatch(html);
      if (descMatch != null) {
        desc = HtmlScraperUtils.unescapeHtml(
          descMatch.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim(),
        );
      }

      // Status
      String status = 'Ongoing';
      if (html.toLowerCase().contains('completed')) {
        status = 'Completed';
      }

      final lower = title.toLowerCase();
      final isManhwa = lower.contains('level') || lower.contains('ranker') || lower.contains('hunter');
      final isManhua = lower.contains('martial') || lower.contains('cultivat') || lower.contains('peak');

      return MangaItem(
        id: 'demon:$cleanId',
        title: title,
        cover: cover,
        description: desc,
        status: status,
        type: isManhwa ? 'manhwa' : (isManhua ? 'manhua' : 'manga'),
        source: 'mangademon',
      );
    }

    throw Exception('Failed to load MangaDemon details for $id (HTTP ${res.statusCode})');
  }

  /// Get chapter list
  Future<List<ChapterItem>> getChapters(String id) async {
    final cleanId = id.startsWith('demon:') ? id.substring(6) : id;
    final mangaUrl = 'https://$_domain/manga/$cleanId';

    final res = await _getCached(
      Uri.parse(mangaUrl),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        'Referer': _referer,
      },
    );

    HtmlScraperUtils.checkResponseHealth(res, 'MangaDemon');

    if (res.statusCode == 200) {
      final html = res.body;
      final chapters = <ChapterItem>[];
      final seen = <String>{};

      // Format: <a href="/chaptered.php?manga=1&chapter=3862">...Chapter 3862...</a>
      final chRegex = RegExp(
        r'<a[^>]+href="(?:\/)?chaptered\.php\?manga=(\d+)&amp;chapter=([^"&]+)"[^>]*>([\s\S]*?)<\/a>|<a[^>]+href="(?:\/)?chaptered\.php\?manga=(\d+)&chapter=([^"&]+)"[^>]*>([\s\S]*?)<\/a>',
        caseSensitive: false,
      );

      for (final m in chRegex.allMatches(html)) {
        final mangaNum = m.group(1) ?? m.group(4) ?? '';
        final chNum = m.group(2) ?? m.group(5) ?? '';
        final rawText = (m.group(3) ?? m.group(6) ?? '').replaceAll(RegExp(r'<[^>]+>'), '').trim();

        if (chNum.isEmpty || !seen.add(chNum)) continue;

        final title = HtmlScraperUtils.unescapeHtml(
          rawText.split('\n').first.trim(),
        );

        chapters.add(
          ChapterItem(
            id: 'demon:$cleanId:$mangaNum:$chNum',
            title: title.isNotEmpty ? title : 'Chapter $chNum',
            number: chNum,
            source: 'mangademon',
          ),
        );
      }

      return chapters;
    }

    return [];
  }

  /// Load chapter reader pages
  Future<ChapterPages> getChapterPages(String chapterId) async {
    // chapterId format: demon:cleanId:mangaNum:chNum
    final parts = chapterId.split(':');
    final String mangaNum;
    final String chNum;
    if (parts.length >= 4) {
      mangaNum = parts[2];
      chNum = parts[3];
    } else if (parts.length == 3) {
      mangaNum = parts[1];
      chNum = parts[2];
    } else {
      throw Exception('Invalid chapterId for MangaDemon: $chapterId');
    }

    final initialUrl = 'https://$_domain/chaptered.php?manga=$mangaNum&chapter=$chNum';
    final res = await _client.get(
      Uri.parse(initialUrl),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        'Referer': _referer,
      },
    );

    final String finalHtml;
    if (res.statusCode == 302 || res.statusCode == 301) {
      final loc = res.headers['location'] ?? '';
      final target = loc.startsWith('http') ? loc : 'https://$_domain/${loc.replaceFirst(RegExp(r'^/'), '')}';
      final res2 = await _getCached(
        Uri.parse(target),
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          'Referer': _referer,
        },
      );
      finalHtml = res2.body;
    } else {
      finalHtml = res.body;
    }

    final pages = <String>[];
    final seen = <String>{};

    // Images format: <img ... class="imgholder" src="https://cdn.demoniclibs.com/..."
    final imgRegex = RegExp(
      r'<img[^>]+src="([^"]+)"[^>]*class="[^"]*imgholder[^"]*"|<img[^>]+class="[^"]*imgholder[^"]*"[^>]+src="([^"]+)"',
      caseSensitive: false,
    );

    for (final m in imgRegex.allMatches(finalHtml)) {
      var src = m.group(1) ?? m.group(2) ?? '';
      src = src.trim();
      if (src.isEmpty || src.contains('free_ads') || src.contains('demon-title')) continue;
      if (src.startsWith('//')) src = 'https:$src';
      if (seen.add(src)) {
        pages.add(src);
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

    throw Exception('Failed to extract chapter pages for $chapterId');
  }
}
