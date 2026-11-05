import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:manga_reader/display_settings.dart';
import 'package:manga_reader/services/reader_settings.dart';
import 'package:manga_reader/services/extension_service.dart';
import 'package:manga_reader/screens/browse_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DisplaySettings Persistence Tests', () {
    test('Persists mode, columns, categoryTabs, and sort across restarts', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = DisplaySettings.instance;

      await settings.update(() {
        settings.mode = DisplayMode.comfortableGrid;
        settings.columns = 4;
        settings.categoryTabs = false;
        settings.sort = LibrarySort.alphabetical;
      });

      // Verify immediate in-memory values
      expect(settings.mode, DisplayMode.comfortableGrid);
      expect(settings.columns, 4);
      expect(settings.categoryTabs, isFalse);
      expect(settings.sort, LibrarySort.alphabetical);

      // Verify values written to SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('library_display_mode'), 'comfortableGrid');
      expect(prefs.getInt('library_display_columns'), 4);
      expect(prefs.getBool('library_display_category_tabs'), isFalse);
      expect(prefs.getString('library_display_sort'), 'alphabetical');

      // Simulate app restart by re-initializing DisplaySettings
      await settings.init();
      expect(settings.mode, DisplayMode.comfortableGrid);
      expect(settings.columns, 4);
      expect(settings.categoryTabs, isFalse);
      expect(settings.sort, LibrarySort.alphabetical);
    });
  });

  group('ReaderSettings Persistence Tests', () {
    test('Persists fitMode, brightness, tint, tap zones, and per-manga direction', () async {
      SharedPreferences.setMockInitialValues({});
      final reader = ReaderSettings.instance;

      await reader.setFitMode(BoxFit.contain);
      await reader.setBrightness(0.75);
      await reader.setTint(0.40);
      await reader.setEnableTapZones(false);
      await reader.setInvertTapZones(true);
      await reader.setReadingDirection('manga_123', 'webtoon');

      expect(reader.fitMode, BoxFit.contain);
      expect(reader.brightness, closeTo(0.75, 0.01));
      expect(reader.tint, closeTo(0.40, 0.01));
      expect(reader.enableTapZones, isFalse);
      expect(reader.invertTapZones, isTrue);
      expect(reader.getReadingDirectionForManga('manga_123'), 'webtoon');
      expect(reader.getReadingDirectionForManga('other_manga'), 'webtoon');

      // Verify in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('reader_fit_mode'), 'contain');
      expect(prefs.getDouble('reader_brightness'), closeTo(0.75, 0.01));
      expect(prefs.getDouble('reader_tint'), closeTo(0.40, 0.01));
      expect(prefs.getBool('reader_enable_tap_zones'), isFalse);
      expect(prefs.getBool('reader_invert_tap_zones'), isTrue);
      expect(prefs.getString('reader_direction_manga_123'), 'webtoon');

      // Simulate app restart by calling init()
      await reader.init();
      expect(reader.fitMode, BoxFit.contain);
      expect(reader.brightness, closeTo(0.75, 0.01));
      expect(reader.tint, closeTo(0.40, 0.01));
      expect(reader.enableTapZones, isFalse);
      expect(reader.invertTapZones, isTrue);
      expect(reader.getReadingDirectionForManga('manga_123'), 'webtoon');
    });
  });

  group('Browse Search Installed Sources Coverage', () {
    testWidgets('Searches every installed extension including all sub-sources without dropping any', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final extService = ExtensionService.instance;

      final multiSourceExt = MangaExtension(
        id: 'eu.kanade.tachiyomi.extension.all.mangadex',
        name: 'MangaDex',
        pkg: 'eu.kanade.tachiyomi.extension.all.mangadex',
        version: '1.4.1',
        versionCode: 1,
        libVersion: '1.4',
        apkUrl: '',
        iconUrl: '',
        lang: 'ALL',
        isNsfw: false,
        isInstalled: true,
        sourceNames: ['MangaDex EN', 'MangaDex JA', 'MangaDex KO', 'MangaDex ES', 'MangaDex ZH'],
        subSources: [
          {'id': '1', 'name': 'MangaDex (EN)', 'lang': 'EN'},
          {'id': '2', 'name': 'MangaDex (JA)', 'lang': 'JA'},
          {'id': '3', 'name': 'MangaDex (KO)', 'lang': 'KO'},
          {'id': '4', 'name': 'MangaDex (ES)', 'lang': 'ES'},
          {'id': '5', 'name': 'MangaDex (ZH)', 'lang': 'ZH'},
        ],
      );

      final singleSourceExt = MangaExtension(
        id: 'eu.kanade.tachiyomi.extension.en.asura',
        name: 'Asura Scans',
        pkg: 'eu.kanade.tachiyomi.extension.en.asura',
        version: '1.4.1',
        versionCode: 1,
        libVersion: '1.4',
        apkUrl: '',
        iconUrl: '',
        lang: 'EN',
        isNsfw: false,
        isInstalled: true,
        sourceNames: ['Asura Scans'],
        subSources: const [],
      );

      extService.setDeviceExtensionsForTesting([multiSourceExt, singleSourceExt]);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BrowseScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Deduplicates multi-language sub-sources for the same site to avoid duplicate search queries: MangaDex (EN @1) + Asura = 2
      expect(find.byType(BrowseScreen), findsOneWidget);
      final browseState = tester.state(find.byType(BrowseScreen)) as dynamic;
      final targetSources = browseState.resolveTargetSourceIdsForTesting() as List<String>;
      expect(targetSources.length, 2);
      expect(targetSources, contains('eu.kanade.tachiyomi.extension.all.mangadex@1'));
      expect(targetSources, contains('eu.kanade.tachiyomi.extension.en.asura'));
    });
  });
}
