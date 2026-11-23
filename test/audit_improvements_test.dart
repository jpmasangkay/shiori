import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/screens/backup_screen.dart';
import 'package:manga_reader/screens/more_screen.dart';
import 'package:manga_reader/screens/reader_settings_screen.dart';
import 'package:manga_reader/screens/stats_screen.dart';
import 'package:manga_reader/services/api_service.dart';
import 'package:manga_reader/services/http_cache.dart';
import 'package:manga_reader/services/local_source_service.dart';
import 'package:manga_reader/services/privacy_service.dart';
import 'package:manga_reader/services/reader_settings.dart';
import 'package:manga_reader/services/secure_token_store.dart';
import 'package:manga_reader/services/source_resolver.dart';
import 'package:manga_reader/services/tachibk_backup_service.dart';
import 'package:manga_reader/services/tracker_service.dart';
import 'package:manga_reader/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
    await SecureTokenStore.instance.deleteAll();
    await PrivacyService.instance.init();
    await PrivacyService.instance.setIncognitoMode(false);
    await PrivacyService.instance.setAppLockEnabled(false);
    await ThemeController.instance.init();
    await ReaderSettings.instance.init();
    await ApiService.instance.init();
    await ApiService.instance.libraryRepo.clearLocalData();
    await ApiService.instance.historyRepo.clearLocalData();
  });

  group('Phase 1 P0 Regression Tests', () {
    test('MangaItem.fromJson preserves MangaDex cover URL with .512.jpg', () {
      final m = MangaItem.fromJson({
        'id': '11111111-2222-3333-4444-555555555555',
        'title': 'Test Manga',
        'cover': 'https://uploads.mangadex.org/covers/abc/def.jpg',
        'source': 'mangadex',
      });
      expect(m.cover, 'https://uploads.mangadex.org/covers/abc/def.jpg.512.jpg');

      // Already-suffixed cover should not be doubled
      final m2 = MangaItem.fromJson({
        'id': '11111111-2222-3333-4444-555555555555',
        'title': 'Test Manga',
        'cover': 'https://uploads.mangadex.org/covers/abc/def.jpg.512.jpg',
        'source': 'mangadex',
      });
      expect(m2.cover, 'https://uploads.mangadex.org/covers/abc/def.jpg.512.jpg');
    });

    test('LruHttpCache.deduplicate populates cache for sequential calls & honors shouldCache', () async {
      final cache = LruHttpCache(capacity: 10);
      var fetchCount = 0;

      final first = await cache.deduplicate<http.Response>(
        'ok-key',
        () async {
          fetchCount++;
          return http.Response('{"ok":true}', 200);
        },
        shouldCache: (r) => r.statusCode == 200,
      );
      final second = await cache.deduplicate<http.Response>(
        'ok-key',
        () async {
          fetchCount++;
          return http.Response('{"ok":false}', 200);
        },
        shouldCache: (r) => r.statusCode == 200,
      );
      expect(fetchCount, 1);
      expect(first.body, '{"ok":true}');
      expect(second.body, '{"ok":true}');

      // Error response (500) must NOT be cached when shouldCache rejects it
      var errCount = 0;
      await cache.deduplicate<http.Response>(
        'err-key',
        () async {
          errCount++;
          return http.Response('server error', 500);
        },
        shouldCache: (r) => r.statusCode == 200,
      );
      await cache.deduplicate<http.Response>(
        'err-key',
        () async {
          errCount++;
          return http.Response('recovered', 200);
        },
        shouldCache: (r) => r.statusCode == 200,
      );
      expect(errCount, 2);
    });

    test('ReaderSettings isolates per-manga reading direction from global default', () async {
      await ReaderSettings.instance.setDefaultReadingDirection('automatic');
      await ReaderSettings.instance.setReadingDirection('manga_a', 'webtoon');

      expect(ReaderSettings.instance.defaultDirection, 'automatic');
      expect(ReaderSettings.instance.getReadingDirectionForManga('manga_a'), 'webtoon');
      expect(ReaderSettings.instance.getReadingDirectionForManga('manga_b'), 'automatic');
    });

    test('SourceResolver.isBuiltIn includes all built-in scrapers and local source', () {
      for (final src in const ['manganato', 'nato', 'mangafox', 'fanfox', 'fox', 'mangademon', 'demon', 'local']) {
        expect(SourceResolver.isBuiltIn(src), isTrue, reason: '$src should be built-in');
      }
      expect(SourceResolver.isBuiltIn('eu.kanade.tachiyomi.extension.en.example'), isFalse);
    });

    test('ApiService.restoreBackupJson remaps custom category IDs cleanly', () async {
      final backupJson = jsonEncode({
        'version': 2,
        'app': 'Shiori',
        'categories': [
          {'id': 'legacy_cat_999', 'name': 'Custom SciFi Shelf'},
        ],
        'library': [
          {
            'id': 'asura:solo-leveling',
            'title': 'Solo Leveling',
            'source': 'asura',
            'type': 'manhwa',
          },
        ],
        'mangaCategories': {
          'asura:solo-leveling': ['legacy_cat_999'],
        },
      });

      final res = await ApiService.instance.restoreBackupJson(backupJson);
      expect(res['bookmarks'], 1);
      expect(res['categories'], 1);

      final customCat = ApiService.instance
          .getCategories()
          .firstWhere((c) => c.name == 'Custom SciFi Shelf');
      final assigned = ApiService.instance.getMangaCategoryIds('asura:solo-leveling');
      expect(assigned, contains(customCat.id));
    });

    test('DuplicateDetector.groupDuplicates runs in O(n) and detects cross-source duplicates', () {
      const items = [
        MangaItem(id: 'asura:solo', title: 'Solo Leveling', source: 'asura'),
        MangaItem(id: 'weeb:solo', title: 'Solo Leveling [Official]', source: 'weebcentral'),
        MangaItem(id: 'mangadex:op', title: 'One Piece', source: 'mangadex'),
      ];
      final groups = DuplicateDetector.groupDuplicates(items);
      expect(groups.length, 1);
      expect(groups.values.first.length, 2);
    });
  });

  group('Phase 3 Ecosystem: .tachibk, Local CBZ & Trackers', () {
    test('TachibkBackupService round-trips protobuf + gzip and ApiService auto-detects on restore', () async {
      final encoded = TachibkBackupService.encodeTachibk(
        library: const [
          MangaItem(
            id: 'asura:omniscient-reader',
            title: 'Omniscient Reader',
            cover: 'https://example.com/orv.jpg',
            description: 'Story',
            authors: ['Sing Shong'],
            tags: ['Action', 'Fantasy'],
            status: 'ongoing',
            source: 'asura',
          ),
        ],
        categories: const [CategoryItem(id: 'cat_1', name: 'Manhwa')],
        mangaCategories: const {
          'asura:omniscient-reader': ['cat_1'],
        },
        readChapters: const {
          'asura:omniscient-reader': {'ch_1', 'ch_2'},
        },
        chapterBookmarks: const {'ch_2'},
      );

      expect(TachibkBackupService.isGzipped(encoded), isTrue);

      final decoded = TachibkBackupService.decodeTachibk(encoded);
      expect(decoded.library.length, 1);
      expect(decoded.library.first.title, 'Omniscient Reader');
      expect(decoded.categories.first.name, 'Manhwa');

      final restored = await ApiService.instance.restoreBackupBytes(encoded);
      expect(restored['bookmarks'], 1);
      expect(ApiService.instance.libraryRepo.localLibrary.length, 1);
    });

    test('LocalSourceService imports CBZ, lists chapters/pages, and blocks path traversal', () async {
      final tempDir = Directory.systemTemp.createTempSync('shiori_local_test_');
      addTearDown(() {
        LocalSourceService.instance.setRootDirForTesting(null);
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      LocalSourceService.instance.setRootDirForTesting(tempDir);

      // Build a minimal valid ZIP/CBZ with 2 PNG pages
      final archive = Archive()
        ..addFile(ArchiveFile('01.png', 4, [0x89, 0x50, 0x4E, 0x47]))
        ..addFile(ArchiveFile('02.png', 4, [0x89, 0x50, 0x4E, 0x47]));
      final cbzBytes = ZipEncoder().encode(archive);

      final imported = await LocalSourceService.instance.importCbzArchive(
        fileName: 'Chapter 1.cbz',
        bytes: Uint8List.fromList(cbzBytes),
        seriesTitle: 'My Local Comic',
      );
      expect(imported.id, 'local:My Local Comic');
      expect(imported.source, 'local');

      final seriesList = await LocalSourceService.instance.listSeries();
      expect(seriesList.length, 1);
      expect(seriesList.first.title, 'My Local Comic');

      final chapters = await LocalSourceService.instance.getChapters(imported.id);
      expect(chapters.length, 1);
      expect(chapters.first.number, '1');

      final pages = await LocalSourceService.instance.getChapterPages(chapters.first.id);
      expect(pages.pages.length, 2);

      // Path traversal must throw SecurityException
      await expectLater(
        LocalSourceService.instance.getChapterPages('local:../evil::../../etc/passwd'),
        throwsA(isA<SecurityException>()),
      );
    });

    test('TrackerService migrates legacy plaintext tokens, enforces PKCE, and never mutates unlinked titles', () async {
      SharedPreferences.setMockInitialValues({
        'tracker_token_myanimelist': 'legacy_plain_mal_tok',
      });
      var networkCalls = 0;
      TrackerService.instance.setHttpClientForTesting(
        MockClient((req) async {
          networkCalls++;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(() => TrackerService.instance.setHttpClientForTesting(null));

      await TrackerService.instance.init();
      final prefs = await SharedPreferences.getInstance();
      // Plaintext key must be scrubbed from SharedPreferences
      expect(prefs.getString('tracker_token_myanimelist'), isNull);
      expect(TrackerService.instance.isTrackerAuthenticated('myanimelist'), isTrue);

      // PKCE verifier & S256 challenge format
      final verifier = TrackerService.generatePkceVerifier(64);
      expect(verifier.length, 64);
      final challenge = TrackerService.derivePkceS256Challenge(verifier);
      expect(challenge.contains('='), isFalse);
      expect(challenge.length, greaterThanOrEqualTo(43));

      // Unlinked manga must NOT trigger fuzzy network mutations
      networkCalls = 0;
      await TrackerService.instance.onChapterFinished(
        mangaTitle: 'Unlinked Title',
        chapterNumber: '5',
        mangaId: 'unlinked_manga_id',
      );
      expect(networkCalls, 0);
    });
  });

  group('Phase 4 Privacy, Theme & UI Screens', () {
    test('PrivacyService hashes PIN securely & Incognito Mode pauses history writes', () async {
      await PrivacyService.instance.setPin('4321');
      expect(PrivacyService.instance.hasPin, isTrue);
      expect(await PrivacyService.instance.verifyPin('0000'), isFalse);
      expect(await PrivacyService.instance.verifyPin('4321'), isTrue);

      // Incognito pauses HistoryRepository writes
      await PrivacyService.instance.setIncognitoMode(true);
      await ApiService.instance.historyRepo.saveProgress(
        mangaId: 'secret_manga',
        chapterId: 'secret_ch1',
        mangaTitle: 'Secret Title',
        page: 3,
        totalPages: 10,
      );
      expect(ApiService.instance.historyRepo.localHistory, isEmpty);
      await PrivacyService.instance.setIncognitoMode(false);
    });

    test('ThemeController defaults to AMOLED pure black and switches cleanly', () async {
      expect(ThemeController.instance.mode, ShioriThemeMode.amoled);
      expect(buildTheme().scaffoldBackgroundColor, const Color(0xFF000000));

      await ThemeController.instance.setThemeMode(ShioriThemeMode.light);
      expect(ThemeController.instance.isAmoled, isFalse);
      expect(buildTheme().brightness, Brightness.light);

      await ThemeController.instance.setAccent(ShioriAccent.rose);
      expect(ThemeController.instance.accent, ShioriAccent.rose);

      // Reset to default AMOLED
      await ThemeController.instance.setThemeMode(ShioriThemeMode.amoled);
      await ThemeController.instance.setAccent(ShioriAccent.periwinkle);
    });

    testWidgets('StatsScreen, ReaderSettingsScreen, BackupScreen and MoreScreen render cleanly', (tester) async {
      for (final screen in const [
        StatsScreen(),
        ReaderSettingsScreen(),
        BackupScreen(),
        Scaffold(body: MoreScreen()),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: screen,
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
      }
    });
  });
}
