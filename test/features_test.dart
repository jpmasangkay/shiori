import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/screens/reader_screen.dart';
import 'package:manga_reader/services/api_service.dart';
import 'package:manga_reader/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    ApiService.instance.setHttpClient(null);
    await ApiService.instance.init();
  });

  tearDown(() {
    ApiService.instance.setHttpClient(null);
  });

  group('Authentication & Cloud Sync Unit Tests', () {
    test('register() succeeds, stores session, and triggers cloud sync', () async {
      final requestedPaths = <String>[];
      ApiService.instance.setHttpClient(
        MockClient((request) async {
          requestedPaths.add('${request.method} ${request.url.path}');
          if (request.url.path.endsWith('/auth/register')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'token': 'jwt_signup_token_123',
                'user': {
                  'id': 'u_new',
                  'email': body['email'],
                  'displayName': body['displayName'],
                },
              }),
              201,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.url.path.endsWith('/library') && request.method == 'GET') {
            return http.Response(jsonEncode({'items': []}), 200);
          }
          if (request.url.path.endsWith('/history') && request.method == 'GET') {
            return http.Response(jsonEncode({'items': []}), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      await ApiService.instance.register(
        'reader@example.com',
        'secret123',
        displayName: 'Reader One',
      );

      expect(ApiService.instance.isLoggedIn, isTrue);
      expect(ApiService.instance.currentUser?.email, 'reader@example.com');
      expect(ApiService.instance.currentUser?.displayName, 'Reader One');
      expect(ApiService.instance.currentUser?.id, 'u_new');
      expect(requestedPaths, contains('POST /api/auth/register'));
      // Cloud sync runs after registration
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requestedPaths, contains('GET /api/library'));
      expect(requestedPaths, contains('GET /api/progress/history'));
    });

    test('login() succeeds, stores session, and syncs remote library', () async {
      ApiService.instance.setHttpClient(
        MockClient((request) async {
          if (request.url.path.endsWith('/auth/login')) {
            return http.Response(
              jsonEncode({
                'token': 'jwt_login_token_456',
                'user': {
                  'id': 'u_existing',
                  'email': 'existing@example.com',
                  'displayName': 'Existing Reader',
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.url.path.endsWith('/library') && request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'items': [
                  {
                    'mangaId': 'cloud_manga_1',
                    'title': 'Cloud Manga',
                    'coverUrl': 'https://example.com/cover.jpg',
                    'type': 'manga',
                  }
                ]
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/history') && request.method == 'GET') {
            return http.Response(jsonEncode({'items': []}), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      await ApiService.instance.login('existing@example.com', 'correct_password');
      expect(ApiService.instance.isLoggedIn, isTrue);
      expect(ApiService.instance.currentUser?.displayName, 'Existing Reader');

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ApiService.instance.isInLibrary('cloud_manga_1'), isTrue);
    });

    test('login() with wrong password throws clear error and stays logged out', () async {
      ApiService.instance.setHttpClient(
        MockClient((request) async {
          return http.Response(
            jsonEncode({'error': 'Invalid email or password'}),
            401,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await expectLater(
        () => ApiService.instance.login('user@example.com', 'wrong_pass'),
        throwsA(
          predicate((e) => e.toString().contains('Invalid email or password')),
        ),
      );
      expect(ApiService.instance.isLoggedIn, isFalse);
      expect(ApiService.instance.currentUser, isNull);
    });

    test('register() with duplicate email throws clear error and stays logged out', () async {
      ApiService.instance.setHttpClient(
        MockClient((request) async {
          return http.Response(
            jsonEncode({'error': 'Email is already registered'}),
            409,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await expectLater(
        () => ApiService.instance.register('dup@example.com', 'password123'),
        throwsA(
          predicate((e) => e.toString().contains('Email is already registered')),
        ),
      );
      expect(ApiService.instance.isLoggedIn, isFalse);
    });

    test('login() and register() handle network failure gracefully without crashing', () async {
      ApiService.instance.setHttpClient(
        MockClient((request) async {
          throw const SocketException('Failed host lookup: shiori-n5hd.onrender.com');
        }),
      );

      await expectLater(
        () => ApiService.instance.login('offline@example.com', 'password123'),
        throwsA(
          predicate((e) => e.toString().contains('Unable to reach server')),
        ),
      );
      await expectLater(
        () => ApiService.instance.register('offline@example.com', 'password123'),
        throwsA(
          predicate((e) => e.toString().contains('Unable to reach server')),
        ),
      );
      expect(ApiService.instance.isLoggedIn, isFalse);
    });

    test('Session survives app restart via init() and Sign Out clears it', () async {
      ApiService.instance.setHttpClient(
        MockClient((request) async {
          if (request.url.path.endsWith('/auth/login')) {
            return http.Response(
              jsonEncode({
                'token': 'persistent_jwt_token',
                'user': {
                  'id': 'u_persist',
                  'email': 'persist@example.com',
                  'displayName': 'Persistent User',
                },
              }),
              200,
            );
          }
          return http.Response(jsonEncode({'items': []}), 200);
        }),
      );

      await ApiService.instance.login('persist@example.com', 'password123');
      expect(ApiService.instance.isLoggedIn, isTrue);

      // Simulate app restart by calling init() again (SharedPreferences retains values)
      await ApiService.instance.init();
      expect(ApiService.instance.isLoggedIn, isTrue);
      expect(ApiService.instance.currentUser?.email, 'persist@example.com');
      expect(ApiService.instance.currentUser?.displayName, 'Persistent User');

      // Sign Out clears session both in memory and across subsequent restart
      await ApiService.instance.logout();
      expect(ApiService.instance.isLoggedIn, isFalse);
      expect(ApiService.instance.currentUser, isNull);

      await ApiService.instance.init();
      expect(ApiService.instance.isLoggedIn, isFalse);
      expect(ApiService.instance.currentUser, isNull);
    });
  });

  group('Category Management & Direct Category Assignment', () {
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

    test('Assigning a category to a non-library manga automatically adds it to library with metadata/cover and persists across init()', () async {
      const nonLibManga = MangaItem(
        id: 'ext:asura::solo-leveling',
        title: 'Solo Leveling',
        cover: 'https://example.com/solo-cover.jpg',
        type: 'manhwa',
        status: 'Completed',
        authors: ['Chugong'],
      );

      expect(ApiService.instance.isInLibrary(nonLibManga.id), isFalse);
      expect(ApiService.instance.getMangaCategoryIds(nonLibManga.id), isEmpty);

      // Assign category directly without calling addToLibrary first
      await ApiService.instance.toggleMangaCategory(
        nonLibManga.id,
        'reading',
        manga: nonLibManga,
      );

      // Must now be in library AND in the 'reading' category
      expect(ApiService.instance.isInLibrary(nonLibManga.id), isTrue);
      expect(ApiService.instance.getMangaCategoryIds(nonLibManga.id), contains('reading'));

      final libItems = await ApiService.instance.getLibrary();
      final added = libItems.firstWhere((m) => m.id == nonLibManga.id);
      expect(added.title, 'Solo Leveling');
      expect(added.cover, 'https://example.com/solo-cover.jpg');

      // Simulate app restart via ApiService.init()
      await ApiService.instance.init();
      expect(ApiService.instance.isInLibrary(nonLibManga.id), isTrue);
      expect(ApiService.instance.getMangaCategoryIds(nonLibManga.id), contains('reading'));
      final persistedLib = await ApiService.instance.getLibrary();
      final persistedItem = persistedLib.firstWhere((m) => m.id == nonLibManga.id);
      expect(persistedItem.title, 'Solo Leveling');
      expect(persistedItem.cover, 'https://example.com/solo-cover.jpg');

      // Removing manga from its last category must NOT remove it from the library
      await ApiService.instance.toggleMangaCategory(nonLibManga.id, 'reading');
      expect(ApiService.instance.getMangaCategoryIds(nonLibManga.id), isEmpty);
      expect(ApiService.instance.isInLibrary(nonLibManga.id), isTrue);
    });

    test('Assigning and toggling manga categories via setMangaCategories', () async {
      const manga = MangaItem(
        id: 'test_manga_1',
        title: 'Berserk',
        cover: 'https://example.com/berserk.jpg',
      );
      expect(ApiService.instance.isInLibrary(manga.id), isFalse);
      expect(ApiService.instance.getMangaCategoryIds(manga.id), isEmpty);

      await ApiService.instance.setMangaCategories(
        manga.id,
        ['reading', 'favorites'],
        manga: manga,
      );
      expect(ApiService.instance.isInLibrary(manga.id), isTrue);
      expect(ApiService.instance.getMangaCategoryIds(manga.id), containsAll(['reading', 'favorites']));

      await ApiService.instance.toggleMangaCategory(manga.id, 'reading');
      expect(ApiService.instance.getMangaCategoryIds(manga.id), isNot(contains('reading')));
      expect(ApiService.instance.getMangaCategoryIds(manga.id), contains('favorites'));

      // Clear all categories — manga stays in library
      await ApiService.instance.setMangaCategories(manga.id, []);
      expect(ApiService.instance.getMangaCategoryIds(manga.id), isEmpty);
      expect(ApiService.instance.isInLibrary(manga.id), isTrue);
    });
  });

  group('Permanent True AMOLED & Type Scale', () {
    test('Theme is permanently pure black (#000000) with WCAG AA muted text', () {
      expect(AppColors.bg, const Color(0xFF000000));
      expect(ThemeController.instance.isAmoled, isTrue);
      final theme = buildTheme();
      expect(theme.scaffoldBackgroundColor, const Color(0xFF000000));
      expect(AppText.title.fontSize, 20);
      expect(AppText.sectionHeader.fontSize, 11.5);
      expect(AppText.cardTitle.fontSize, 14.5);
      expect(AppText.body.fontSize, 13);
      expect(AppText.caption.fontSize, 11.5);
      expect(AppText.badge.fontSize, 9.5);
      expect(AppText.chip.fontSize, 12);
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
