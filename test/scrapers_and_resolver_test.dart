import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/scrapers/asura_scraper.dart';
import 'package:manga_reader/services/scrapers/html_scraper_utils.dart';
import 'package:manga_reader/services/scrapers/mangapill_scraper.dart';
import 'package:manga_reader/services/scrapers/weeb_scraper.dart';
import 'package:manga_reader/services/source_resolver.dart';

void main() {
  group('SourceResolver Tests', () {
    test('resolveSource identifies all standard sources by ID prefix or format', () {
      expect(SourceResolver.resolveSource('mangadex:12345'), 'mangadex');
      expect(SourceResolver.resolveSource('asura:solo-leveling'), 'asura');
      expect(SourceResolver.resolveSource('flame:omniscient-reader'), 'flamecomics');
      expect(SourceResolver.resolveSource('weeb:01JJX'), 'weebcentral');
      expect(SourceResolver.resolveSource('pill:456'), 'mangapill');
      expect(SourceResolver.resolveSource('katana:789'), 'mangakatana');
      expect(SourceResolver.resolveSource('mread:888'), 'mangaread');
      expect(SourceResolver.resolveSource('ext:keiyoushi:abc'), 'keiyoushi');

      // UUID format without prefix resolves to mangadex
      expect(SourceResolver.resolveSource('a1b2c3d4-e5f6-7890-abcd-ef1234567890'), 'mangadex');
      // Unknown prefix
      expect(SourceResolver.resolveSource('unknown_id_no_prefix'), 'unknown_id_no_prefix');
    });

    test('displayName returns user-friendly source labels', () {
      expect(SourceResolver.displayName('mangadex'), 'MangaDex');
      expect(SourceResolver.displayName('asura'), 'Asura Scans');
      expect(SourceResolver.displayName('flamecomics'), 'Flame Comics');
      expect(SourceResolver.displayName('weebcentral'), 'WeebCentral');
      expect(SourceResolver.displayName('mangapill'), 'MangaPill');
      expect(SourceResolver.displayName('mangakatana'), 'MangaKatana');
      expect(SourceResolver.displayName('mangaread'), 'MangaRead');
      expect(SourceResolver.displayName('custom_source'), 'Custom_source');
    });

    test('prefix and stripPrefix round-trip', () {
      const source = 'asura';
      const rawId = 'my-manga-slug';
      final prefixed = SourceResolver.prefix(source, rawId);
      expect(prefixed, 'asura:my-manga-slug');
      expect(SourceResolver.stripPrefix(prefixed), 'my-manga-slug');

      // If already prefixed, prefix does not duplicate
      expect(SourceResolver.prefix(source, prefixed), 'asura:my-manga-slug');
    });
  });

  group('LruHttpCache Tests', () {
    test('Caches items and respects capacity eviction', () {
      final cache = LruHttpCache(capacity: 3);

      cache.put('a', 'alpha', ttl: const Duration(minutes: 5));
      cache.put('b', 'beta', ttl: const Duration(minutes: 5));
      cache.put('c', 'gamma', ttl: const Duration(minutes: 5));

      expect(cache.get('a'), 'alpha');
      expect(cache.get('b'), 'beta');
      expect(cache.get('c'), 'gamma');

      // Add a 4th entry, which should evict the least recently used ('a' was accessed first, then 'b', then 'c', so 'a' was re-inserted)
      cache.put('d', 'delta', ttl: const Duration(minutes: 5));
      expect(cache.length, 3);
      expect(cache.get('d'), 'delta');
    });

    test('Item expires after TTL', () async {
      final cache = LruHttpCache(capacity: 10);
      cache.put('temp', 'val', ttl: const Duration(milliseconds: 50));
      expect(cache.get('temp'), 'val');

      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(cache.get('temp'), isNull);
    });

    test('In-flight deduplication runs fetcher only once for concurrent requests', () async {
      final cache = LruHttpCache(capacity: 10);
      var computeCount = 0;

      Future<String> slowCompute() async {
        computeCount++;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return 'computed_result';
      }

      final futures = <Future<String>>[
        cache.deduplicate('key1', slowCompute),
        cache.deduplicate('key1', slowCompute),
        cache.deduplicate('key1', slowCompute),
      ];

      final results = await Future.wait(futures);
      expect(results, ['computed_result', 'computed_result', 'computed_result']);
      expect(computeCount, 1);
    });
  });

  group('Scrapers HTML Parsing Tests', () {
    test('HtmlScraperUtils resolves relative and protocol-relative URLs', () {
      expect(
        HtmlScraperUtils.normalizeImgUrl('//cdn.example.com/img.jpg'),
        'https://cdn.example.com/img.jpg',
      );
      expect(
        HtmlScraperUtils.normalizeImgUrl('/covers/1.jpg', baseUrl: 'https://example.com/manga'),
        'https://example.com/covers/1.jpg',
      );
      expect(
        HtmlScraperUtils.normalizeImgUrl('https://other.com/a.jpg'),
        'https://other.com/a.jpg',
      );
    });

    test('MangaPillScraper extracts manga items from search HTML', () async {
      const sampleHtml = '''
        <html>
          <body>
            <div>
              <a href="/manga/101/one-piece" class="block">
                <div>
                  <img src="https://cdn.mangapill.com/covers/101.jpg" alt="One Piece" />
                </div>
                <div class="mt-3 font-black leading-tight line-clamp-2">One Piece</div>
              </a>
              <a href="/manga/102/naruto" class="block">
                <div>
                  <img data-src="https://cdn.mangapill.com/covers/102.jpg" alt="Naruto" />
                </div>
                <div class="mt-3 font-black leading-tight line-clamp-2">Naruto</div>
              </a>
            </div>
          </body>
        </html>
      ''';

      final mockClient = MockClient((request) async {
        return http.Response(sampleHtml, 200);
      });

      final scraper = MangaPillScraper(clientProvider: () => mockClient);
      final items = await scraper.search(query: 'piece');

      expect(items.length, 2);
      expect(items[0].id, 'pill:101:one-piece');
      expect(items[0].title, 'One Piece');
      expect(items[0].cover, 'https://cdn.mangapill.com/covers/101.jpg');
      expect(items[1].id, 'pill:102:naruto');
      expect(items[1].title, 'Naruto');
      expect(items[1].cover, 'https://cdn.mangapill.com/covers/102.jpg');
    });

    test('WeebScraper extracts chapter items', () async {
      const sampleMangaHtml = '''
        <html>
          <body>
            <a href="/series/01JJX/full-chapter-list">Full List</a>
          </body>
        </html>
      ''';

      const sampleChaptersHtml = '''
        <html>
          <body>
            <div id="chapter-list">
              <a href="/chapters/01JJX01">
                <span class="">Chapter 1</span>
              </a>
              <a href="/chapters/01JJX02">
                <span class="">Chapter 2</span>
              </a>
            </div>
          </body>
        </html>
      ''';

      final mockClient = MockClient((request) async {
        if (request.url.path.contains('full-chapter-list')) {
          return http.Response(sampleChaptersHtml, 200);
        }
        return http.Response(sampleMangaHtml, 200);
      });

      final scraper = WeebScraper(clientProvider: () => mockClient);
      final chapters = await scraper.getChapters('weeb:01JJX');

      expect(chapters.length, 2);
      expect(chapters[0].id, 'weeb:01JJX01');
      expect(chapters[0].number, '1');
      expect(chapters[1].id, 'weeb:01JJX02');
      expect(chapters[1].number, '2');
    });

    test('AsuraScraper parses chapter page image URLs from API response', () async {
      const sampleJsonResponse = '''
        {
          "data": {
            "chapter": {
              "pages": [
                {"url": "https://img.asurascans.com/page1.jpg"},
                {"url": "https://img.asurascans.com/page2.jpg"},
                {"url": "https://img.asurascans.com/page3.jpg"}
              ]
            }
          }
        }
      ''';

      final mockClient = MockClient((request) async {
        return http.Response(sampleJsonResponse, 200);
      });

      final scraper = AsuraScraper(clientProvider: () => mockClient);
      final res = await scraper.getChapterPages('asura:solo-leveling:chapter-1');

      expect(res.pages.length, 3);
      expect(res.pages[0], 'https://img.asurascans.com/page1.jpg');
      expect(res.pages[1], 'https://img.asurascans.com/page2.jpg');
      expect(res.pages[2], 'https://img.asurascans.com/page3.jpg');
    });
  });
}
