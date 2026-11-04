import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/api_service.dart';
import 'package:manga_reader/services/history_repository.dart';
import 'package:manga_reader/services/secure_token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await SecureTokenStore.instance.deleteAll();
    await ApiService.instance.init();
    await ApiService.instance.logout(clearLocalData: true);
  });

  group('Security & Token Store Tests (#7, #8, #36)', () {
    test(
      'SecureTokenStore securely stores, retrieves, and clears tokens',
      () async {
        final store = SecureTokenStore.instance;
        await store.write('auth_token', 'jwt_token_123');
        await store.write('refresh_token', 'refresh_token_456');

        expect(await store.read('auth_token'), 'jwt_token_123');
        expect(await store.read('refresh_token'), 'refresh_token_456');

        await store.delete('auth_token');
        expect(await store.read('auth_token'), isNull);
        expect(await store.read('refresh_token'), 'refresh_token_456');

        await store.deleteAll();
        expect(await store.read('refresh_token'), isNull);
      },
    );

    test(
      'AuthService refreshes session token with server upon request',
      () async {
        var refreshCalled = false;

        ApiService.instance.setMockClient(
          MockClient((request) async {
            if (request.url.path == '/api/auth/refresh') {
              refreshCalled = true;
              return http.Response(
                jsonEncode({
                  'token': 'new_refreshed_jwt',
                  'user': {
                    'id': 'user_1',
                    'email': 'test@shiori.app',
                    'displayName': 'Reader',
                  },
                }),
                200,
              );
            }
            return http.Response(jsonEncode({}), 200);
          }),
        );

        // Pre-seed an active token
        await ApiService.instance.auth.saveAuthData(
          'current_jwt',
          const UserAccount(
            id: 'user_1',
            email: 'test@shiori.app',
            displayName: 'Reader',
          ),
        );

        final success = await ApiService.instance.auth.refreshSession();
        expect(success, isTrue);
        expect(refreshCalled, isTrue);
        expect(ApiService.instance.auth.token, 'new_refreshed_jwt');
        expect(ApiService.instance.isLoggedIn, isTrue);
      },
    );

    test('401 triggers session expired state in AuthService', () async {
      await ApiService.instance.auth.saveAuthData(
        'expired_jwt',
        const UserAccount(
          id: 'user_1',
          email: 'test@shiori.app',
          displayName: 'Reader',
        ),
      );

      expect(ApiService.instance.isSessionExpired, isFalse);
      ApiService.instance.auth.handleUnauthorized();

      expect(ApiService.instance.isSessionExpired, isTrue);

      ApiService.instance.clearSessionExpiredBanner();
      expect(ApiService.instance.isSessionExpired, isFalse);
    });
  });

  group('History Repository Timestamp-Based Merge (#31, #6)', () {
    test(
      'Merging history entries prioritizes higher updatedAt timestamp',
      () async {
        final repo = HistoryRepository();
        final prefs = await SharedPreferences.getInstance();
        await repo.init(prefs);

        final olderTime = DateTime(2026, 1, 1, 10, 0);
        final newerTime = DateTime(2026, 1, 1, 12, 0);

        final remoteNewer = {
          'mangaId': 'solo-leveling',
          'chapterId': 'ch-2',
          'mangaTitle': 'Solo Leveling',
          'chapterTitle': 'Chapter 2',
          'chapterNumber': '2',
          'page': 18,
          'totalPages': 20,
          'updatedAt': newerTime.toIso8601String(),
        };

        await repo.saveProgress(
          mangaId: 'solo-leveling',
          chapterId: 'ch-1',
          mangaTitle: 'Solo Leveling',
          chapterNumber: '1',
          page: 5,
          totalPages: 20,
          updatedAt: olderTime,
        );

        // Merge remote list
        repo.mergeRemoteHistory([remoteNewer]);

        final entries = repo.getHistoryEntries();
        expect(entries.length, 1);
        // Newer chapter should have won
        expect(entries.first.chapterId, 'ch-2');
        expect(entries.first.page, 18);
      },
    );

    test(
      'Local entry with newer timestamp is not overwritten by older remote entry',
      () async {
        final repo = HistoryRepository();
        final prefs = await SharedPreferences.getInstance();
        await repo.init(prefs);

        final localTime = DateTime(2026, 2, 1, 14, 0);
        final remoteOlderTime = DateTime(2026, 2, 1, 10, 0);

        await repo.saveProgress(
          mangaId: 'one-piece',
          chapterId: 'ch-1100',
          mangaTitle: 'One Piece',
          chapterNumber: '1100',
          page: 15,
          totalPages: 19,
          updatedAt: localTime,
        );

        final remoteOlder = {
          'mangaId': 'one-piece',
          'chapterId': 'ch-1099',
          'mangaTitle': 'One Piece',
          'chapterTitle': 'Chapter 1099',
          'chapterNumber': '1099',
          'page': 1,
          'totalPages': 19,
          'updatedAt': remoteOlderTime.toIso8601String(),
        };

        repo.mergeRemoteHistory([remoteOlder]);

        final entries = repo.getHistoryEntries();
        expect(entries.length, 1);
        expect(entries.first.chapterId, 'ch-1100');
      },
    );
  });

  group('Cloud Sync Enhancements (#11, #32, #33, #34, #35)', () {
    test('Batch library and progress upload sends all pending items', () async {
      var batchLibraryPayload = <String, dynamic>{};
      var batchProgressPayload = <String, dynamic>{};
      var categoriesPayload = <String, dynamic>{};

      ApiService.instance.setMockClient(
        MockClient((request) async {
          if (request.url.path == '/api/library/batch') {
            batchLibraryPayload =
                jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({'items': batchLibraryPayload['items'] ?? []}),
              200,
            );
          }
          if (request.url.path == '/api/progress/batch') {
            batchProgressPayload =
                jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(jsonEncode({'success': true}), 200);
          }
          if (request.url.path == '/api/library/categories') {
            if (request.method == 'PUT') {
              categoriesPayload =
                  jsonDecode(request.body) as Map<String, dynamic>;
            }
            return http.Response(
              jsonEncode({'categories': categoriesPayload['categories'] ?? []}),
              200,
            );
          }
          if (request.url.path == '/api/progress/sync') {
            return http.Response(
              jsonEncode({
                'history': [],
                'completed': [],
                'chapterBookmarks': ['c2_cloud'],
              }),
              200,
            );
          }
          if (request.url.path == '/api/library') {
            return http.Response(jsonEncode({'items': []}), 200);
          }
          return http.Response(jsonEncode({}), 200);
        }),
      );

      // Add local items
      await ApiService.instance.addToLibrary(
        const MangaItem(
          id: 'm1',
          title: 'Manga One',
          cover: 'http://c.com/1.jpg',
        ),
      );
      await ApiService.instance.addToLibrary(
        const MangaItem(
          id: 'm2',
          title: 'Manga Two',
          cover: 'http://c.com/2.jpg',
        ),
      );
      await ApiService.instance.saveProgress(
        mangaId: 'm1',
        chapterId: 'c1',
        mangaTitle: 'Manga One',
        chapterNumber: '1',
        page: 10,
        totalPages: 20,
      );
      await ApiService.instance.markChapterRead('m1', 'c1', read: true);
      await ApiService.instance.toggleChapterBookmark('c1');
      await ApiService.instance.addCategory('Action');

      // Set logged in
      await ApiService.instance.auth.saveAuthData(
        'valid_token',
        const UserAccount(
          id: 'u1',
          email: 'test@shiori.app',
          displayName: 'Reader',
        ),
      );

      final synced = await ApiService.instance.syncNow();
      expect(synced, isTrue);

      // Verify batch payloads
      final libItems = batchLibraryPayload['items'] as List?;
      expect(libItems, isNotNull);
      expect(libItems!.length, 2);

      final progressItems = batchProgressPayload['entries'] as List?;
      expect(progressItems, isNotNull);
      expect(progressItems!.length, 1);
      expect(progressItems.first['chapterId'], 'c1');

      final readChapters =
          batchProgressPayload['readChaptersByManga'] as Map<String, dynamic>?;
      expect(readChapters, isNotNull);
      expect(readChapters!['m1'], contains('c1'));

      final chapterBookmarks =
          batchProgressPayload['chapterBookmarks'] as List?;
      expect(chapterBookmarks, isNotNull);
      expect(chapterBookmarks, contains('c1'));
      expect(ApiService.instance.isChapterBookmarked('c2_cloud'), isTrue);
    });

    test('markChapterRead and markChaptersRead send real-time cloud read-status', () async {
      final calls = <Map<String, dynamic>>[];

      ApiService.instance.setMockClient(
        MockClient((request) async {
          if (request.url.path == '/api/progress/read-status') {
            calls.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(jsonEncode({'success': true}), 200);
          }
          return http.Response(jsonEncode({}), 200);
        }),
      );

      // Pre-seed an active token
      await ApiService.instance.auth.saveAuthData(
        'current_jwt',
        const UserAccount(
          id: 'user_1',
          email: 'test@shiori.app',
          displayName: 'Reader',
        ),
      );

      // Single chapter mark read
      await ApiService.instance.markChapterRead('manga_x', 'ch_1', read: true);
      expect(ApiService.instance.isChapterRead('manga_x', 'ch_1'), isTrue);

      // Multiple chapters mark read
      await ApiService.instance.markChaptersRead('manga_x', ['ch_2', 'ch_3'], read: true);
      expect(ApiService.instance.isChapterRead('manga_x', 'ch_2'), isTrue);
      expect(ApiService.instance.isChapterRead('manga_x', 'ch_3'), isTrue);

      // Mark single chapter unread
      await ApiService.instance.markChapterRead('manga_x', 'ch_1', read: false);
      expect(ApiService.instance.isChapterRead('manga_x', 'ch_1'), isFalse);

      // Check calls were recorded
      expect(calls.length, 3);
      expect(calls[0]['chapterId'], 'ch_1');
      expect(calls[0]['read'], isTrue);
      expect(calls[1]['chapterIds'], ['ch_2', 'ch_3']);
      expect(calls[1]['read'], isTrue);
      expect(calls[2]['chapterId'], 'ch_1');
      expect(calls[2]['read'], isFalse);
    });

    test('syncCategoriesWithCloud downloads and preserves cloud custom categories', () async {
      var uploadedCategories = <dynamic>[];

      ApiService.instance.setMockClient(
        MockClient((request) async {
          if (request.url.path == '/api/library/categories') {
            if (request.method == 'GET') {
              return http.Response(
                jsonEncode({
                  'categories': [
                    {'id': 'reading', 'name': 'Reading', 'order': 0},
                    {'id': 'cat_cloud_custom', 'name': 'Sci-Fi Cloud', 'order': 1},
                  ],
                  'mangaCategories': {
                    'manga_1': ['cat_cloud_custom'],
                  },
                }),
                200,
              );
            }
            if (request.method == 'PUT') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              uploadedCategories = body['categories'] as List<dynamic>? ?? [];
              return http.Response(jsonEncode({'success': true}), 200);
            }
          }
          return http.Response(jsonEncode({}), 200);
        }),
      );

      // Pre-seed an active token
      await ApiService.instance.auth.saveAuthData(
        'current_jwt',
        const UserAccount(
          id: 'user_1',
          email: 'test@shiori.app',
          displayName: 'Reader',
        ),
      );

      // Create a local custom category
      await ApiService.instance.addCategory('Local Shonen');

      // Sync categories with cloud
      await ApiService.instance.libraryRepo.syncCategoriesWithCloud(
        ApiService.instance.httpManager.client,
        ApiService.instance.baseUrl,
        ApiService.instance.auth.headers(withAuth: true),
      );

      final currentCats = ApiService.instance.getCategories();
      final catNames = currentCats.map((c) => c.name).toSet();

      // Cloud category must be merged
      expect(catNames, contains('Sci-Fi Cloud'));
      // Local category must be preserved
      expect(catNames, contains('Local Shonen'));

      // Both must have been uploaded to cloud
      final uploadedNames = uploadedCategories.map((c) => (c as Map)['name']).toSet();
      expect(uploadedNames, contains('Sci-Fi Cloud'));
      expect(uploadedNames, contains('Local Shonen'));
    });

    test('downloadLibraryBookmarks does not overwrite valid covers with empty string or file URI', () async {
      ApiService.instance.setMockClient(
        MockClient((request) async {
          if (request.url.path == '/api/library') {
            return http.Response(
              jsonEncode({
                'items': [
                  {
                    'mangaId': 'manga_with_local_cover',
                    'title': 'Test Manga',
                    'cover': '', // Empty in cloud
                  },
                  {
                    'mangaId': 'manga_with_file_cover',
                    'title': 'Test Manga 2',
                    'cover': 'file:///deviceA/data/cover.jpg', // Local path on device A
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(jsonEncode({}), 200);
        }),
      );

      // Pre-seed local library with valid remote covers
      await ApiService.instance.addToLibrary(
        const MangaItem(
          id: 'manga_with_local_cover',
          title: 'Test Manga',
          cover: 'https://cdn.example.com/cover1.jpg',
        ),
      );
      await ApiService.instance.addToLibrary(
        const MangaItem(
          id: 'manga_with_file_cover',
          title: 'Test Manga 2',
          cover: 'https://cdn.example.com/cover2.jpg',
        ),
      );

      await ApiService.instance.libraryRepo.downloadLibraryBookmarks(
        ApiService.instance.httpManager.client,
        ApiService.instance.baseUrl,
        ApiService.instance.auth.headers(withAuth: true),
      );

      final lib = ApiService.instance.libraryRepo.localLibrary;
      expect(lib['manga_with_local_cover']?.cover, 'https://cdn.example.com/cover1.jpg');
      expect(lib['manga_with_file_cover']?.cover, 'https://cdn.example.com/cover2.jpg');
    });
  });

  group('Privacy Logout Wipe (#38)', () {
    test(
      'Logout with clearLocalData: false preserves local library and history',
      () async {
        await ApiService.instance.addToLibrary(
          const MangaItem(
            id: 'm1',
            title: 'Manga One',
            cover: 'http://c.com/1.jpg',
          ),
        );
        await ApiService.instance.saveProgress(
          mangaId: 'm1',
          chapterId: 'c1',
          mangaTitle: 'Manga One',
          page: 5,
          totalPages: 10,
        );

        await ApiService.instance.logout(clearLocalData: false);

        final lib = await ApiService.instance.getLibrary();
        final hist = await ApiService.instance.getHistory();
        expect(lib.length, 1);
        expect(hist.length, 1);
        expect(ApiService.instance.isLoggedIn, isFalse);
      },
    );

    test(
      'Logout with clearLocalData: true completely wipes local data from device',
      () async {
        await ApiService.instance.addToLibrary(
          const MangaItem(
            id: 'm1',
            title: 'Manga One',
            cover: 'http://c.com/1.jpg',
          ),
        );
        await ApiService.instance.saveProgress(
          mangaId: 'm1',
          chapterId: 'c1',
          mangaTitle: 'Manga One',
          page: 5,
          totalPages: 10,
        );
        await ApiService.instance.addCategory('Custom Genre');

        await ApiService.instance.logout(clearLocalData: true);

        final lib = await ApiService.instance.getLibrary();
        final hist = await ApiService.instance.getHistory();
        expect(lib, isEmpty);
        expect(hist, isEmpty);
        expect(
          ApiService.instance.getCategories().where(
            (c) => c.name == 'Custom Genre',
          ),
          isEmpty,
        );
        expect(ApiService.instance.isLoggedIn, isFalse);
      },
    );
  });
}
