import 'package:flutter_test/flutter_test.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/source_resolver.dart';

void main() {
  group('Title Cleaning and DisplayTitle Tests', () {
    test('cleanTitleFromIdOrSlug decodes raw package and slug IDs into human readable titles', () {
      final rawExtId = 'ext:eu.kanade.tachiyomi.extension.all.comicklive:%2Flove-like-cherry-blossoms';
      expect(MangaItem.cleanTitleFromIdOrSlug(rawExtId), 'Love Like Cherry Blossoms');

      final rawMangaBuddy = 'ext:eu.kanade.tachiyomi.extension.en.mangabuddy:solo-leveling';
      expect(MangaItem.cleanTitleFromIdOrSlug(rawMangaBuddy), 'Solo Leveling');

      final simpleSlug = 'aoku-somero';
      expect(MangaItem.cleanTitleFromIdOrSlug(simpleSlug), 'Aoku Somero');
    });

    test('displayTitle falls back to cleaned title if title is Untitled, empty, or ext:...', () {
      final itemCorrupted = MangaItem(
        id: 'ext:eu.kanade.tachiyomi.extension.all.comicklive:%2Flove-like-cherry-blossoms',
        title: 'ext:eu.kanade.tachiyomi.extension.all.comicklive:%2Flove-like-cherry-blossoms',
      );
      expect(itemCorrupted.displayTitle, 'Love Like Cherry Blossoms');

      final itemUntitled = MangaItem(
        id: 'ext:eu.kanade.tachiyomi.extension.en.mangabuddy:the-build-up',
        title: 'Untitled',
      );
      expect(itemUntitled.displayTitle, 'The Build Up');

      final itemNormal = MangaItem(
        id: 'manga-123',
        title: 'Blue Lock',
      );
      expect(itemNormal.displayTitle, 'Blue Lock');
    });
  });

  group('SourceResolver Tests', () {
    test('displayName parses tachiyomi package IDs into friendly names', () {
      expect(
        SourceResolver.displayName('eu.kanade.tachiyomi.extension.en.mangabuddy'),
        'MangaBuddy',
      );
      expect(
        SourceResolver.displayName('eu.kanade.tachiyomi.extension.all.comicklive'),
        'Comick',
      );
    });
  });
}
