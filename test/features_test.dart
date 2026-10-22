import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/screens/reader_screen.dart';
import 'package:manga_reader/services/api_service.dart';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await ApiService.instance.init();
  });

  group('Category Management', () {
    test('Default categories initialized', () {
      final cats = ApiService.instance.getCategories();
      expect(cats, isNotEmpty);
      expect(cats.any((c) => c.name == 'Reading'), isTrue);
      expect(cats.any((c) => c.name == 'Completed'), isTrue);
    });

    test('User can create, rename, and delete categories', () async {
      final newCat = await ApiService.instance.createCategory('Action Thriller');
      expect(newCat.name, 'Action Thriller');
      expect(ApiService.instance.getCategories().any((c) => c.id == newCat.id), isTrue);

      await ApiService.instance.renameCategory(newCat.id, 'Sci-Fi Action');
      final updated = ApiService.instance.getCategories().firstWhere((c) => c.id == newCat.id);
      expect(updated.name, 'Sci-Fi Action');

      await ApiService.instance.deleteCategory(newCat.id);
      expect(ApiService.instance.getCategories().any((c) => c.id == newCat.id), isFalse);
    });

    test('Assigning and toggling manga categories', () async {
      const mangaId = 'test_manga_1';
      expect(ApiService.instance.getMangaCategoryIds(mangaId), isEmpty);

      await ApiService.instance.setMangaCategories(mangaId, ['reading', 'favorites']);
      expect(ApiService.instance.getMangaCategoryIds(mangaId), containsAll(['reading', 'favorites']));

      await ApiService.instance.toggleMangaCategory(mangaId, 'reading');
      expect(ApiService.instance.getMangaCategoryIds(mangaId), isNot(contains('reading')));
      expect(ApiService.instance.getMangaCategoryIds(mangaId), contains('favorites'));
    });
  });

  group('Chapter Read and Bookmark Management', () {
    test('Mark chapter as read / unread', () async {
      const mangaId = 'manga_solo';
      const chapterId = 'ch_101';

      expect(ApiService.instance.isChapterRead(mangaId, chapterId), isFalse);

      await ApiService.instance.markChapterRead(mangaId, chapterId, read: true);
      expect(ApiService.instance.isChapterRead(mangaId, chapterId), isTrue);
      expect(ApiService.instance.getReadChapterIds(mangaId), contains(chapterId));

      await ApiService.instance.markChapterRead(mangaId, chapterId, read: false);
      expect(ApiService.instance.isChapterRead(mangaId, chapterId), isFalse);
    });

    test('Bookmark and unbookmark chapters', () async {
      const chapterId = 'ch_epic_battle';

      expect(ApiService.instance.isChapterBookmarked(chapterId), isFalse);

      final state1 = await ApiService.instance.toggleChapterBookmark(chapterId);
      expect(state1, isTrue);
      expect(ApiService.instance.isChapterBookmarked(chapterId), isTrue);

      final state2 = await ApiService.instance.toggleChapterBookmark(chapterId);
      expect(state2, isFalse);
      expect(ApiService.instance.isChapterBookmarked(chapterId), isFalse);
    });
  });

  group('Continuous Reader Screen', () {
    testWidgets('ReaderScreen renders with chapters list and bookmark toggle', (tester) async {
      final chapters = [
        const ChapterItem(id: 'ch_1', number: '1', title: 'Beginning'),
        const ChapterItem(id: 'ch_2', number: '2', title: 'Awakening'),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            mangaId: 'manga_1',
            mangaTitle: 'Solo Leveling',
            chapters: chapters,
            initialIndex: 0,
          ),
        ),
      );

      await tester.pump();
      expect(find.text('Solo Leveling'), findsOneWidget);
      // Bookmark button exists in top bar
      expect(find.byTooltip('Bookmark Chapter'), findsOneWidget);

      // Tap bookmark
      await tester.tap(find.byTooltip('Bookmark Chapter'));
      await tester.pump();
      expect(ApiService.instance.isChapterBookmarked('ch_1'), isTrue);
    });
  });

  group('Strict No-Fallback Policy', () {
    test('getManga throws for unknown source ID without falling back to MangaDex', () async {
      expect(
        () => ApiService.instance.getManga('unknown_random_id_12345'),
        throwsA(isA<Exception>()),
      );
    });

    test('getChapters returns empty list for unknown source ID without querying MangaDex', () async {
      final chapters = await ApiService.instance.getChapters('unknown_source_manga_999');
      expect(chapters, isEmpty);
    });

    test('getChapterPages throws for unknown chapter source ID without querying MangaDex', () async {
      expect(
        () => ApiService.instance.getChapterPages('unknown_chapter_999'),
        throwsA(isA<Exception>()),
      );
    });

    test('searchManga returns empty list for unknown or failing source', () async {
      final results = await ApiService.instance.searchManga(query: 'test', source: 'non_existent_source_xyz');
      expect(results, isEmpty);
    });
  });
}
