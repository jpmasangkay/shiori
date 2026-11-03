import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/screens/reader_screen.dart';
import 'package:manga_reader/services/api_service.dart';
import 'package:manga_reader/services/secure_token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await SecureTokenStore.instance.deleteAll();
    await ApiService.instance.init();
  });

  group('Automatic Reading Direction Logic (resolveAutomaticMode)', () {
    test('resolves Japanese manga to Right-to-Left (RTL)', () {
      // Direct type 'manga'
      expect(
        ReaderScreen.resolveAutomaticMode(type: 'manga'),
        equals(ReaderMode.rightToLeft),
      );

      // Uppercase type
      expect(
        ReaderScreen.resolveAutomaticMode(type: 'MANGA'),
        equals(ReaderMode.rightToLeft),
      );

      // By tag 'manga'
      expect(
        ReaderScreen.resolveAutomaticMode(tags: ['Action', 'Manga']),
        equals(ReaderMode.rightToLeft),
      );

      // By tag 'japanese'
      expect(
        ReaderScreen.resolveAutomaticMode(tags: ['Japanese']),
        equals(ReaderMode.rightToLeft),
      );

      // By MangaPill source prefix
      expect(
        ReaderScreen.resolveAutomaticMode(mangaId: 'pill:one-piece-100'),
        equals(ReaderMode.rightToLeft),
      );

      // By title annotation
      expect(
        ReaderScreen.resolveAutomaticMode(title: 'Bleach (Manga)'),
        equals(ReaderMode.rightToLeft),
      );
    });

    test('resolves Korean manhwa / manwha / webtoon to Webtoon (vertical scroll)', () {
      // Direct type 'manhwa'
      expect(
        ReaderScreen.resolveAutomaticMode(type: 'manhwa'),
        equals(ReaderMode.webtoon),
      );

      // Alternate spelling 'manwha' (as in user prompt)
      expect(
        ReaderScreen.resolveAutomaticMode(type: 'manwha'),
        equals(ReaderMode.webtoon),
      );

      // Direct type 'webtoon'
      expect(
        ReaderScreen.resolveAutomaticMode(type: 'webtoon'),
        equals(ReaderMode.webtoon),
      );

      // By tag 'manhwa'
      expect(
        ReaderScreen.resolveAutomaticMode(tags: ['Fantasy', 'Manhwa']),
        equals(ReaderMode.webtoon),
      );

      // By tag 'manwha'
      expect(
        ReaderScreen.resolveAutomaticMode(tags: ['Action', 'Manwha']),
        equals(ReaderMode.webtoon),
      );

      // By tag 'webtoon'
      expect(
        ReaderScreen.resolveAutomaticMode(tags: ['Webtoon', 'Supernatural']),
        equals(ReaderMode.webtoon),
      );

      // By tag 'korean'
      expect(
        ReaderScreen.resolveAutomaticMode(tags: ['Korean']),
        equals(ReaderMode.webtoon),
      );

      // By Asura source prefix
      expect(
        ReaderScreen.resolveAutomaticMode(mangaId: 'asura:solo-leveling-ragnarok'),
        equals(ReaderMode.webtoon),
      );

      // By Flame Comics source prefix
      expect(
        ReaderScreen.resolveAutomaticMode(mangaId: 'flame:the-beginning-after-the-end'),
        equals(ReaderMode.webtoon),
      );

      // By title annotation
      expect(
        ReaderScreen.resolveAutomaticMode(title: 'Return of the Mount Hua Sect [Manhwa]'),
        equals(ReaderMode.webtoon),
      );
    });

    test('resolves other formats (manhua, comics, unknown) to Left-to-Right (LTR)', () {
      // Chinese manhua
      expect(
        ReaderScreen.resolveAutomaticMode(type: 'manhua'),
        equals(ReaderMode.leftToRight),
      );

      expect(
        ReaderScreen.resolveAutomaticMode(tags: ['Martial Arts', 'Manhua']),
        equals(ReaderMode.leftToRight),
      );

      expect(
        ReaderScreen.resolveAutomaticMode(tags: ['Chinese']),
        equals(ReaderMode.leftToRight),
      );

      // Western comic
      expect(
        ReaderScreen.resolveAutomaticMode(type: 'comic'),
        equals(ReaderMode.leftToRight),
      );

      expect(
        ReaderScreen.resolveAutomaticMode(type: 'western'),
        equals(ReaderMode.leftToRight),
      );

      expect(
        ReaderScreen.resolveAutomaticMode(tags: ['Superhero', 'Comic']),
        equals(ReaderMode.leftToRight),
      );

      // Unknown / empty / other fallback
      expect(
        ReaderScreen.resolveAutomaticMode(type: '', mangaId: 'custom:123'),
        equals(ReaderMode.leftToRight),
      );

      expect(
        ReaderScreen.resolveAutomaticMode(),
        equals(ReaderMode.leftToRight),
      );
    });

    test('prioritizes manhwa / manhua tags even if default type was manga', () {
      // In scrapers where MangaItem default type was 'manga', but tag indicates Manhwa
      expect(
        ReaderScreen.resolveAutomaticMode(type: 'manga', tags: ['Action', 'Manhwa']),
        equals(ReaderMode.webtoon),
      );

      expect(
        ReaderScreen.resolveAutomaticMode(type: 'manga', tags: ['Action', 'Manwha']),
        equals(ReaderMode.webtoon),
      );

      // Default type was 'manga', but tag indicates Manhua
      expect(
        ReaderScreen.resolveAutomaticMode(type: 'manga', tags: ['Cultivation', 'Manhua']),
        equals(ReaderMode.leftToRight),
      );
    });
  });

  group('ReaderScreen Automatic Mode Widget Integration', () {
    final sampleChapters = [
      const ChapterItem(id: 'ch_1', number: '1', title: 'Chapter 1'),
      const ChapterItem(id: 'ch_2', number: '2', title: 'Chapter 2'),
    ];

    testWidgets('Manga opens in Automatic (RTL) mode by default', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            mangaId: 'manga_jp_1',
            mangaTitle: 'Demon Slayer',
            mangaType: 'manga',
            chapters: sampleChapters,
            initialIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Top bar and bottom bar should display 'Auto (RTL)'
      expect(find.text('Auto (RTL)'), findsAtLeastNWidgets(1));

      // Open reading direction sheet
      await tester.tap(find.text('Auto (RTL)').first);
      await tester.pumpAndSettle();

      expect(find.text('READING DIRECTION'), findsOneWidget);
      expect(find.text('Automatic'), findsOneWidget);
      expect(find.text('Right to Left (Standard Manga 🇯🇵)'), findsOneWidget);
      expect(find.text('Webtoon (Vertical continuous scroll 🇰🇷)'), findsOneWidget);
      expect(find.text('Left to Right (Western comics / Manhua 🇨🇳)'), findsOneWidget);

      // Checkmark is on Automatic
      final checkmarks = find.byIcon(Icons.check_rounded);
      expect(checkmarks, findsOneWidget);
    });

    testWidgets('Manhwa opens in Automatic (Webtoon) mode by default', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            mangaId: 'manga_kr_1',
            mangaTitle: 'Solo Leveling',
            mangaType: 'manhwa',
            chapters: sampleChapters,
            initialIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Top and bottom bar should display 'Auto (Webtoon)'
      expect(find.text('Auto (Webtoon)'), findsAtLeastNWidgets(1));
    });

    testWidgets('Manwha (alternate spelling) opens in Automatic (Webtoon) mode by default', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            mangaId: 'manga_kr_2',
            mangaTitle: 'Tower of God',
            mangaType: 'manwha',
            chapters: sampleChapters,
            initialIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Auto (Webtoon)'), findsAtLeastNWidgets(1));
    });

    testWidgets('Other formats (e.g. Manhua / Western) open in Automatic (LTR) mode by default', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            mangaId: 'manga_cn_1',
            mangaTitle: 'Martial Peak',
            mangaType: 'manhua',
            chapters: sampleChapters,
            initialIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Auto (LTR)'), findsAtLeastNWidgets(1));
    });

    testWidgets('User can override reading direction manually and switch back to Automatic', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            mangaId: 'test_manga_override',
            mangaTitle: 'One Piece',
            mangaType: 'manga',
            chapters: sampleChapters,
            initialIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially Auto (RTL)
      expect(find.text('Auto (RTL)'), findsAtLeastNWidgets(1));

      // Open sheet and choose Webtoon
      await tester.tap(find.text('Auto (RTL)').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Webtoon (Vertical continuous scroll 🇰🇷)'));
      await tester.pumpAndSettle();

      // Label should now be 'Webtoon'
      expect(find.text('Webtoon'), findsAtLeastNWidgets(1));

      // Wait for SnackBar to dismiss so it doesn't intercept tap
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      // Open sheet and choose Automatic again
      await tester.tap(find.text('Webtoon').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Automatic'));
      await tester.pumpAndSettle();

      // Returns to Auto (RTL)
      expect(find.text('Auto (RTL)'), findsAtLeastNWidgets(1));
    });
  });
}
