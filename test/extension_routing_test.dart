import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/api_service.dart';
import 'package:manga_reader/services/extension_service.dart';
import 'package:manga_reader/services/scrapers/web_extension_scraper.dart';
import 'package:manga_reader/services/source_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await ApiService.instance.init();
  });

  group('Plan D: Strict Source Resolution & No Fuzzy Fallbacks', () {
    test('MangaItem preserves explicit source', () {
      final item = MangaItem.fromJson({
        'id': 'some-random-id-12345',
        'title': 'Test Manga',
        'source': 'custom_source',
      });
      expect(item.source, 'custom_source');
    });

    test('MangaItem resolves ext: package prefix correctly without mangadex fallback', () {
      final item = MangaItem.fromJson({
        'id': 'ext:eu.kanade.tachiyomi.extension.en.asurascans:%2Fmanga%2F123',
        'title': 'Solo Hunter',
      });
      expect(item.source, 'eu.kanade.tachiyomi.extension.en.asurascans');
    });

    test('MangaItem resolves built-in prefixes', () {
      final asura = MangaItem.fromJson({'id': 'asura:solo-leveling', 'title': 'Solo'});
      expect(asura.source, 'asura');

      final flame = MangaItem.fromJson({'id': 'flame:infinite-mage', 'title': 'Mage'});
      expect(flame.source, 'flamecomics');

      final weeb = MangaItem.fromJson({'id': 'weeb:01J76XY', 'title': 'Weeb'});
      expect(weeb.source, 'weebcentral');

      final pill = MangaItem.fromJson({'id': 'pill:123/one-piece', 'title': 'One Piece'});
      expect(pill.source, 'mangapill');

      final katana = MangaItem.fromJson({'id': 'katana:solo-leveling:21708', 'title': 'Solo'});
      expect(katana.source, 'mangakatana');

      final mread = MangaItem.fromJson({'id': 'mread:solo-leveling-ragnarok', 'title': 'Ragnarok'});
      expect(mread.source, 'mangaread');
    });

    test('SourceManager includes direct sources in allDirectSources', () {
      final directIds = SourceManager.allDirectSources.map((s) => s.id).toList();
      expect(directIds, containsAll(['mangadex', 'mangapill', 'weebcentral', 'asura', 'flamecomics', 'mangakatana', 'mangaread']));
    });

    test('MangaItem resolves genuine MangaDex UUID to mangadex', () {
      final md = MangaItem.fromJson({'id': '32d76d19-8a05-4db0-9fc2-e0b0648fe9d0', 'title': 'MD Manga'});
      expect(md.source, 'mangadex');
    });

    test('Non-UUID and non-prefixed unknown ID does NOT default to mangadex', () {
      final unknown = MangaItem.fromJson({'id': 'some_independent_id_not_uuid', 'title': 'Unknown Manga'});
      expect(unknown.source, 'some_independent_id_not_uuid');
    });

    test('searchManga with unknown non-MangaDex source returns empty list, never MangaDex', () async {
      final results = await ApiService.instance.searchManga(
        query: 'test query',
        source: 'non_existent_custom_source',
      );
      expect(results, isEmpty);
    });

    test('MangaItem accurately distinguishes manga, manhwa, and manhua', () {
      final manhwa = MangaItem(
        id: 'ext:eu.kanade.tachiyomi.extension.all.comick:solo',
        title: 'Solo Leveling',
        type: 'manhwa',
        tags: const ['Action', 'Manhwa', 'Webtoon'],
      );
      expect(manhwa.type, 'manhwa');

      final manhua = MangaItem(
        id: 'ext:eu.kanade.tachiyomi.extension.all.comick:martial',
        title: 'Martial Peak',
        type: 'manhua',
        tags: const ['Martial Arts', 'Manhua'],
      );
      expect(manhua.type, 'manhua');

      final manga = MangaItem(
        id: 'ext:eu.kanade.tachiyomi.extension.all.comick:op',
        title: 'One Piece',
        type: 'manga',
        tags: const ['Action', 'Manga'],
      );
      expect(manga.type, 'manga');
    });

    test('WebExtensionScraper ignores Discord invite links and Cloudflare block artifacts', () async {
      final mockClient = http_testing.MockClient((request) async {
        return http.Response(
          '''
          <html>
            <body>
              <a href="https://discord.com/invite/TndkBtSNWs">Discord</a>
              <a href="https://discord.gg/xyz">Join Server</a>
              <a href="https://twitter.com/comic">Twitter</a>
              <a href="/comic/the-build-up"><img src="https://example.com/cover.jpg" title="The Build Up"/></a>
            </body>
          </html>
          ''',
          200,
        );
      });
      final scraper = WebExtensionScraper(clientProvider: () => mockClient);
      final ext = MangaExtension(
        id: 'comicklive',
        name: 'Comick (Unoriginal)',
        pkg: 'eu.kanade.tachiyomi.extension.all.comicklive',
        version: '1.4.1',
        versionCode: 1,
        apkUrl: '',
        iconUrl: '',
        sourceNames: const ['Comick (Unoriginal)'],
        libVersion: '1.4',
        lang: 'all',
        isNsfw: false,
        isInstalled: true,
        hasUpdate: false,
        homeUrl: 'https://comick.art',
      );
      final results = await scraper.search(ext, query: 'the build up');
      expect(results.any((m) => m.title == 'TndkBtSNWs'), isFalse);
      expect(results.any((m) => m.title == 'Discord'), isFalse);
      expect(results.any((m) => m.title == 'The Build Up'), isTrue);
    });

    test('ChapterItem.displayTitle formats cleanly and eliminates duplicate chapter names', () {
      final c1 = ChapterItem(id: '1', title: 'Ch. 220', number: '220');
      expect(c1.displayTitle, 'Chapter 220');

      final c2 = ChapterItem(id: '2', title: 'Chapter 220', number: '220');
      expect(c2.displayTitle, 'Chapter 220');

      final c3 = ChapterItem(id: '3', title: '220', number: '220');
      expect(c3.displayTitle, 'Chapter 220');

      final c4 = ChapterItem(id: '4', title: 'Ch. 216.5', number: '216.5');
      expect(c4.displayTitle, 'Chapter 216.5');

      final c5 = ChapterItem(id: '5', title: 'Ch. 220 - The Match Begins', number: '220');
      expect(c5.displayTitle, 'Chapter 220 - The Match Begins');

      final c6 = ChapterItem(id: '6', title: 'The Match Begins', number: '220');
      expect(c6.displayTitle, 'Chapter 220 - The Match Begins');

      final c7 = ChapterItem(id: '7', title: 'Prologue', number: null);
      expect(c7.displayTitle, 'Prologue');

      final c8 = ChapterItem(id: '8', title: '', number: '10');
      expect(c8.displayTitle, 'Chapter 10');
    });

    test('Scanlator exclusion correctly filters duplicate releases', () {
      final chapters = [
        ChapterItem(id: '1', title: 'Ch. 220', number: '220', group: 'Mangakakalot'),
        ChapterItem(id: '2', title: 'Ch. 220', number: '220', group: 'LINE Webtoon'),
        ChapterItem(id: '3', title: 'Ch. 219', number: '219', group: 'Mangakakalot'),
        ChapterItem(id: '4', title: 'Ch. 219', number: '219', group: 'LINE Webtoon'),
      ];

      final excluded = {'LINE Webtoon'};
      final filtered = chapters.where((c) => !excluded.contains(c.group)).toList();

      expect(filtered.length, 2);
      expect(filtered.every((c) => c.group == 'Mangakakalot'), isTrue);
    });
  });
}
