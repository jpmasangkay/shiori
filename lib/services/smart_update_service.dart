import 'package:manga_reader/models/manga_models.dart';

class SmartUpdateResult {
  final bool isCompleted;
  final bool hasPrediction;
  final DateTime? nextReleaseDate;
  final int? intervalDays;
  final DateTime? latestChapterDate;
  final String label;
  final String statusDescription;

  const SmartUpdateResult({
    required this.isCompleted,
    required this.hasPrediction,
    this.nextReleaseDate,
    this.intervalDays,
    this.latestChapterDate,
    required this.label,
    required this.statusDescription,
  });
}

class SmartUpdateService {
  SmartUpdateService._();
  static final SmartUpdateService instance = SmartUpdateService._();

  SmartUpdateResult calculate(MangaItem manga, List<ChapterItem> chapters) {
    final status = manga.status.trim().toLowerCase();
    final isCompleted = status.contains('completed') ||
        status.contains('finish') ||
        status.contains('complete');

    if (isCompleted) {
      return const SmartUpdateResult(
        isCompleted: true,
        hasPrediction: false,
        label: 'N/A',
        statusDescription:
            'This manga is either completed, or there is no predicted release date.',
      );
    }

    // Parse chapters with valid publishAt
    final datedChapters = <({DateTime date, ChapterItem chapter})>[];
    for (final c in chapters) {
      if (c.publishAt != null && c.publishAt!.isNotEmpty) {
        final d = DateTime.tryParse(c.publishAt!);
        if (d != null) {
          datedChapters.add((date: d, chapter: c));
        }
      }
    }

    // Sort ascending by date
    datedChapters.sort((a, b) => a.date.compareTo(b.date));

    if (datedChapters.length < 2) {
      return const SmartUpdateResult(
        isCompleted: false,
        hasPrediction: false,
        label: 'N/A',
        statusDescription:
            'This manga is either completed, or there is no predicted release date.',
      );
    }

    // Take the last up to 10 dated chapters to analyze recent frequency
    final recent = datedChapters.length > 10
        ? datedChapters.sublist(datedChapters.length - 10)
        : datedChapters;

    final intervals = <int>[];
    for (var i = 0; i < recent.length - 1; i++) {
      final days = recent[i + 1].date.difference(recent[i].date).inDays;
      if (days >= 1 && days <= 120) {
        intervals.add(days);
      }
    }

    if (intervals.isEmpty) {
      return const SmartUpdateResult(
        isCompleted: false,
        hasPrediction: false,
        label: 'N/A',
        statusDescription:
            'This manga is either completed, or there is no predicted release date.',
      );
    }

    // Calculate median interval
    intervals.sort();
    final medianDays = intervals[intervals.length ~/ 2];
    final latestDate = recent.last.date;
    final nextDate = latestDate.add(Duration(days: medianDays));
    final now = DateTime.now();
    final diffDays = nextDate.difference(now).inDays;

    String label;
    if (diffDays < 0) {
      label = 'N/A'; // Passed or no current prediction
    } else if (diffDays == 0) {
      label = 'Today';
    } else if (diffDays == 1) {
      label = 'Tomorrow';
    } else if (diffDays < 7) {
      label = 'in ${diffDays}d';
    } else if (diffDays < 14) {
      label = '1 week';
    } else {
      label = '${(diffDays / 7).round()}w';
    }

    final freqText = medianDays <= 1
        ? 'Daily'
        : medianDays == 7
            ? 'Weekly (every 7 days)'
            : medianDays == 14
                ? 'Bi-weekly (every 14 days)'
                : medianDays >= 28 && medianDays <= 31
                    ? 'Monthly (approx. 30 days)'
                    : 'Every $medianDays days';

    final dateStr =
        '${_monthName(nextDate.month)} ${nextDate.day}, ${nextDate.year}';
    final desc =
        'Predicted next release: $dateStr\nRelease frequency: $freqText';

    return SmartUpdateResult(
      isCompleted: false,
      hasPrediction: true,
      nextReleaseDate: nextDate,
      intervalDays: medianDays,
      latestChapterDate: latestDate,
      label: label,
      statusDescription: desc,
    );
  }

  static String _monthName(int month) {
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    if (month >= 1 && month <= 12) return m[month - 1];
    return '';
  }
}

