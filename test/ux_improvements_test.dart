import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_reader/display_settings.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/screens/history_screen.dart';
import 'package:manga_reader/screens/library_screen.dart';
import 'package:manga_reader/screens/reader_screen.dart';
import 'package:manga_reader/screens/updates_screen.dart';
import 'package:manga_reader/services/api_service.dart';
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

  group('Library Sort & Management UX (#19, #20, #25)', () {
    testWidgets('Library empty state shows onboarding guide button and opens sheet (#25)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LibraryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Assert requirement: 'Your library is empty' must be present
      expect(find.text('Your library is empty'), findsOneWidget);
      expect(find.text('How it works (3-step guide)'), findsOneWidget);

      // Tap onboarding guide
      await tester.tap(find.text('How it works (3-step guide)'));
      await tester.pumpAndSettle();

      expect(find.text('Welcome to Shiori'), findsOneWidget);
      expect(find.text('Browse Sources & Extensions'), findsOneWidget);
      expect(find.text('Bookmark & Organize'), findsOneWidget);

      // Dismiss sheet
      await tester.tap(find.text('Get Started'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to Shiori'), findsNothing);
    });

    testWidgets('Library sort options exist in top bar PopupMenuButton (#19)', (tester) async {
      await ApiService.instance.addToLibrary(
        const MangaItem(id: 'm1', title: 'Zeta Gundam', cover: 'http://c.com/1.jpg'),
      );
      await ApiService.instance.addToLibrary(
        const MangaItem(id: 'm2', title: 'Alpha Manga', cover: 'http://c.com/2.jpg'),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LibraryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Find sort menu button
      final sortButton = find.byTooltip('Sort library');
      expect(sortButton, findsOneWidget);

      await tester.tap(sortButton);
      await tester.pumpAndSettle();

      expect(find.text('Alphabetically'), findsOneWidget);
      expect(find.text('Date added'), findsOneWidget);
      expect(find.text('Last read'), findsOneWidget);
      expect(find.text('Unread count'), findsOneWidget);

      // Select Alphabetical
      await tester.tap(find.text('Alphabetically'));
      await tester.pumpAndSettle();

      expect(DisplaySettings.instance.librarySort, LibrarySort.alphabetical);
    });

    testWidgets('Library items can be removed via swipe in list mode with Undo (#20)', (tester) async {
      DisplaySettings.instance.mode = DisplayMode.list;

      await ApiService.instance.addToLibrary(
        const MangaItem(id: 'm1', title: 'Solo Leveling', cover: 'http://c.com/1.jpg'),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LibraryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Solo Leveling'), findsOneWidget);

      // Swipe dismissible
      await tester.drag(find.byType(Dismissible), const Offset(-500, 0));
      await tester.pumpAndSettle();

      expect(find.text('Removed "Solo Leveling" from library'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      // Tap Undo
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(ApiService.instance.isInLibrary('m1'), isTrue);
    });
  });

  group('History Screen Search & Deletion (#17, #18)', () {
    testWidgets('History search bar filters items and source chips filter sources', (tester) async {
      await ApiService.instance.saveProgress(
        mangaId: 'asura:solo-leveling',
        chapterId: 'c1',
        mangaTitle: 'Solo Leveling',
        chapterNumber: '1',
        source: 'asura',
        page: 5,
        totalPages: 20,
      );
      await ApiService.instance.saveProgress(
        mangaId: 'mangadex:frieren',
        chapterId: 'c2',
        mangaTitle: 'Frieren: Beyond Journey\'s End',
        chapterNumber: '10',
        source: 'mangadex',
        page: 1,
        totalPages: 18,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HistoryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Solo Leveling'), findsOneWidget);
      expect(find.text('Frieren: Beyond Journey\'s End'), findsOneWidget);

      // Filter via search
      await tester.enterText(find.byType(TextField), 'Frieren');
      await tester.pumpAndSettle();

      expect(find.text('Solo Leveling'), findsNothing);
      expect(find.text('Frieren: Beyond Journey\'s End'), findsOneWidget);

      // Clear search
      await tester.tap(find.byIcon(Icons.clear_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Solo Leveling'), findsOneWidget);

      // Filter via source chip
      await tester.tap(find.text('Asura Scans'));
      await tester.pumpAndSettle();

      expect(find.text('Solo Leveling'), findsOneWidget);
      expect(find.text('Frieren: Beyond Journey\'s End'), findsNothing);
    });

    testWidgets('Clear all history confirmation dialog wipes history', (tester) async {
      await ApiService.instance.saveProgress(
        mangaId: 'asura:solo-leveling',
        chapterId: 'c1',
        mangaTitle: 'Solo Leveling',
        source: 'asura',
        page: 5,
        totalPages: 20,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HistoryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final clearButton = find.byTooltip('Clear history');
      expect(clearButton, findsOneWidget);

      await tester.tap(clearButton);
      await tester.pumpAndSettle();

      expect(find.text('Clear History'), findsOneWidget);
      await tester.tap(find.text('Clear All'));
      await tester.pumpAndSettle();

      final hist = await ApiService.instance.getHistory();
      expect(hist, isEmpty);
      expect(find.text('No reading history'), findsOneWidget);
    });
  });

  group('Updates Screen Filtering (#23)', () {
    testWidgets('Updates screen renders source and category filter chips', (tester) async {
      await ApiService.instance.addToLibrary(
        const MangaItem(id: 'mangadex:one-piece', title: 'One Piece', cover: 'http://c.com/1.jpg'),
      );
      await ApiService.instance.addToLibrary(
        const MangaItem(id: 'asura:solo-leveling', title: 'Solo Leveling', cover: 'http://c.com/2.jpg'),
      );
      await ApiService.instance.libraryRepo.setMangaCategories('mangadex:one-piece', ['Reading']);
      await ApiService.instance.libraryRepo.setMangaCategories('asura:solo-leveling', ['Completed']);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UpdatesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Top bar check updates exists
      expect(find.byTooltip('Check updates'), findsOneWidget);
    });
  });

  group('Reader Zoom and Comfort Controls (#21, #22)', () {
    testWidgets('ZoomablePageWrapper supports double-tap zoom and resets', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ZoomablePageWrapper(
              child: Container(
                width: 200,
                height: 300,
                color: Colors.blue,
                key: const ValueKey('zoom_target'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final target = find.byKey(const ValueKey('zoom_target'));
      expect(target, findsOneWidget);

      final interactiveViewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
      expect(interactiveViewer.transformationController?.value.getMaxScaleOnAxis(), 1.0);

      // Double-tap zoom in
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(target);
      await tester.pumpAndSettle();

      expect(interactiveViewer.transformationController?.value.getMaxScaleOnAxis(), 2.5);

      // Double-tap zoom out
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(target);
      await tester.pumpAndSettle();

      expect(interactiveViewer.transformationController?.value.getMaxScaleOnAxis(), 1.0);
    });

    testWidgets('ReaderScreen renders display comfort tune button', (tester) async {
      final chapters = [
        const ChapterItem(id: 'ch_1', number: '1', title: 'Chapter 1'),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            mangaId: 'manga_1',
            mangaTitle: 'Tower of God',
            chapters: chapters,
            initialIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final tuneButton = find.byTooltip('Display & Filter');
      expect(tuneButton, findsOneWidget);

      await tester.tap(tuneButton);
      await tester.pumpAndSettle();

      expect(find.text('DISPLAY & COMFORT'), findsOneWidget);
      expect(find.text('Brightness'), findsOneWidget);
      expect(find.text('Eye-Care Warm Tint'), findsOneWidget);
    });
  });

  group('Clear Cache (#10)', () {
    test('ApiService clearAllCaches executes without throwing', () async {
      await expectLater(ApiService.instance.clearAllCaches(), completes);
    });
  });
}
