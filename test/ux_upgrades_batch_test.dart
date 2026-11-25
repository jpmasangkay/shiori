import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:manga_reader/display_settings.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/screens/detail_screen.dart';
import 'package:manga_reader/screens/history_screen.dart';
import 'package:manga_reader/services/api_service.dart';
import 'package:manga_reader/services/reader_settings.dart';
import 'package:manga_reader/theme.dart';
import 'package:manga_reader/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ImageReferers.resetForTesting();
    await displaySettings.init();
    await ReaderSettings.instance.init();
    await ApiService.instance.init();
  });

  test('Native page cache holds >80 webtoon strips in RAM without re-fetching when going back', () async {
    var networkCalls = 0;
    final sampleBytes = Uint8List.fromList(List<int>.filled(256, 7));

    for (var i = 0; i < 90; i++) {
      final url = 'https://cdn.example.com/ch1/page_$i.jpg';
      ImageReferers.registerSourceConfig(
        [url],
        preferNative: true,
        nativeLoader: (_) async {
          networkCalls++;
          return sampleBytes;
        },
      );
      final res = await ImageReferers.fetchNativeBytes(url);
      expect(
        res,
        isNotNull,
        reason: 'i=$i hasLoader=${ImageReferers.hasNativeLoader(url)} calls=$networkCalls',
      );
    }
    expect(networkCalls, 90);

    // Going back to early pages (page 0..10) hits RAM cache with 0 extra network calls
    for (var i = 0; i < 15; i++) {
      final url = 'https://cdn.example.com/ch1/page_$i.jpg';
      expect(ImageReferers.getCachedNativeBytes(url), isNotNull);
      await ImageReferers.fetchNativeBytes(url);
    }
    expect(networkCalls, 90);
  });

  test('DisplaySettings setSort toggles ascending/descending and persists excluded update categories', () async {
    await displaySettings.setSort(LibrarySort.alphabetical);
    expect(displaySettings.sort, LibrarySort.alphabetical);
    expect(displaySettings.sortAscending, isTrue);

    // Tapping active sort reverses direction
    await displaySettings.setSort(LibrarySort.alphabetical);
    expect(displaySettings.sortAscending, isFalse);

    // Switching to unreadCount defaults to descending (highest unread first)
    await displaySettings.setSort(LibrarySort.unreadCount);
    expect(displaySettings.sort, LibrarySort.unreadCount);
    expect(displaySettings.sortAscending, isFalse);

    // Excluded update categories toggle cleanly
    await displaySettings.toggleExcludedUpdateCategory('completed');
    expect(displaySettings.excludedUpdateCategoryIds, contains('completed'));
    await displaySettings.toggleExcludedUpdateCategory('completed');
    expect(displaySettings.excludedUpdateCategoryIds, isNot(contains('completed')));
  });

  test('ReaderSettings persists webtoonTapScroll, skipDuplicateChapters, and orientation', () async {
    final rs = ReaderSettings.instance;
    await rs.setWebtoonTapScroll(true);
    await rs.setSkipDuplicateChapters(false);
    await rs.setOrientation(ReaderOrientation.portrait);

    await rs.init();
    expect(rs.webtoonTapScroll, isTrue);
    expect(rs.skipDuplicateChapters, isFalse);
    expect(rs.orientation, ReaderOrientation.portrait);
  });

  testWidgets('DetailScreen supports chapter multi-select with range selection and bulk mark read', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    const manga = MangaItem(
      id: 'ext:test::multi_select',
      title: 'Multi Select Manga',
      cover: '',
      type: 'manga',
    );
    final chapters = const [
      ChapterItem(id: 'ch_3', number: '3', title: 'Third'),
      ChapterItem(id: 'ch_2', number: '2', title: 'Second'),
      ChapterItem(id: 'ch_1', number: '1', title: 'First'),
    ];
    await ApiService.instance.addToLibrary(manga);
    await ApiService.instance.libraryRepo.cacheChapters(manga.id, chapters);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const DetailScreen(manga: manga),
      ),
    );
    await tester.pumpAndSettle();

    // Promoted WebView action button is visible in action row (and N/A is hidden)
    expect(find.text('WebView'), findsOneWidget);
    expect(find.text('N/A'), findsNothing);

    // Long-press Chapter 3 to enter multi-select mode
    await tester.longPress(find.textContaining('Third'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    // Tap Chapter 1 to add it, then tap Range to include Chapter 2
    await tester.tap(find.textContaining('First'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.text('Range'));
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);

    // Bulk mark all 3 selected chapters as read
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();

    expect(find.text('3 selected'), findsNothing);
    expect(ApiService.instance.isChapterRead(manga.id, 'ch_1'), isTrue);
    expect(ApiService.instance.isChapterRead(manga.id, 'ch_2'), isTrue);
    expect(ApiService.instance.isChapterRead(manga.id, 'ch_3'), isTrue);
  });

  testWidgets('HistoryScreen groups entries under Today and Earlier date headers', (tester) async {
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'shiori_local_history': jsonEncode([
        {
          'mangaId': 'ext:test::hist_today',
          'chapterId': 'ch_today',
          'mangaTitle': 'Today Manga',
          'cover': '',
          'source': 'mangadex',
          'chapterNumber': '5',
          'chapterTitle': 'Today Ch',
          'page': 3,
          'totalPages': 20,
          'completed': false,
          'updatedAt': now.toIso8601String(),
        },
        {
          'mangaId': 'ext:test::hist_old',
          'chapterId': 'ch_old',
          'mangaTitle': 'Old Manga',
          'cover': '',
          'source': 'mangadex',
          'chapterNumber': '1',
          'chapterTitle': 'Old Ch',
          'page': 1,
          'totalPages': 10,
          'completed': true,
          'updatedAt': now.subtract(const Duration(days: 14)).toIso8601String(),
        },
      ]),
    });
    await ApiService.instance.init();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const Scaffold(body: HistoryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Earlier'), findsOneWidget);
    expect(find.text('Today Manga'), findsOneWidget);
    expect(find.text('Old Manga'), findsOneWidget);
  });
}
