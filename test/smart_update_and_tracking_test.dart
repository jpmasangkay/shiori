import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/models/tracking_models.dart';
import 'package:manga_reader/services/smart_update_service.dart';
import 'package:manga_reader/services/tracker_service.dart';
import 'package:manga_reader/widgets/tracker_icons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SmartUpdateService tests', () {
    test('Completed manga returns N/A and standard completed message', () {
      const manga = MangaItem(
        id: 'test_manga_1',
        title: 'Ace of the Diamond',
        status: 'Completed',
      );

      final result = SmartUpdateService.instance.calculate(manga, [
        const ChapterItem(id: 'c1', publishAt: '2024-12-01T00:00:00Z', number: '1'),
        const ChapterItem(id: 'c2', publishAt: '2024-12-08T00:00:00Z', number: '2'),
      ]);

      expect(result.isCompleted, isTrue);
      expect(result.hasPrediction, isFalse);
      expect(result.label, 'N/A');
      expect(
        result.statusDescription,
        'This manga is either completed, or there is no predicted release date.',
      );
    });

    test('Ongoing manga with insufficient chapters returns N/A', () {
      const manga = MangaItem(
        id: 'test_manga_2',
        title: 'New Manga',
        status: 'Ongoing',
      );

      final result = SmartUpdateService.instance.calculate(manga, [
        const ChapterItem(id: 'c1', publishAt: '2024-12-01T00:00:00Z', number: '1'),
      ]);

      expect(result.isCompleted, isFalse);
      expect(result.hasPrediction, isFalse);
      expect(result.label, 'N/A');
      expect(
        result.statusDescription,
        'This manga is either completed, or there is no predicted release date.',
      );
    });

    test('Ongoing manga with regular weekly releases predicts next chapter date', () {
      const manga = MangaItem(
        id: 'test_manga_3',
        title: 'Weekly Manga',
        status: 'Ongoing',
      );

      final now = DateTime.now();
      final ch1Date = now.subtract(const Duration(days: 14)).toIso8601String();
      final ch2Date = now.subtract(const Duration(days: 7)).toIso8601String();
      final ch3Date = now.toIso8601String();

      final result = SmartUpdateService.instance.calculate(manga, [
        ChapterItem(id: 'c1', publishAt: ch1Date, number: '1'),
        ChapterItem(id: 'c2', publishAt: ch2Date, number: '2'),
        ChapterItem(id: 'c3', publishAt: ch3Date, number: '3'),
      ]);

      expect(result.isCompleted, isFalse);
      expect(result.hasPrediction, isTrue);
      expect(result.intervalDays, 7);
      expect(result.label, anyOf(contains('in 7d'), contains('1 week'), contains('in 6d')));
      expect(result.statusDescription, contains('Weekly (every 7 days)'));
    });
  });

  group('TrackerService and models tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await TrackerService.instance.init();
    });

    test('TrackerService default settings', () {
      final tracker = TrackerService.instance;
      expect(tracker.updateProgressAfterReading, isTrue);
      expect(tracker.updateProgressWhenMarkedRead, 'Always');
    });

    test('Can toggle settings and persist', () async {
      final tracker = TrackerService.instance;
      await tracker.setUpdateProgressAfterReading(false);
      expect(tracker.updateProgressAfterReading, isFalse);

      await tracker.setUpdateProgressWhenMarkedRead('Never');
      expect(tracker.updateProgressWhenMarkedRead, 'Never');
    });

    test('Per-manga tracking records: save, retrieve, and delete', () async {
      final tracker = TrackerService.instance;
      const mangaId = 'diamond_ace_418';

      expect(tracker.isMangaTracked(mangaId), isFalse);
      expect(tracker.getTrackingRecordsForManga(mangaId), isEmpty);

      final record = MangaTrackingRecord(
        trackerId: 'anilist',
        mangaId: mangaId,
        remoteId: '30456',
        remoteTitle: 'Ace of Diamond',
        status: 'Reading',
        lastChapterRead: 412,
        totalChapters: 418,
        score: 9.0,
        updatedAt: DateTime.now(),
      );

      await tracker.saveTrackingRecord(record);

      expect(tracker.isMangaTracked(mangaId), isTrue);
      final retrieved = tracker.getTrackingRecord(mangaId, 'anilist');
      expect(retrieved, isNotNull);
      expect(retrieved!.remoteTitle, 'Ace of Diamond');
      expect(retrieved.lastChapterRead, 412);
      expect(retrieved.totalChapters, 418);
      expect(retrieved.score, 9.0);

      // Unlink
      await tracker.removeTrackingRecord(mangaId, 'anilist');
      expect(tracker.isMangaTracked(mangaId), isFalse);
      expect(tracker.getTrackingRecord(mangaId, 'anilist'), isNull);
    });

    test('All 8 trackers exist in TrackerServiceMeta', () {
      expect(TrackerServiceMeta.all.length, 8);
      final ids = TrackerServiceMeta.all.map((t) => t.id).toList();
      expect(ids, containsAll([
        'mangabaka',
        'myanimelist',
        'anilist',
        'kitsu',
        'mangaupdates',
        'shikimori',
        'bangumi',
        'hikka',
      ]));
    });

    testWidgets('TrackerLogo renders all 8 trackers without crashing', (tester) async {
      for (final tracker in TrackerServiceMeta.all) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TrackerLogo(trackerId: tracker.id, size: 40),
            ),
          ),
        );
        expect(find.byType(TrackerLogo), findsOneWidget);
      }
    });
  });
}

