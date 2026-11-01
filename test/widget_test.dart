import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manga_reader/main.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/screens/detail_screen.dart';
import 'package:manga_reader/screens/library_screen.dart';
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

  Future<void> boot(WidgetTester tester, {double textScale = 1.0}) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await tester.pumpWidget(const ShioriApp());
    await tester.pumpAndSettle();
  }

  testWidgets('Library tab renders with empty state', (tester) async {
    await boot(tester);
    expect(find.text('Library'), findsWidgets);
    expect(find.text('Your library is empty'), findsOneWidget);
  });

  testWidgets('Display sheet opens and changes columns/mode', (tester) async {
    await boot(tester);
    await tester.tap(find.byTooltip('Filter, sort and display'));
    await tester.pumpAndSettle();
    expect(find.text('Display mode'.toUpperCase()), findsOneWidget);

    await tester.tap(find.text('List'));
    await tester.pumpAndSettle();
  });

  testWidgets('Updates tab renders', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Updates'));
    await tester.pumpAndSettle();
    expect(find.text('No recent updates'), findsOneWidget);
  });

  testWidgets('Browse tab renders', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Browse'));
    await tester.pumpAndSettle();
    expect(find.text('Browse'), findsWidgets);
  });

  testWidgets('More tab renders with clean auth card, no AMOLED toggle, inline error on bad credentials, and hides cloud sync card when signed in', (tester) async {
    await boot(tester);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Guest User'), findsOneWidget);
    expect(find.text('Sign In / Create Account'), findsOneWidget);
    expect(find.text('Sign in to sync', skipOffstage: false), findsOneWidget);
    expect(find.text('Offline Backup & File Export', skipOffstage: false), findsOneWidget);
    expect(find.text('True AMOLED Pure Black', skipOffstage: false), findsNothing);
    expect(find.text('Extensions', skipOffstage: false), findsOneWidget);

    var shouldFail = true;
    ApiService.instance.setHttpClient(
      MockClient((request) async {
        if (request.url.path.endsWith('/auth/login')) {
          if (shouldFail) {
            return http.Response(
              jsonEncode({'error': 'Invalid email or password'}),
              401,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'token': 'tok_123',
              'user': {
                'id': 'u_1',
                'email': 'pro@shiori.app',
                'displayName': 'Pro Reader',
              },
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'items': []}), 200);
      }),
    );

    await tester.tap(find.text('Sign In / Create Account'));
    await tester.pumpAndSettle();

    // 1. Test bad password shows inline error and clears loading state
    final textFields = find.byType(TextField);
    await tester.enterText(textFields.at(0), 'pro@shiori.app');
    await tester.enterText(textFields.at(1), 'wrong_password');
    await tester.tap(find.text('Sign In & Sync Now'));
    await tester.pumpAndSettle();

    expect(find.text('Invalid email or password'), findsOneWidget);
    expect(find.text('Sign In & Sync Now'), findsOneWidget); // Loading spinner cleared

    // 2. Test valid credentials sign in and close modal
    shouldFail = false;
    await tester.enterText(textFields.at(1), 'password123');
    await tester.tap(find.text('Sign In & Sync Now'));
    await tester.pumpAndSettle();

    // Signed in: user is shown, "Cloud Sync Active" / "Automatic Cloud Sync" / "Sign in to sync" are hidden,
    // and no sync toast/banner is shown.
    expect(find.text('Pro Reader'), findsOneWidget);
    expect(find.text('Cloud Sync Active', skipOffstage: false), findsNothing);
    expect(find.text('AUTOMATIC CLOUD SYNC', skipOffstage: false), findsNothing);
    expect(find.text('Sign in to sync', skipOffstage: false), findsNothing);
    expect(find.text('Offline Backup & File Export', skipOffstage: false), findsOneWidget);
  });

  testWidgets('Manage Categories at 320x640 viewport with 15 categories and 60-char name has no overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Add a 60-character category name plus enough categories to total >= 15
    final longName = 'A' * 60;
    await ApiService.instance.createCategory(longName);
    while (ApiService.instance.getCategories().length < 15) {
      final idx = ApiService.instance.getCategories().length + 1;
      await ApiService.instance.createCategory('Custom Category Number $idx With Extra Label');
    }
    expect(ApiService.instance.getCategories().length, greaterThanOrEqualTo(15));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const Scaffold(body: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Manage categories'));
    await tester.pumpAndSettle();

    expect(find.text('MANAGE CATEGORIES'), findsOneWidget);
    expect(find.text(longName), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Scroll through the 15 categories inside the bounded sheet
    await tester.drag(find.byType(ListView).last, const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Assigning a category from DetailScreen adds non-library manga to library and category', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    const manga = MangaItem(
      id: 'ext:test::omniscient-reader',
      title: 'Omniscient Reader',
      cover: 'https://example.com/orv.jpg',
      type: 'manhwa',
    );
    expect(ApiService.instance.isInLibrary(manga.id), isFalse);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const DetailScreen(manga: manga),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Add to Library'), findsOneWidget);

    await tester.tap(find.text('Categories'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reading'));
    await tester.pumpAndSettle();

    expect(ApiService.instance.isInLibrary(manga.id), isTrue);
    expect(ApiService.instance.getMangaCategoryIds(manga.id), contains('reading'));
    expect(find.text('In Library', skipOffstage: false), findsOneWidget);
  });

  testWidgets('Titles put in a category are removed from All tab and restored when uncategorized', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    const mangaA = MangaItem(
      id: 'ext:test::manga_a',
      title: 'Chainsaw Man',
      cover: 'https://example.com/csm.jpg',
      type: 'manga',
    );
    const mangaB = MangaItem(
      id: 'ext:test::manhwa_b',
      title: 'Solo Leveling',
      cover: 'https://example.com/solo.jpg',
      type: 'manhwa',
    );

    await ApiService.instance.addToLibrary(mangaA);
    await ApiService.instance.addToLibrary(mangaB);
    await ApiService.instance.setMangaCategories(mangaA.id, []);
    await ApiService.instance.setMangaCategories(mangaB.id, []);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const Scaffold(body: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Initially both are uncategorized, so both appear in All (2)
    expect(find.text('All 2'), findsOneWidget);
    expect(find.text('Chainsaw Man'), findsOneWidget);
    expect(find.text('Solo Leveling'), findsOneWidget);

    // Put mangaA into 'Reading' category
    await ApiService.instance.toggleMangaCategory(mangaA.id, 'reading', manga: mangaA);
    await tester.pumpAndSettle();

    // mangaA should now be REMOVED from All, leaving only mangaB in All (1)
    expect(find.text('All 1'), findsOneWidget);
    expect(find.text('Solo Leveling'), findsOneWidget);
    expect(find.text('Chainsaw Man'), findsNothing);

    // Switch to Reading tab
    await tester.tap(find.text('Reading 1'));
    await tester.pumpAndSettle();

    // mangaA is in Reading, mangaB is not
    expect(find.text('Chainsaw Man'), findsOneWidget);
    expect(find.text('Solo Leveling'), findsNothing);

    // Put mangaB into 'Completed' category
    await ApiService.instance.toggleMangaCategory(mangaB.id, 'completed', manga: mangaB);
    await tester.pumpAndSettle();

    // Switch back to All tab
    await tester.tap(find.text('All 0'));
    await tester.pumpAndSettle();

    // Both are categorized, so All has no titles and shows empty state
    expect(find.text('Chainsaw Man'), findsNothing);
    expect(find.text('Solo Leveling'), findsNothing);
    expect(find.text('No uncategorized titles'), findsOneWidget);

    // Remove mangaA from 'Reading' (clearing its category)
    await ApiService.instance.toggleMangaCategory(mangaA.id, 'reading');
    await tester.pumpAndSettle();

    // mangaA returns to All
    expect(find.text('All 1'), findsOneWidget);
    expect(find.text('Chainsaw Man'), findsOneWidget);
    expect(find.text('Solo Leveling'), findsNothing);
  });

  testWidgets('Screens render without overflow at text scale 1.3', (tester) async {
    await boot(tester, textScale: 1.3);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Updates'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Browse'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
