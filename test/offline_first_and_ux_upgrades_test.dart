import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:manga_reader/display_settings.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/screens/detail_screen.dart';
import 'package:manga_reader/screens/library_screen.dart';
import 'package:manga_reader/services/api_service.dart';
import 'package:manga_reader/services/connectivity_service.dart';
import 'package:manga_reader/services/reader_settings.dart';
import 'package:manga_reader/services/secure_token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SecureTokenStore.instance.deleteAll();
    ConnectivityService.instance.setOfflineForTesting(false);
    ApiService.instance.setHttpClient(null);
    await ApiService.instance.init();
    await ApiService.instance.logout(clearLocalData: true);
    DisplaySettings.instance.clearFilters();
  });

  tearDown(() {
    ConnectivityService.instance.setOfflineForTesting(false);
    ApiService.instance.setHttpClient(null);
  });

  group('Offline-First Local Library, Metadata & Chapter Persistence', () {
    test('getLibrary returns local items immediately without blocking on slow network', () async {
      await ApiService.instance.addToLibrary(
        const MangaItem(
          id: 'asura:solo-leveling',
          title: 'Solo Leveling',
          description: 'Ten years ago, after the Gate...',
          authors: ['Chugong'],
          tags: ['Action', 'Fantasy'],
          cover: 'https://example.com/solo.jpg',
          type: 'manhwa',
        ),
      );

      await ApiService.instance.auth.saveAuthData(
        'jwt_tok',
        const UserAccount(id: 'u1', email: 'u@test.com', displayName: 'User'),
      );

      // Simulate a very slow network connection (e.g. 5 seconds delay)
      ApiService.instance.setHttpClient(
        MockClient((request) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return http.Response(jsonEncode({'items': []}), 200);
        }),
      );

      final sw = Stopwatch()..start();
      final items = await ApiService.instance.getLibrary();
      sw.stop();

      expect(items.length, 1);
      expect(items.first.title, 'Solo Leveling');
      // Must return in < 200ms without waiting for the 5-second cloud request!
      expect(sw.elapsedMilliseconds, lessThan(200));
    });

    test('Cloud bookmark sync preserves local description, authors, tags, and year', () async {
      await ApiService.instance.addToLibrary(
        const MangaItem(
          id: 'weeb:berserk',
          title: 'Berserk',
          description: 'Guts, known as the Black Swordsman...',
          authors: ['Kentaro Miura'],
          tags: ['Dark Fantasy', 'Seinen'],
          year: '1989',
          cover: 'https://example.com/berserk.jpg',
          type: 'manga',
          status: 'Ongoing',
        ),
      );

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/library')) {
          // Cloud payload only has minimal bookmark fields
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'mangaId': 'weeb:berserk',
                  'title': 'Berserk',
                  'cover': 'https://example.com/berserk.jpg',
                  'type': 'manga',
                  'status': 'Ongoing',
                  'latestChapter': '376',
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
        'http://localhost:3000/api',
        {},
      );

      final synced = ApiService.instance.libraryRepo.localLibrary['weeb:berserk']!;
      expect(synced.description, 'Guts, known as the Black Swordsman...');
      expect(synced.authors, ['Kentaro Miura']);
      expect(synced.tags, ['Dark Fantasy', 'Seinen']);
      expect(synced.year, '1989');
      expect(synced.lastChapter, '376');
    });

    test('Chapter lists are persisted locally across restarts and served when offline or network fails', () async {
      const mangaId = 'asura:omniscient-reader';
      final chapters = [
        const ChapterItem(id: '$mangaId:ch-2', number: '2', title: 'Episode 2', pages: 42),
        const ChapterItem(id: '$mangaId:ch-1', number: '1', title: 'Episode 1', pages: 50),
      ];

      await ApiService.instance.libraryRepo.cacheChapters(mangaId, chapters);

      // Simulate app restart by re-initializing ApiService
      await ApiService.instance.init();

      final cachedAfterRestart = ApiService.instance.getCachedChapters(mangaId);
      expect(cachedAfterRestart.length, 2);
      expect(cachedAfterRestart.first.id, '$mangaId:ch-2');

      // Now simulate offline / failed network and verify getChapters falls back to persisted chapters
      ConnectivityService.instance.setOfflineForTesting(true);
      final offlineChapters = await ApiService.instance.getChapters(mangaId);
      expect(offlineChapters.length, 2);
      expect(offlineChapters.first.title, 'Episode 2');
    });
  });

  group('DetailScreen & LibraryScreen Offline UX Upgrades', () {
    testWidgets('DetailScreen renders cached chapters, partial page progress, chapter search, and More menu offline', (tester) async {
      const manga = MangaItem(
        id: 'asura:solo-leveling',
        title: 'Solo Leveling',
        description: 'A locally cached synopsis available offline.',
        authors: ['Chugong'],
        tags: ['Action', 'Dungeon'],
        cover: 'https://example.com/solo.jpg',
        type: 'manhwa',
        status: 'Completed',
      );
      final chapters = [
        const ChapterItem(id: 'asura:solo-leveling:ch-10', number: '10', title: 'Dungeon Boss'),
        const ChapterItem(id: 'asura:solo-leveling:ch-9', number: '9', title: 'Raid Begins'),
      ];

      await ApiService.instance.addToLibrary(manga);
      await ApiService.instance.libraryRepo.cacheChapters(manga.id, chapters);
      await ApiService.instance.saveProgress(
        mangaId: manga.id,
        chapterId: 'asura:solo-leveling:ch-10',
        mangaTitle: manga.title,
        chapterNumber: '10',
        chapterTitle: 'Dungeon Boss',
        page: 14,
        totalPages: 40,
        completed: false,
      );

      // Go offline before opening DetailScreen
      ConnectivityService.instance.setOfflineForTesting(true);

      await tester.pumpWidget(
        const MaterialApp(
          home: DetailScreen(manga: manga),
        ),
      );
      await tester.pump();

      // Cached synopsis and chapters appear immediately on Frame 0!
      expect(find.textContaining('A locally cached synopsis available offline.'), findsOneWidget);
      expect(find.textContaining('Dungeon Boss'), findsOneWidget);
      expect(find.textContaining('Raid Begins'), findsOneWidget);
      // Inline partial page progress is displayed on chapter 10
      expect(find.textContaining('Page 14/40'), findsOneWidget);

      // Test Chapter Search button
      final searchChBtn = find.byTooltip('Search chapters');
      expect(searchChBtn, findsOneWidget);
      await tester.tap(searchChBtn);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Raid');
      await tester.pumpAndSettle();
      expect(find.textContaining('Raid Begins'), findsOneWidget);
      expect(find.textContaining('Dungeon Boss'), findsNothing);

      // Test More Options button on DetailScreen
      await tester.tap(find.byTooltip('More').first);
      await tester.pumpAndSettle();
      expect(find.text('Refresh Metadata & Chapters'), findsOneWidget);
      expect(find.text('Open in WebView'), findsOneWidget);
      expect(find.text('Share Title'), findsOneWidget);
    });

    testWidgets('LibraryScreen search bar filters library items by title, author, or tag', (tester) async {
      await ApiService.instance.addToLibrary(
        const MangaItem(
          id: 'm1',
          title: 'Vagabond',
          authors: ['Takehiko Inoue'],
          tags: ['Samurai', 'Historical'],
        ),
      );
      await ApiService.instance.addToLibrary(
        const MangaItem(
          id: 'm2',
          title: 'Chainsaw Man',
          authors: ['Tatsuki Fujimoto'],
          tags: ['Action', 'Supernatural'],
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: LibraryScreen())),
      );
      await tester.pump();

      // Both render immediately on frame 0
      expect(find.text('Vagabond'), findsOneWidget);
      expect(find.text('Chainsaw Man'), findsOneWidget);

      // Open in-library search bar
      await tester.tap(find.byTooltip('Search library'));
      await tester.pumpAndSettle();

      // Search by author name
      await tester.enterText(find.byType(TextField), 'Inoue');
      await tester.pumpAndSettle();
      expect(find.text('Vagabond'), findsOneWidget);
      expect(find.text('Chainsaw Man'), findsNothing);
    });
  });

  group('Complete Backup v2 Export & Restore & Data Saver Settings', () {
    test('Backup v2 exports and restores categories, read chapters, chapter bookmarks, and cached chapters', () async {
      const manga = MangaItem(
        id: 'asura:solo',
        title: 'Solo Leveling',
        description: 'Full description',
        tags: ['Action'],
      );
      final cat = await ApiService.instance.createCategory('Masterpieces');
      await ApiService.instance.addToLibrary(manga);
      await ApiService.instance.setMangaCategories(manga.id, [cat.id], manga: manga);
      await ApiService.instance.markChaptersRead(manga.id, ['ch1', 'ch2'], read: true);
      await ApiService.instance.setChapterBookmarked('ch2', true);
      await ApiService.instance.libraryRepo.cacheChapters(
        manga.id,
        const [
          ChapterItem(id: 'ch1', number: '1', title: 'Ch 1'),
          ChapterItem(id: 'ch2', number: '2', title: 'Ch 2'),
        ],
      );

      final exported = await ApiService.instance.exportBackupJson();

      // Wipe all local data
      await ApiService.instance.libraryRepo.clearLocalData();
      await ApiService.instance.historyRepo.clearLocalData();
      expect(ApiService.instance.isInLibrary(manga.id), isFalse);
      expect(ApiService.instance.getCachedChapters(manga.id), isEmpty);

      // Restore backup
      final res = await ApiService.instance.restoreBackupJson(exported);
      expect(res['bookmarks'], 1);
      expect(ApiService.instance.isInLibrary(manga.id), isTrue);
      expect(ApiService.instance.isChapterRead(manga.id, 'ch1'), isTrue);
      expect(ApiService.instance.isChapterRead(manga.id, 'ch2'), isTrue);
      expect(ApiService.instance.isChapterBookmarked('ch2'), isTrue);
      expect(ApiService.instance.getCachedChapters(manga.id).length, 2);
      expect(
        ApiService.instance.getCategories().any((c) => c.name == 'Masterpieces'),
        isTrue,
      );
    });

    test('ReaderSettings persists Data Saver and Immersive Fullscreen settings', () async {
      await ReaderSettings.instance.setDataSaver(true);
      await ReaderSettings.instance.setImmersiveFullscreen(false);

      expect(ReaderSettings.instance.dataSaver, isTrue);
      expect(ReaderSettings.instance.immersiveFullscreen, isFalse);

      await ReaderSettings.instance.init();
      expect(ReaderSettings.instance.dataSaver, isTrue);
      expect(ReaderSettings.instance.immersiveFullscreen, isFalse);
    });
  });

  group('Cloud Sync Integrity with Local-First Caching', () {
    test('getMangaProgress merges newer cloud lastRead and completedChapterIds when online', () async {
      await ApiService.instance.auth.saveAuthData(
        'token_sync_1',
        const UserAccount(id: 'u1', email: 'test@shiori.app', displayName: 'Reader'),
      );
      await ApiService.instance.saveProgress(
        mangaId: 'asura:solo',
        chapterId: 'ch1',
        mangaTitle: 'Solo Leveling',
        chapterNumber: '1',
        page: 5,
        totalPages: 20,
        completed: false,
      );

      final newerCloudTime = DateTime.now().add(const Duration(minutes: 5)).toIso8601String();
      ApiService.instance.setHttpClient(
        MockClient((request) async {
          if (request.url.path.contains('/api/progress/manga/')) {
            return http.Response(
              jsonEncode({
                'mangaId': 'asura:solo',
                'lastRead': {
                  'mangaId': 'asura:solo',
                  'chapterId': 'ch5',
                  'mangaTitle': 'Solo Leveling',
                  'chapterNumber': '5',
                  'chapterTitle': 'Awakening',
                  'page': 18,
                  'totalPages': 30,
                  'completed': false,
                  'updatedAt': newerCloudTime,
                },
                'completedChapterIds': ['ch1', 'ch2', 'ch3', 'ch4'],
                'completedChapters': 4,
                'progressMap': {
                  'ch5': {'page': 18, 'totalPages': 30, 'completed': false},
                },
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );

      final progress = await ApiService.instance.getMangaProgress('asura:solo');
      expect(progress['completedChapters'], hasLength(4));
      expect(ApiService.instance.isChapterRead('asura:solo', 'ch4'), isTrue);
      expect(progress['lastRead']['chapterId'], 'ch5');
      expect(progress['lastRead']['page'], 18);
    });

    test('Offline mark-as-unread and unbookmark are preserved during cloud merge and flushed to cloud', () async {
      await ApiService.instance.auth.saveAuthData(
        'token_sync_2',
        const UserAccount(id: 'u1', email: 'test@shiori.app', displayName: 'Reader'),
      );

      // Start with ch1 & ch2 read, and ch1 bookmarked
      await ApiService.instance.markChaptersRead('asura:solo', ['ch1', 'ch2'], read: true);
      await ApiService.instance.setChapterBookmarked('ch1', true);

      // Go offline and mark ch2 unread + unbookmark ch1
      ConnectivityService.instance.setOfflineForTesting(true);
      await ApiService.instance.markChaptersRead('asura:solo', ['ch2'], read: false);
      await ApiService.instance.setChapterBookmarked('ch1', false);

      expect(ApiService.instance.isChapterRead('asura:solo', 'ch2'), isFalse);
      expect(ApiService.instance.isChapterBookmarked('ch1'), isFalse);

      var flushedUnread = false;
      var flushedBookmarks = false;

      ApiService.instance.setHttpClient(
        MockClient((request) async {
          if (request.url.path.endsWith('/api/progress/read-status') && request.method == 'POST') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            if (body['read'] == false && (body['chapterIds'] as List).contains('ch2')) {
              flushedUnread = true;
            }
            return http.Response('{"ok":true}', 200);
          }
          if (request.url.path.endsWith('/api/progress/chapter-bookmarks') && request.method == 'PUT') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            if (!(body['chapterBookmarks'] as List).contains('ch1')) {
              flushedBookmarks = true;
            }
            return http.Response('{"ok":true}', 200);
          }
          if (request.url.path.endsWith('/api/progress/sync')) {
            // Simulate cloud still having old state (ch2 read, ch1 bookmarked) before upload finishes
            return http.Response(
              jsonEncode({
                'history': [],
                'readChaptersByManga': {
                  'asura:solo': ['ch1', 'ch2'],
                },
                'chapterBookmarks': ['ch1'],
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );

      // Reconnect to online
      ConnectivityService.instance.setOfflineForTesting(false);
      await ApiService.instance.syncAllCloudData();

      // Offline tombstones prevent cloud merge from resurrecting ch2 as read or ch1 as bookmarked
      expect(ApiService.instance.isChapterRead('asura:solo', 'ch1'), isTrue);
      expect(ApiService.instance.isChapterRead('asura:solo', 'ch2'), isFalse);
      expect(ApiService.instance.isChapterBookmarked('ch1'), isFalse);
      expect(flushedUnread, isTrue);
      expect(flushedBookmarks, isTrue);
    });
  });
}
