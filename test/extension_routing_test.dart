import 'package:flutter_test/flutter_test.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/api_service.dart';
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
  });
}
