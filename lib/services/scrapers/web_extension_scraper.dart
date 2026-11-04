import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/extension_service.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/scrapers/html_scraper_utils.dart';
import 'package:manga_reader/widgets/common.dart';

class WebExtensionScraper {
  final http.Client Function() _clientProvider;
  final LruHttpCache? _cache;

  WebExtensionScraper({required this._clientProvider, this._cache});

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

  Future<List<MangaItem>> search(
    MangaExtension ext, {
    String? sourcePkg,
    String? query,
    String order = 'popular',
    int page = 1,
    int limit = 24,
  }) async {
    final effectivePkg = (sourcePkg != null && sourcePkg.isNotEmpty)
        ? sourcePkg
        : ext.pkg;
    String home = ext.homeUrl;
    if (effectivePkg.contains('@') && ext.subSources.isNotEmpty) {
      final sel = effectivePkg.split('@').sublist(1).join('@').toUpperCase();
      final matchSub = ext.subSources
          .where(
            (s) =>
                (s['id'] ?? '').toUpperCase() == sel ||
                (s['lang'] ?? '').toUpperCase() == sel ||
                (s['name'] ?? '').toUpperCase() == sel,
          )
          .firstOrNull;
      if (matchSub != null && (matchSub['baseUrl'] ?? '').startsWith('http')) {
        home = matchSub['baseUrl']!;
      }
    }
    if (home.isEmpty) return [];

    try {
      final base = home.endsWith('/')
          ? home.substring(0, home.length - 1)
          : home;
      final referer = '$base/';
      final candidateUrls = <String>[];
      if (query != null && query.trim().isNotEmpty) {
        final q = Uri.encodeComponent(query.trim());
        candidateUrls.addAll([
          if (page > 1)
            '$base/page/$page/?s=$q&post_type=wp-manga'
          else
            '$base/?s=$q&post_type=wp-manga',
          if (page > 1) '$base/page/$page/?s=$q' else '$base/?s=$q',
          '$base/manga/?s=$q&page=$page',
        ]);
      } else if (order == 'latest') {
        candidateUrls.addAll([
          '$base/manga/?page=$page&order=update',
          if (page > 1)
            '$base/page/$page/?s=&post_type=wp-manga&m_orderby=latest'
          else
            '$base/?s=&post_type=wp-manga&m_orderby=latest',
          if (page > 1) '$base/page/$page/' else base,
        ]);
      } else {
        candidateUrls.addAll([
          '$base/manga/?page=$page&order=popular',
          if (page > 1)
            '$base/page/$page/?s=&post_type=wp-manga&m_orderby=views'
          else
            '$base/?s=&post_type=wp-manga&m_orderby=views',
          if (page > 1) '$base/page/$page/' else base,
        ]);
      }

      const invalidTitles = {
        'home',
        'about',
        'privacy',
        'privacy policy',
        'contact',
        'contact us',
        'dmca',
        'terms',
        'terms of service',
        'login',
        'sign in',
        'register',
        'sign up',
        'discord',
        'telegram',
        'twitter',
        'facebook',
        'donate',
        'bookmark',
        'history',
        'popular',
        'latest',
        'search',
        'manga list',
        'all manga',
        'genre',
        'genres',
        'tags',
        'news',
        'read more',
        'next',
        'prev',
      };

      for (final url in candidateUrls) {
        http.Response res;
        try {
          res = await _getCached(
            Uri.parse(url),
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Referer': referer,
            },
            timeout: const Duration(seconds: 10),
          );
        } catch (_) {
          continue;
        }
        if (res.statusCode != 200) continue;

        final html = res.body;
        final items = <MangaItem>[];
        final seenUrls = <String>{};

        void tryAddItem(String rawHref, String titleHint, String coverHint) {
          var itemUrl = rawHref.trim();
          if (itemUrl.isEmpty ||
              itemUrl == '#' ||
              itemUrl == base ||
              itemUrl == '$base/') {
            return;
          }
          if (itemUrl.startsWith('javascript:') ||
              itemUrl.startsWith('mailto:')) {
            return;
          }
          final lowerHref = itemUrl.toLowerCase();
          if (lowerHref.contains('/wp-login') ||
              lowerHref.contains('/genre/') ||
              lowerHref.contains('/tag/') ||
              lowerHref.contains('/author/') ||
              RegExp(
                r'(?:chapter|ch-|episode|ep-)\d',
                caseSensitive: false,
              ).hasMatch(lowerHref)) {
            return;
          }
          if (!itemUrl.startsWith('http')) {
            itemUrl = itemUrl.startsWith('/')
                ? '$base$itemUrl'
                : '$base/$itemUrl';
          }
          if (!seenUrls.add(itemUrl)) return;

          var title = HtmlScraperUtils.unescapeHtml(
            titleHint
                .replaceAll(RegExp(r'<[^>]*>'), ' ')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim(),
          );
          if (title.isEmpty) {
            final slug =
                Uri.tryParse(
                  itemUrl,
                )?.pathSegments.where((s) => s.isNotEmpty).lastOrNull ??
                '';
            title = slug.replaceAll('-', ' ').replaceAll('_', ' ');
          }
          final lowerTitle = title.toLowerCase().trim();
          if (title.isEmpty || invalidTitles.contains(lowerTitle)) return;

          items.add(
            MangaItem(
              id: 'ext:$effectivePkg:${Uri.encodeComponent(itemUrl)}',
              title: title,
              cover: coverHint,
              source: effectivePkg,
            ),
          );
        }

        final linkBlockRegex = RegExp(
          r'''<a\s+[^>]*href=["']([^"']+)["']([^>]*)>((?:(?!</a>)[\s\S])*?)</a>''',
          caseSensitive: false,
        );
        for (final m in linkBlockRegex.allMatches(html)) {
          final href = m.group(1) ?? '';
          final aAttrs = m.group(2) ?? '';
          final innerHtml = m.group(3) ?? '';

          String coverUrl = '';
          final imgTagMatch = RegExp(
            r'<img\b[^>]*>',
            caseSensitive: false,
          ).firstMatch(innerHtml);
          if (imgTagMatch != null) {
            coverUrl = HtmlScraperUtils.extractImgFromTag(
              imgTagMatch.group(0)!,
              baseUrl: base,
              referer: referer,
            );
          }
          if (coverUrl.isEmpty) {
            final bgMatch = RegExp(
              r'''url\(["']?([^"')]+)["']?\)''',
              caseSensitive: false,
            ).firstMatch('$aAttrs $innerHtml');
            if (bgMatch != null) {
              coverUrl = HtmlScraperUtils.normalizeImgUrl(
                bgMatch.group(1),
                baseUrl: base,
                referer: referer,
              );
            }
          }
          if (coverUrl.isEmpty) continue;
          final lowerCover = coverUrl.toLowerCase();
          if (lowerCover.contains('logo') ||
              lowerCover.contains('avatar') ||
              lowerCover.contains('favicon') ||
              lowerCover.contains('banner')) {
            continue;
          }

          final titleAttrMatch =
              RegExp(
                r'''title=["']([^"']+)["']''',
                caseSensitive: false,
              ).firstMatch(aAttrs) ??
              (imgTagMatch != null
                  ? RegExp(
                      r'''alt=["']([^"']+)["']''',
                      caseSensitive: false,
                    ).firstMatch(imgTagMatch.group(0)!)
                  : null);
          final titleHint = titleAttrMatch?.group(1) ?? innerHtml;
          tryAddItem(href, titleHint, coverUrl);
          if (items.length >= limit) break;
        }

        if (items.isEmpty) {
          final cardRegex = RegExp(
            r'''<div[^>]*class=["'][^"']*(?:page-item-detail|c-tabs-item__content|bsx|utao|manga-item|serie-card)[^"']*["'][^>]*>([\s\S]*?)</div>\s*</div>''',
            caseSensitive: false,
          );
          for (final cm in cardRegex.allMatches(html)) {
            final block = cm.group(1) ?? '';
            final hrefMatch = RegExp(
              r'''<a\s+[^>]*href=["']([^"']+)["']([^>]*)>([\s\S]*?)</a>''',
              caseSensitive: false,
            ).firstMatch(block);
            if (hrefMatch == null) continue;
            final imgMatch = RegExp(
              r'<img\b[^>]*>',
              caseSensitive: false,
            ).firstMatch(block);
            var coverUrl = imgMatch != null
                ? HtmlScraperUtils.extractImgFromTag(
                    imgMatch.group(0)!,
                    baseUrl: base,
                    referer: referer,
                  )
                : '';
            if (coverUrl.isEmpty) {
              final bgMatch = RegExp(
                r'''url\(["']?([^"')]+)["']?\)''',
                caseSensitive: false,
              ).firstMatch(block);
              coverUrl = HtmlScraperUtils.normalizeImgUrl(
                bgMatch?.group(1),
                baseUrl: base,
                referer: referer,
              );
            }
            final titleMatch =
                RegExp(
                  r'''<(?:h3|h4|h5|div)[^>]*class=["'][^"']*(?:post-title|tt|title)[^"']*["'][^>]*>([\s\S]*?)</(?:h3|h4|h5|div)>''',
                  caseSensitive: false,
                ).firstMatch(block) ??
                RegExp(
                  r'''title=["']([^"']+)["']''',
                  caseSensitive: false,
                ).firstMatch(hrefMatch.group(2) ?? '');
            tryAddItem(
              hrefMatch.group(1) ?? '',
              titleMatch?.group(1) ?? hrefMatch.group(3) ?? '',
              coverUrl,
            );
            if (items.length >= limit) break;
          }
        }

        if (items.isNotEmpty) {
          final missingIndices = <int>[
            for (var i = 0; i < items.length; i++)
              if (items[i].cover.isEmpty) i,
          ];
          if (missingIndices.isNotEmpty) {
            await Future.wait(
              missingIndices.take(6).map((idx) async {
                try {
                  final m = items[idx];
                  final actual = m.id.split(':').sublist(2).join(':');
                  final detailed = await getManga(
                    effectivePkg,
                    actual,
                    ext: ext,
                  );
                  if (detailed.cover.isNotEmpty) {
                    items[idx] = MangaItem(
                      id: m.id,
                      title: m.title,
                      cover: detailed.cover,
                      source: m.source,
                    );
                  }
                } catch (_) {}
              }),
            );
          }
          return items;
        }
      }
    } catch (e) {
      debugPrint('WebExtension search error for $effectivePkg: $e');
    }
    return [];
  }

  Future<MangaItem> getManga(
    String pkg,
    String actualId, {
    MangaExtension? ext,
  }) async {
    final seriesUrl = Uri.decodeComponent(actualId);
    final parsedUri = Uri.tryParse(seriesUrl);
    final origin =
        (parsedUri != null && parsedUri.hasScheme && parsedUri.host.isNotEmpty)
        ? '${parsedUri.scheme}://${parsedUri.host}'
        : (ext?.homeUrl ?? '');
    final referer = origin.isNotEmpty
        ? (origin.endsWith('/') ? origin : '$origin/')
        : null;

    try {
      final res = await _getCached(
        Uri.parse(seriesUrl),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Referer': ?referer,
        },
        timeout: const Duration(seconds: 10),
      );

      if (res.statusCode == 200) {
        final html = res.body;

        final h1Match = RegExp(
          r'<h1[^>]*>([\s\S]*?)</h1>',
          caseSensitive: false,
        ).firstMatch(html);
        final rawTitle =
            h1Match?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '';
        final title = HtmlScraperUtils.unescapeHtml(
          rawTitle.isNotEmpty ? rawTitle : (ext?.name ?? 'Series'),
        );

        final descMatch =
            RegExp(
              r'''<div[^>]*class=["'][^"']*(?:description|synopsis|summary|entry-content)[^"']*["'][^>]*>([\s\S]*?)</div>''',
              caseSensitive: false,
            ).firstMatch(html) ??
            RegExp(
              r'''<p[^>]*class=["'][^"']*(?:description|synopsis|summary)[^"']*["'][^>]*>([\s\S]*?)</p>''',
              caseSensitive: false,
            ).firstMatch(html) ??
            RegExp(
              r'''<meta[^>]+(?:property=["']og:description["']|name=["']description["'])[^>]+content=["']([^"']+)["']''',
              caseSensitive: false,
            ).firstMatch(html);
        final desc = HtmlScraperUtils.unescapeHtml(
          descMatch?.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '',
        );

        String coverUrl = '';
        final coverContainerMatch = RegExp(
          r'''<(?:div|figure)[^>]*class=["'][^"']*(?:summary_image|thumb|cover|poster|seriestucon)[^"']*["'][^>]*>[\s\S]*?(<img\b[^>]*>)''',
          caseSensitive: false,
        ).firstMatch(html);
        if (coverContainerMatch != null) {
          coverUrl = HtmlScraperUtils.extractImgFromTag(
            coverContainerMatch.group(1)!,
            baseUrl: origin,
            referer: referer,
          );
        }
        if (coverUrl.isEmpty) {
          final coverImgMatch = RegExp(
            r'''<img\b[^>]*class=["'][^"']*(?:thumb|cover|poster|wp-post-image)[^"']*["'][^>]*>''',
            caseSensitive: false,
          ).firstMatch(html);
          if (coverImgMatch != null) {
            coverUrl = HtmlScraperUtils.extractImgFromTag(
              coverImgMatch.group(0)!,
              baseUrl: origin,
              referer: referer,
            );
          }
        }
        if (coverUrl.isEmpty) {
          final ogMatch =
              RegExp(
                r'''<meta[^>]+(?:property=["']og:image["']|name=["']twitter:image["'])[^>]+content=["']([^"']+)["']''',
                caseSensitive: false,
              ).firstMatch(html) ??
              RegExp(
                r'''<meta[^>]+content=["']([^"']+)["'][^>]+(?:property=["']og:image["']|name=["']twitter:image["'])''',
                caseSensitive: false,
              ).firstMatch(html);
          coverUrl = HtmlScraperUtils.normalizeImgUrl(
            ogMatch?.group(1),
            baseUrl: origin,
            referer: referer,
          );
        }

        final mangaId = 'ext:$pkg:$actualId';
        if (coverUrl.isNotEmpty) {
          ImageReferers.rememberResolvedCover(mangaId, coverUrl);
        }

        return MangaItem(
          id: mangaId,
          title: title,
          description: desc,
          cover: coverUrl,
          source: pkg,
        );
      }
    } catch (e) {
      debugPrint('WebExtension getManga error: $e');
    }

    return MangaItem(
      id: 'ext:$pkg:$actualId',
      title: ext?.name ?? 'Series',
      source: pkg,
    );
  }

  Future<List<ChapterItem>> getChapters(
    String pkg,
    String actualId, {
    MangaExtension? ext,
  }) async {
    final seriesUrl = Uri.decodeComponent(actualId);
    final parsedUri = Uri.tryParse(seriesUrl);
    final origin =
        (parsedUri != null && parsedUri.hasScheme && parsedUri.host.isNotEmpty)
        ? '${parsedUri.scheme}://${parsedUri.host}'
        : (ext?.homeUrl ?? '');
    final referer = origin.isNotEmpty
        ? (origin.endsWith('/') ? origin : '$origin/')
        : null;

    List<ChapterItem> parseHtmlChapters(String html) {
      final chapterRegex = RegExp(
        r'''<a\s+[^>]*href=["']([^"']*(?:chapter|ch-|episode|ep-|chap-)[^"']*)["'][^>]*>((?:(?!</a>)[\s\S])*?)</a>''',
        caseSensitive: false,
      );
      final list = <ChapterItem>[];
      final seen = <String>{};
      for (final m in chapterRegex.allMatches(html)) {
        var chUrl = (m.group(1) ?? '').trim();
        final rawText = HtmlScraperUtils.unescapeHtml(
          (m.group(2) ?? '')
              .replaceAll(RegExp(r'<[^>]*>'), ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim(),
        );
        if (chUrl.isEmpty ||
            chUrl.startsWith('#') ||
            chUrl.startsWith('javascript:')) {
          continue;
        }
        if (!chUrl.startsWith('http')) {
          final uri = Uri.parse(seriesUrl);
          chUrl = chUrl.startsWith('/')
              ? '${uri.scheme}://${uri.host}$chUrl'
              : '${uri.scheme}://${uri.host}/$chUrl';
        }
        if (!seen.add(chUrl)) continue;
        final numMatch =
            RegExp(
              r'(?:chapter|episode|ch\.?|ep\.?|chap\.?)\s*([\d\.]+)',
              caseSensitive: false,
            ).firstMatch(rawText) ??
            RegExp(
              r'(?:chapter|ch|ep)[-_]([\d\.]+)',
              caseSensitive: false,
            ).firstMatch(chUrl);
        final chNum = numMatch?.group(1);
        list.add(
          ChapterItem(
            id: 'ext:$pkg:${Uri.encodeComponent(chUrl)}',
            number: chNum,
            title: rawText.isNotEmpty
                ? rawText
                : (chNum != null ? 'Chapter $chNum' : 'Chapter'),
            group: ext?.name ?? 'Web',
            source: pkg,
          ),
        );
      }
      return list;
    }

    try {
      final res = await _getCached(
        Uri.parse(seriesUrl),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Referer': ?referer,
        },
        timeout: const Duration(seconds: 10),
      );

      if (res.statusCode == 200) {
        final directList = parseHtmlChapters(res.body);
        if (directList.isNotEmpty) return directList;

        final ajaxUrl =
            '${seriesUrl.endsWith('/') ? seriesUrl : '$seriesUrl/'}ajax/chapters/';
        try {
          final ajaxRes = await _client
              .post(
                Uri.parse(ajaxUrl),
                headers: {
                  'User-Agent':
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                  'X-Requested-With': 'XMLHttpRequest',
                  'Referer': seriesUrl,
                },
              )
              .timeout(const Duration(seconds: 8));
          if (ajaxRes.statusCode == 200 && ajaxRes.body.isNotEmpty) {
            final ajaxList = parseHtmlChapters(ajaxRes.body);
            if (ajaxList.isNotEmpty) return ajaxList;
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('WebExtension getChapters error: $e');
    }
    return [];
  }

  Future<ChapterPages> getChapterPages(
    String pkg,
    String actualChapterId, {
    MangaExtension? ext,
  }) async {
    final chapterUrl = Uri.decodeComponent(actualChapterId);
    final parsedUri = Uri.tryParse(chapterUrl);
    final origin =
        (parsedUri != null && parsedUri.hasScheme && parsedUri.host.isNotEmpty)
        ? '${parsedUri.scheme}://${parsedUri.host}'
        : (ext?.homeUrl ?? '');
    final referer = origin.isNotEmpty
        ? (origin.endsWith('/') ? origin : '$origin/')
        : null;

    try {
      final res = await _client
          .get(
            Uri.parse(chapterUrl),
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Referer': ?referer,
            },
          )
          .timeout(const Duration(seconds: 12));

      if (res.statusCode == 200) {
        final html = res.body;
        final pagesList = <String>[];
        final seen = <String>{};

        final tsReaderMatch = RegExp(
          r'ts_reader\.run\((\{[\s\S]*?\})\)\s*;?',
          caseSensitive: false,
        ).firstMatch(html);
        if (tsReaderMatch != null) {
          final jsonBlock = tsReaderMatch.group(1)!;
          final imagesArrMatch = RegExp(
            r'"images"\s*:\s*\[([\s\S]*?)\]',
          ).firstMatch(jsonBlock);
          if (imagesArrMatch != null) {
            for (final um in RegExp(
              r'"([^"]+)"',
            ).allMatches(imagesArrMatch.group(1)!)) {
              final rawImg = um.group(1)!.replaceAll(r'\/', '/');
              final u = HtmlScraperUtils.normalizeImgUrl(
                rawImg,
                baseUrl: origin,
                referer: referer,
              );
              if (u.isNotEmpty && seen.add(u)) pagesList.add(u);
            }
          }
        }

        if (pagesList.isEmpty) {
          final preloadMatch = RegExp(
            r'(?:chapter_preloaded_images|var\s+thzq)\s*=\s*\[([\s\S]*?)\]',
            caseSensitive: false,
          ).firstMatch(html);
          if (preloadMatch != null) {
            for (final um in RegExp(
              r'''["']([^"']+)["']''',
            ).allMatches(preloadMatch.group(1)!)) {
              final rawImg = um.group(1)!.replaceAll(r'\/', '/');
              final u = HtmlScraperUtils.normalizeImgUrl(
                rawImg,
                baseUrl: origin,
                referer: referer,
              );
              if (u.isNotEmpty && seen.add(u)) pagesList.add(u);
            }
          }
        }

        if (pagesList.isEmpty) {
          final readerSectionMatch = RegExp(
            r'''<div[^>]*(?:id=["']readerarea["']|class=["'][^"']*(?:reading-content|chapter-content|vung-doc|container-chapter-reader)[^"']*["'])[^>]*>([\s\S]*?)</div>\s*</div>''',
            caseSensitive: false,
          ).firstMatch(html);
          final targetHtml = readerSectionMatch?.group(1) ?? html;
          final imgTags = RegExp(
            r'<img\b[^>]*>',
            caseSensitive: false,
          ).allMatches(targetHtml);
          for (final m in imgTags) {
            final u = HtmlScraperUtils.extractImgFromTag(
              m.group(0)!,
              baseUrl: origin,
              referer: referer,
            );
            if (u.isEmpty) continue;
            final lower = u.toLowerCase();
            if (lower.contains('logo') ||
                lower.contains('banner') ||
                lower.contains('avatar') ||
                lower.contains('favicon') ||
                lower.contains('icon') ||
                lower.contains('gravatar')) {
              continue;
            }
            if (seen.add(u)) {
              pagesList.add(u);
            }
          }
        }

        if (pagesList.isNotEmpty) {
          return ChapterPages(
            chapterId: 'ext:$pkg:$actualChapterId',
            pages: pagesList,
            dataSaver: pagesList,
          );
        }
      }
    } catch (e) {
      debugPrint('WebExtension getChapterPages error: $e');
    }
    throw Exception('Failed to load chapter pages from $pkg');
  }
}
