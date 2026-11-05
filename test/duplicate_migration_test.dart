import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/api_service.dart';
import 'package:manga_reader/widgets/duplicate_migration_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ApiService.instance.init();
    await ApiService.instance.libraryRepo.clearLocalData();
    await ApiService.instance.historyRepo.clearLocalData();
  });

  group('DuplicateDetector Tests', () {
    test('normalize removes tags, punctuation and extra whitespace', () {
      expect(
        DuplicateDetector.normalize('Initial D [Official] (Colored)'),
        equals('initial d'),
      );
      expect(
        DuplicateDetector.normalize('Solo Leveling - Side Story [Webtoon]'),
        equals('solo leveling side story'),
      );
    });

    test('isPossibleDuplicate correctly matches titles across sources', () {
      expect(
        DuplicateDetector.isPossibleDuplicate('Initial D', 'Initial D (Official)'),
        isTrue,
      );
      expect(
        DuplicateDetector.isPossibleDuplicate('Initial D', 'initial-d'),
        isTrue,
      );
      expect(
        DuplicateDetector.isPossibleDuplicate('Solo Leveling', 'One Piece'),
        isFalse,
      );
      expect(
        DuplicateDetector.isPossibleDuplicate('Ao Ashi', 'Ao Ashi Brotherfoot'),
        isFalse,
      );
      expect(
        DuplicateDetector.isPossibleDuplicate('Solo Leveling', 'Solo Leveling Ragnarok'),
        isFalse,
      );
      expect(
        DuplicateDetector.isPossibleDuplicate('Naruto', 'Naruto Gaiden'),
        isFalse,
      );
      expect(
        DuplicateDetector.isPossibleDuplicate('Ao Ashi', 'Ao Ashi Digital Colored'),
        isTrue,
      );
    });

    test('findDuplicatesInLibrary locates entries with similar names', () {
      final library = [
        const MangaItem(id: 'weeb:initial-d', title: 'Initial D', source: 'weebcentral'),
        const MangaItem(id: 'md:one-piece', title: 'One Piece', source: 'mangadex'),
      ];

      final target = const MangaItem(
        id: 'md:initial-d',
        title: 'Initial D [Official]',
        source: 'mangadex',
      );

      final dups = DuplicateDetector.findDuplicatesInLibrary(target, library);
      expect(dups.length, equals(1));
      expect(dups.first.id, equals('weeb:initial-d'));
    });
  });

  group('Library Removal and Cloud Tombstone Tests', () {
    test('Removed manga cannot be resurrected by cloud download (tombstones)', () async {
      final manga = const MangaItem(
        id: 'ext:weeb:manga-1',
        title: 'Initial D',
        cover: 'https://example.com/cover.jpg',
      );

      // Add to library
      await ApiService.instance.addToLibrary(manga);
      expect(ApiService.instance.libraryRepo.isInLibrary(manga.id), isTrue);

      // Remove from library
      await ApiService.instance.removeFromLibrary(manga.id);
      expect(ApiService.instance.libraryRepo.isInLibrary(manga.id), isFalse);

      // Mock cloud trying to re-inject the deleted manga on download
      final mockClient = MockClient((request) async {
        if (request.url.path.contains('/library')) {
          return http.Response(
            jsonEncode({
              'bookmarks': [
                {
                  'mangaId': manga.id,
                  'title': manga.title,
                  'cover': manga.cover,
                  'source': 'weebcentral',
                }
              ]
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });

      await ApiService.instance.libraryRepo.downloadLibraryBookmarks(
        mockClient,
        'http://mock.test',
        {},
      );

      // Must NOT be resurrected
      expect(ApiService.instance.libraryRepo.isInLibrary(manga.id), isFalse);
    });
  });

  group('Migration and Copy Reading Progress Tests', () {
    test('migrateOrCopyReadingProgress copies read chapters and last reading progress', () async {
      const sourceMangaId = 'weeb:initial-d';
      final targetManga = const MangaItem(
        id: 'md:initial-d',
        title: 'Initial D',
        cover: 'https://example.com/target-cover.jpg',
      );

      // Record source progress: read chapter 2, page 15
      await ApiService.instance.saveProgress(
        mangaId: sourceMangaId,
        chapterId: 'weeb-ch-2',
        mangaTitle: 'Initial D',
        chapterNumber: '2',
        chapterTitle: 'Chapter 2',
        page: 15,
        totalPages: 25,
      );

      final targetChapters = [
        const ChapterItem(id: 'md-ch-1', number: '1', title: 'Ch 1'),
        const ChapterItem(id: 'md-ch-2', number: '2', title: 'Ch 2'),
        const ChapterItem(id: 'md-ch-3', number: '3', title: 'Ch 3'),
      ];

      // Execute migration
      await ApiService.instance.migrateOrCopyReadingProgress(
        sourceMangaId: sourceMangaId,
        targetManga: targetManga,
        targetChapters: targetChapters,
      );

      // Chapters 1 and 2 should now be marked read on target manga
      final readChapters = ApiService.instance.historyRepo.getReadChapterIds(targetManga.id);
      expect(readChapters.contains('md-ch-1'), isTrue);
      expect(readChapters.contains('md-ch-2'), isTrue);
      expect(readChapters.contains('md-ch-3'), isFalse);

      // Target manga should have reading progress on chapter 2
      final progress = ApiService.instance.historyRepo.localProgress[targetManga.id];
      expect(progress, isNotNull);
      expect(progress!.chapterId, equals('md-ch-2'));
      expect(progress.page, equals(15));
    });
  });

  group('Duplicate UI Sheets Widget Tests', () {
    testWidgets('Possible duplicates sheet displays items and "+ Add anyway"', (tester) async {
      final target = const MangaItem(
        id: 'md:initial-d',
        title: 'Initial D',
        cover: 'https://example.com/c1.jpg',
      );
      final duplicate = const MangaItem(
        id: 'weeb:initial-d',
        title: 'Initial D',
        authors: ['SHIGENO Shuichi'],
        status: 'Completed',
        source: 'weebcentral',
        cover: 'https://example.com/c2.jpg',
      );

      ApiService.instance.recordChapterCount(duplicate.id, 724);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showPossibleDuplicatesSheet(
                    context: context,
                    targetManga: target,
                    duplicates: [duplicate],
                  );
                },
                child: const Text('Open Sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      expect(find.text('Possible duplicates'), findsOneWidget);
      expect(find.textContaining('You have entries in your library with a similar name'), findsOneWidget);
      expect(find.text('724 chapters'), findsOneWidget);
      expect(find.text('SHIGENO Shuichi'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('WeebCentral'), findsOneWidget);
      expect(find.text('Add anyway'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      // Tap Cancel
      await tester.ensureVisible(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Possible duplicates'), findsNothing);
    });

    testWidgets('Select data to include sheet displays checkboxes and triggers Copy and Migrate', (tester) async {
      final target = const MangaItem(
        id: 'md:initial-d',
        title: 'Initial D',
        cover: 'https://example.com/c1.jpg',
      );
      final duplicate = const MangaItem(
        id: 'weeb:initial-d',
        title: 'Initial D',
        authors: ['SHIGENO Shuichi'],
        source: 'weebcentral',
        cover: 'https://example.com/c2.jpg',
      );

      await ApiService.instance.addToLibrary(duplicate);
      await ApiService.instance.setMangaCategories(duplicate.id, ['reading'], manga: duplicate);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showSelectDataToIncludeSheet(
                    context: context,
                    targetManga: target,
                    duplicateManga: duplicate,
                  );
                },
                child: const Text('Open Include Sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Include Sheet'));
      await tester.pumpAndSettle();

      expect(find.text('Select data to include'), findsOneWidget);
      expect(find.text('Chapters'), findsOneWidget);
      expect(find.text('Categories'), findsOneWidget);
      expect(find.text('Show entry'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Migrate'), findsOneWidget);

      // Tap Migrate
      await tester.tap(find.text('Migrate'));
      await tester.pumpAndSettle();

      // On migrate, target is added to library with categories, and duplicate is removed!
      expect(ApiService.instance.libraryRepo.isInLibrary(target.id), isTrue);
      expect(ApiService.instance.getMangaCategoryIds(target.id), contains('reading'));
      expect(ApiService.instance.libraryRepo.isInLibrary(duplicate.id), isFalse);
    });

    testWidgets('Resolve duplicates sheet renders without overflow on narrow screens', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final group = [
        const MangaItem(
          id: 'weeb:initial-d',
          title: 'Initial D',
          source: 'weebcentral',
          cover: 'https://example.com/c1.jpg',
        ),
        const MangaItem(
          id: 'md:initial-d',
          title: 'Initial D (Official)',
          source: 'mangadex',
          cover: 'https://example.com/c2.jpg',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showLibraryDuplicatesSheet(
                    context: context,
                    duplicateGroups: {'initial d': group},
                    onRefresh: () {},
                  );
                },
                child: const Text('Open Resolve Sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Resolve Sheet'));
      await tester.pumpAndSettle();

      expect(find.text('Resolve Duplicates'), findsOneWidget);
      expect(find.text('1 groups'), findsOneWidget);
      expect(find.text('Migrate to this'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
