import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:manga_reader/display_settings.dart';
import 'package:manga_reader/main.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/screens/library_screen.dart';
import 'package:manga_reader/screens/reader_screen.dart';
import 'package:manga_reader/services/api_service.dart';
import 'package:manga_reader/services/download_service.dart';
import 'package:manga_reader/services/reader_settings.dart';
import 'package:manga_reader/services/secure_token_store.dart';
import 'package:manga_reader/theme.dart';
import 'package:manga_reader/widgets/auth_modal.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final pngBytes = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ];

  late Directory tempDir1;
  late Directory tempDir2;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
    await SecureTokenStore.instance.deleteAll();
    await ThemeController.instance.init();
    await ThemeController.instance.setThemeMode(ShioriThemeMode.amoled);
    await ThemeController.instance.setAccent(ShioriAccent.periwinkle);
    await DisplaySettings.instance.init();
    await ReaderSettings.instance.init();
    await ApiService.instance.init();
    await ApiService.instance.libraryRepo.clearLocalData();
    await ApiService.instance.historyRepo.clearLocalData();

    tempDir1 = Directory.systemTemp.createTempSync('ux_test_ch1_');
    for (var p = 1; p <= 5; p++) {
      File('${tempDir1.path}/0$p.png').writeAsBytesSync(pngBytes);
    }
    tempDir2 = Directory.systemTemp.createTempSync('ux_test_ch2_');
    for (var p = 1; p <= 3; p++) {
      File('${tempDir2.path}/0$p.png').writeAsBytesSync(pngBytes);
    }

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir1.path,
    );

    final manifest = {
      'ux_ch_1': {
        'chapterId': 'ux_ch_1',
        'mangaId': 'ux_manga_1',
        'mangaTitle': 'Blade of Shiori',
        'mangaCover': '',
        'chapterTitle': 'Chapter 1',
        'chapterNumber': '1',
        'pageCount': 5,
        'totalBytes': pngBytes.length * 5,
        'downloadedAt': DateTime.now().toIso8601String(),
        'directoryPath': tempDir1.path,
      },
      'ux_ch_2': {
        'chapterId': 'ux_ch_2',
        'mangaId': 'ux_manga_1',
        'mangaTitle': 'Blade of Shiori',
        'mangaCover': '',
        'chapterTitle': 'Chapter 2',
        'chapterNumber': '2',
        'pageCount': 3,
        'totalBytes': pngBytes.length * 3,
        'downloadedAt': DateTime.now().toIso8601String(),
        'directoryPath': tempDir2.path,
      },
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('shiori_downloads_manifest_v1', jsonEncode(manifest));
    await DownloadService.instance.init();
  });

  tearDown(() async {
    await ThemeController.instance.setThemeMode(ShioriThemeMode.amoled);
    await ThemeController.instance.setAccent(ShioriAccent.periwinkle);
    try {
      if (tempDir1.existsSync()) tempDir1.deleteSync(recursive: true);
      if (tempDir2.existsSync()) tempDir2.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Dynamic Theme & Accent System', () {
    test('AppColors and AppText react dynamically to theme mode & accent changes', () async {
      await ThemeController.instance.setThemeMode(ShioriThemeMode.amoled);
      expect(AppColors.bg, AppColors.amoledBg);
      expect(AppColors.isLight, isFalse);

      await ThemeController.instance.setThemeMode(ShioriThemeMode.dark);
      expect(AppColors.bg, AppColors.slateBg);
      expect(AppColors.isLight, isFalse);

      await ThemeController.instance.setThemeMode(ShioriThemeMode.light);
      expect(AppColors.bg, AppColors.lightBg);
      expect(AppColors.isLight, isTrue);
      expect(AppText.title.color, AppColors.lightText);

      await ThemeController.instance.setAccent(ShioriAccent.emerald);
      expect(AppColors.primary, ShioriAccent.emerald.lightPrimary);

      await ThemeController.instance.setThemeMode(ShioriThemeMode.system);
      ThemeController.instance.updatePlatformBrightness(Brightness.dark);
      expect(AppColors.isLight, isFalse);
      expect(AppColors.primary, ShioriAccent.emerald.primary);

      ThemeController.instance.updatePlatformBrightness(Brightness.light);
      expect(AppColors.isLight, isTrue);
      expect(AppColors.primary, ShioriAccent.emerald.lightPrimary);
    });
  });

  group('Leave Off Where Readers Finished & Chronological Normalization', () {
    test('sortChaptersChronologically normalizes descending chapters cleanly', () {
      const desc = [
        ChapterItem(id: 'c3', number: '3', title: 'Ch 3'),
        ChapterItem(id: 'c2', number: '2', title: 'Ch 2'),
        ChapterItem(id: 'c1', number: '1', title: 'Ch 1'),
      ];
      final asc = sortChaptersChronologically(desc);
      expect(asc.map((c) => c.id).toList(), ['c1', 'c2', 'c3']);
    });

    test('resolveResumeTarget advances to next unread after finished chapter & handles caught up', () async {
      const mangaId = 'resume_manga';
      const chapters = [
        ChapterItem(id: 'c3', number: '3', title: 'Ch 3'),
        ChapterItem(id: 'c2', number: '2', title: 'Ch 2'),
        ChapterItem(id: 'c1', number: '1', title: 'Ch 1'),
      ];
      ApiService.instance.libraryRepo.cacheChapters(mangaId, chapters);

      // 1. Brand new manga -> Start Ch. 1
      var target = ApiService.instance.resolveResumeTarget(mangaId);
      expect(target.chapterId, 'c1');
      expect(target.page, 1);
      expect(target.label, 'Start Ch. 1');

      // 2. Partial read on Ch. 1 Page 4 -> Resume Ch. 1 Page 4 (NOT marked read)
      await ApiService.instance.saveProgress(
        mangaId: mangaId,
        chapterId: 'c1',
        mangaTitle: 'Test',
        chapterNumber: '1',
        page: 4,
        totalPages: 10,
        completed: false,
      );
      expect(ApiService.instance.isChapterRead(mangaId, 'c1'), isFalse);
      expect(ApiService.instance.getSavedPageForChapter(mangaId, 'c1'), 4);
      target = ApiService.instance.resolveResumeTarget(mangaId);
      expect(target.chapterId, 'c1');
      expect(target.page, 4);
      expect(target.isInProgress, isTrue);
      expect(target.label, 'Resume Ch. 1');

      // 3. Finish Ch. 1 -> leaves off at Ch. 2 Page 1!
      await ApiService.instance.markChapterRead(mangaId, 'c1', read: true);
      await ApiService.instance.saveProgress(
        mangaId: mangaId,
        chapterId: 'c1',
        mangaTitle: 'Test',
        chapterNumber: '1',
        page: 10,
        totalPages: 10,
        completed: true,
      );
      target = ApiService.instance.resolveResumeTarget(mangaId);
      expect(target.chapterId, 'c2');
      expect(target.page, 1);
      expect(target.isAfterFinishedChapter, isTrue);
      expect(target.label, 'Resume Ch. 2');

      // 4. Reader skips ahead and finishes Ch. 3 (latest) -> Read Again (does NOT jump back to Ch. 2)
      await ApiService.instance.markChapterRead(mangaId, 'c3', read: true);
      await ApiService.instance.saveProgress(
        mangaId: mangaId,
        chapterId: 'c3',
        mangaTitle: 'Test',
        chapterNumber: '3',
        page: 10,
        totalPages: 10,
        completed: true,
      );
      target = ApiService.instance.resolveResumeTarget(mangaId);
      expect(target.isCaughtUp, isTrue);
      expect(target.label, 'Read Again');

      // 5. Chapter 4 arrives -> immediately resumes Ch. 4!
      final updatedChapters = [
        const ChapterItem(id: 'c4', number: '4', title: 'Ch 4'),
        ...chapters,
      ];
      ApiService.instance.libraryRepo.cacheChapters(mangaId, updatedChapters);
      target = ApiService.instance.resolveResumeTarget(mangaId);
      expect(target.chapterId, 'c4');
      expect(target.page, 1);
      expect(target.label, 'Resume Ch. 4');
    });

    test('90% progress never marks a chapter as read until completed is true', () async {
      await ApiService.instance.saveProgress(
        mangaId: 'strict_m',
        chapterId: 'strict_c1',
        mangaTitle: 'Strict Test',
        chapterNumber: '1',
        page: 9,
        totalPages: 10,
        completed: false,
      );
      expect(ApiService.instance.isChapterRead('strict_m', 'strict_c1'), isFalse);
    });
  });

  group('Strict Read-All Tracking & RTL Scrubber in ReaderScreen', () {
    const fivePageChapters = [
      ChapterItem(id: 'ux_ch_1', number: '1', title: 'Chapter 1'),
      ChapterItem(id: 'ux_ch_2', number: '2', title: 'Chapter 2'),
    ];

    testWidgets('Skipping via Next Ch. or jumping to last page via scrubber does NOT mark read; reading all pages DOES', (tester) async {
      // Use portrait phone viewport so single-page mode is active
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          home: ReaderScreen(
            mangaId: 'ux_manga_1',
            mangaTitle: 'Blade of Shiori',
            mangaType: 'comic', // LTR single-page
            chapters: fivePageChapters,
            initialIndex: 0,
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(ApiService.instance.isChapterRead('ux_manga_1', 'ux_ch_1'), isFalse);

      // Jump straight to page 5 via slider (skipping pages 2, 3, 4)
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(5.0);
      await tester.pumpAndSettle();

      // Must NOT be marked read because pages 2, 3, 4 were skipped!
      expect(ApiService.instance.isChapterRead('ux_manga_1', 'ux_ch_1'), isFalse);

      // Tap Next Ch. while pages 2, 3, 4 were never read -> still must NOT be marked read!
      await tester.tap(find.text('Next Ch.'));
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      expect(ApiService.instance.isChapterRead('ux_manga_1', 'ux_ch_1'), isFalse);

      // Go back to Ch. 1 and visit remaining pages 2, 3, 4
      await tester.tap(find.text('Prev Ch.'));
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();

      final slider2 = tester.widget<Slider>(find.byType(Slider));
      slider2.onChanged!(2.0);
      await tester.pump();
      expect(ApiService.instance.isChapterRead('ux_manga_1', 'ux_ch_1'), isFalse);

      slider2.onChanged!(3.0);
      await tester.pump();
      expect(ApiService.instance.isChapterRead('ux_manga_1', 'ux_ch_1'), isFalse);

      // Visit the last remaining unread page (4) -> now 1, 2, 3, 4, 5 have all been viewed!
      slider2.onChanged!(4.0);
      await tester.pumpAndSettle();
      expect(ApiService.instance.isChapterRead('ux_manga_1', 'ux_ch_1'), isTrue);
    });

    testWidgets('RTL Manga mode wraps page scrubber Slider in Directionality(rtl)', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          home: ReaderScreen(
            mangaId: 'ux_manga_1',
            mangaTitle: 'Blade of Shiori',
            mangaType: 'manga', // Auto-resolves to RTL
            chapters: fivePageChapters,
            initialIndex: 0,
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      final sliderDir = tester.widget<Directionality>(
        find.ancestor(of: find.byType(Slider), matching: find.byType(Directionality)).first,
      );
      expect(sliderDir.textDirection, TextDirection.rtl);
    });
  });

  group('Library Sort, Empty CTA, Adaptive Shell & Auth UX', () {
    testWidgets('LibrarySort.lastUpdated sorts by chapter publishAt timestamps, not chapter count', (tester) async {
      const oldLongManga = MangaItem(
        id: 'm_old_long',
        title: 'Old 900-Chapter Series',
        lastChapter: '900',
      );
      const freshShortManga = MangaItem(
        id: 'm_fresh_short',
        title: 'Fresh 3-Chapter Series',
        lastChapter: '3',
      );
      await ApiService.instance.addToLibrary(oldLongManga);
      await ApiService.instance.addToLibrary(freshShortManga);
      ApiService.instance.libraryRepo.cacheChapters('m_old_long', const [
        ChapterItem(id: 'o1', number: '900', title: 'Ch 900', publishAt: '2022-01-01T00:00:00Z'),
      ]);
      ApiService.instance.libraryRepo.cacheChapters('m_fresh_short', const [
        ChapterItem(id: 'f1', number: '3', title: 'Ch 3', publishAt: '2026-10-01T00:00:00Z'),
      ]);

      displaySettings.update(() {
        displaySettings.mode = DisplayMode.list;
        displaySettings.sort = LibrarySort.lastUpdated;
        displaySettings.sortAscending = false;
      });

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: LibraryScreen())),
      );
      await tester.pumpAndSettle();

      final freshY = tester.getTopLeft(find.text('Fresh 3-Chapter Series')).dy;
      final oldY = tester.getTopLeft(find.text('Old 900-Chapter Series')).dy;
      expect(freshY, lessThan(oldY));
    });

    testWidgets('Empty Library shows Browse Sources button when callback provided', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryScreen(onBrowseSources: () => tapped = true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Browse Sources'), findsOneWidget);
      await tester.tap(find.text('Browse Sources'));
      await tester.pump();
      expect(tapped, isTrue);
    });

    testWidgets('RootShell uses NavigationRail on wide screens and NavigationBar on phones', (tester) async {
      // Wide tablet/desktop viewport -> NavigationRail
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const ShioriApp());
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      // Compact phone viewport -> NavigationBar
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('AuthModal has working password visibility toggle', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showAuthModal(ctx),
                child: const Text('Open Auth'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open Auth'));
      await tester.pumpAndSettle();

      final passFinder = find.byType(TextField).at(1);
      expect(tester.widget<TextField>(passFinder).obscureText, isTrue);

      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();
      expect(tester.widget<TextField>(passFinder).obscureText, isFalse);
    });
  });
}
