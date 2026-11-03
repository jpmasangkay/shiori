import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/screens/reader_screen.dart';
import 'package:manga_reader/services/api_service.dart';
import 'package:manga_reader/services/download_service.dart';
import 'package:manga_reader/services/secure_token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;
  late Directory tempDir2;

  final pngBytes = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
  ];

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
    await SecureTokenStore.instance.deleteAll();
    await ApiService.instance.init();
    await ApiService.instance.historyRepo.clearLocalData();

    // Create temporary image files for downloaded chapter 1
    tempDir = Directory.systemTemp.createTempSync('manga_test_ch1_');
    File('${tempDir.path}/01.png').writeAsBytesSync(pngBytes);
    File('${tempDir.path}/02.png').writeAsBytesSync(pngBytes);

    // Create temporary image files for downloaded chapter 2
    tempDir2 = Directory.systemTemp.createTempSync('manga_test_ch2_');
    File('${tempDir2.path}/01.png').writeAsBytesSync(pngBytes);
    File('${tempDir2.path}/02.png').writeAsBytesSync(pngBytes);

    // Mock path_provider channel
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        return tempDir.path;
      },
    );

    // Populate DownloadService manifest
    final manifest = {
      'test_ch_1': {
        'chapterId': 'test_ch_1',
        'mangaId': 'test_manga_1',
        'mangaTitle': 'Test Manga',
        'mangaCover': '',
        'chapterTitle': 'Chapter 1',
        'chapterNumber': '1',
        'pageCount': 2,
        'totalBytes': pngBytes.length * 2,
        'downloadedAt': DateTime.now().toIso8601String(),
        'directoryPath': tempDir.path,
      },
      'test_ch_2': {
        'chapterId': 'test_ch_2',
        'mangaId': 'test_manga_1',
        'mangaTitle': 'Test Manga',
        'mangaCover': '',
        'chapterTitle': 'Chapter 2',
        'chapterNumber': '2',
        'pageCount': 2,
        'totalBytes': pngBytes.length * 2,
        'downloadedAt': DateTime.now().toIso8601String(),
        'directoryPath': tempDir2.path,
      },
    };

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('shiori_downloads_manifest_v1', jsonEncode(manifest));
    await DownloadService.instance.init();
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      if (tempDir2.existsSync()) tempDir2.deleteSync(recursive: true);
    } catch (_) {}
  });

  final sampleChapters = [
    const ChapterItem(id: 'test_ch_1', number: '1', title: 'Chapter 1'),
    const ChapterItem(id: 'test_ch_2', number: '2', title: 'Chapter 2'),
  ];

  group('Smooth Scrolling & Page Turn Jitter Elimination', () {
    testWidgets('ZoomablePageWrapper disables panning when scale is 1.0 (unzoomed)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ZoomablePageWrapper(
              child: Container(
                key: const ValueKey('zoom_box'),
                width: 300,
                height: 400,
                color: Colors.blue,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // In unzoomed state (scale 1.0), panEnabled should be false so PageView gestures are smooth
      var iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
      expect(iv.panEnabled, isFalse);

      // Double tap to zoom in
      final target = find.byKey(const ValueKey('zoom_box'));
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(target);
      await tester.pumpAndSettle();

      // In zoomed state (scale 2.5), panEnabled should be true to allow exploring the page
      iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
      expect(iv.panEnabled, isTrue);

      // Double tap to zoom out
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(target);
      await tester.pumpAndSettle();

      iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
      expect(iv.panEnabled, isFalse);
    });
  });

  group('Auto-Mark As Read on Chapter Completion', () {
    test('verify ApiService.instance.getChapterPages', () async {
      final res = await ApiService.instance.getChapterPages('test_ch_1');
      expect(res.pages.length, 2);
      expect(res.pages.first, startsWith('file://'));
    });

    testWidgets('Chapter is initially unread', (tester) async {
      expect(ApiService.instance.isChapterRead('test_manga_1', 'test_ch_1'), isFalse);
      expect(ApiService.instance.isChapterRead('test_manga_1', 'test_ch_2'), isFalse);
    });

    testWidgets('Paged mode marks chapter as read when reaching the final page', (tester) async {
      expect(ApiService.instance.isChapterRead('test_manga_1', 'test_ch_1'), isFalse);

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            mangaId: 'test_manga_1',
            mangaTitle: 'Test Manga',
            mangaType: 'manhua', // LTR mode
            chapters: sampleChapters,
            initialIndex: 0,
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      // Page 1 is displayed initially (not final page since total is 2)
      expect(ApiService.instance.isChapterRead('test_manga_1', 'test_ch_1'), isFalse);

      // Advance to page 2 (the final page of chapter 1)
      final pageView = find.byType(PageView);
      expect(pageView, findsOneWidget);

      // In LTR, fling left to go to next page
      await tester.fling(pageView, const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();

      // Chapter 1 should now be auto-marked as read
      expect(ApiService.instance.isChapterRead('test_manga_1', 'test_ch_1'), isTrue);
    });

    testWidgets('Webtoon mode marks chapter as read when extending to next chapter', (tester) async {
      expect(ApiService.instance.isChapterRead('test_manga_1', 'test_ch_1'), isFalse);

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            mangaId: 'test_manga_1',
            mangaTitle: 'Solo Leveling',
            mangaType: 'manhwa',
            chapters: sampleChapters,
            initialIndex: 0,
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(ApiService.instance.isChapterRead('test_manga_1', 'test_ch_1'), isFalse);

      // In webtoon mode, tap the next chapter button at the bottom of the chapter
      final nextButton = find.textContaining('Next:');
      expect(nextButton, findsOneWidget);

      await tester.tap(nextButton);
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      // Chapter 1 is marked as read
      expect(ApiService.instance.isChapterRead('test_manga_1', 'test_ch_1'), isTrue);
    });

    testWidgets('Popping ReaderScreen via back button flushes progress and records completion', (tester) async {
      expect(ApiService.instance.isChapterRead('test_manga_1', 'test_ch_1'), isFalse);

      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: key,
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    ctx,
                    MaterialPageRoute(
                      builder: (_) => ReaderScreen(
                        mangaId: 'test_manga_1',
                        mangaTitle: 'Test Manga',
                        mangaType: 'manhua',
                        chapters: sampleChapters,
                        initialIndex: 0,
                      ),
                    ),
                  );
                },
                child: const Text('Open Reader'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open reader
      await tester.tap(find.text('Open Reader'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      // Fling to page 2 (final page)
      final pageView = find.byType(PageView);
      await tester.fling(pageView, const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();

      expect(ApiService.instance.isChapterRead('test_manga_1', 'test_ch_1'), isTrue);

      // Now pop the reader screen
      key.currentState?.pop();
      await tester.pumpAndSettle();

      // Remains read after exit
      expect(ApiService.instance.isChapterRead('test_manga_1', 'test_ch_1'), isTrue);
    });

    testWidgets('Advancing to next chapter marks the previous chapter as read', (tester) async {
      expect(ApiService.instance.isChapterRead('test_manga_1', 'test_ch_1'), isFalse);

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            mangaId: 'test_manga_1',
            mangaTitle: 'Test Manga',
            mangaType: 'manhua',
            chapters: sampleChapters,
            initialIndex: 0,
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(ApiService.instance.isChapterRead('test_manga_1', 'test_ch_1'), isFalse);

      // Advance to page 2 first (so chapter 1 is completed)
      final pageView = find.byType(PageView);
      await tester.fling(pageView, const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();

      // Tap next chapter button in the bottom scrubber bar
      final nextChapterButton = find.text('Next Ch.');
      expect(nextChapterButton, findsOneWidget);

      await tester.tap(nextChapterButton);
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      // Chapter 1 is marked as read
      expect(ApiService.instance.isChapterRead('test_manga_1', 'test_ch_1'), isTrue);
    });
  });
}
