import 'package:flutter/material.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/local_database.dart';
import '../services/tracker_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';
import 'source_catalog_screen.dart';

/// Reading Statistics screen showing library totals, reading streak & time
/// (from LocalDatabase reading_sessions), type/status breakdown, and top genres.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  ({int totalSeconds, int totalPages, int streakDays}) _sessionStats = (
    totalSeconds: 0,
    totalPages: 0,
    streakDays: 0,
  );
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final stats = await LocalDatabase.instance.loadReadingSessionStats();
      if (mounted) {
        setState(() {
          _sessionStats = stats;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _formatDuration(int totalSeconds) {
    if (totalSeconds < 60) return '${totalSeconds}s';
    final hours = totalSeconds ~/ 3600;
    final mins = (totalSeconds % 3600) ~/ 60;
    if (hours > 0) return '${hours}h ${mins}m';
    return '${mins}m';
  }

  @override
  Widget build(BuildContext context) {
    final api = ApiService.instance;
    final library = api.libraryRepo.getLibraryItems();
    final readChaptersMap = api.historyRepo.readChapters;
    final totalReadChapters = readChaptersMap.values.fold<int>(
      0,
      (sum, set) => sum + set.length,
    );
    final historyCount = api.historyRepo.localHistory.length;
    final trackedCount = library
        .where((m) => TrackerService.instance.isMangaTracked(m.id))
        .length;
    final downloadedCount = DownloadService.instance.downloadedChapters.length;

    // Breakdown by type
    final typeCounts = <String, int>{};
    final statusCounts = <String, int>{};
    final genreCounts = <String, int>{};

    for (final m in library) {
      final t = m.type.trim().isEmpty ? 'Manga' : m.type.trim();
      final tCap = '${t[0].toUpperCase()}${t.substring(1).toLowerCase()}';
      typeCounts[tCap] = (typeCounts[tCap] ?? 0) + 1;

      final st = m.status.trim().isEmpty ? 'Unknown' : m.status.trim();
      final stCap = '${st[0].toUpperCase()}${st.substring(1).toLowerCase()}';
      statusCounts[stCap] = (statusCounts[stCap] ?? 0) + 1;

      for (final tag in m.tags) {
        final clean = tag.trim();
        if (clean.isNotEmpty) {
          genreCounts[clean] = (genreCounts[clean] ?? 0) + 1;
        }
      }
    }

    final topGenres = genreCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top10Genres = topGenres.take(10).toList();
    final maxGenreCount =
        top10Genres.isNotEmpty ? top10Genres.first.value : 1;

    final mostRead = <(MangaItem, int)>[];
    for (final entry in readChaptersMap.entries) {
      if (entry.value.isEmpty) continue;
      final known = api.libraryRepo.localLibrary[entry.key] ??
          api.libraryRepo.knownManga[entry.key];
      if (known != null) {
        mostRead.add((known, entry.value.length));
      }
    }
    mostRead.sort((a, b) => b.$2.compareTo(a.$2));
    final topReadTitles = mostRead.take(5).toList();

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text('Reading Statistics', style: AppText.title),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Top overview grid
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.75,
            children: [
              _kpiCard(
                icon: Icons.collections_bookmark_rounded,
                label: 'Library Titles',
                value: '${library.length}',
                color: AppColors.primary,
              ),
              _kpiCard(
                icon: Icons.check_circle_outline_rounded,
                label: 'Chapters Read',
                value: '$totalReadChapters',
                color: const Color(0xFF10B981),
              ),
              _kpiCard(
                icon: Icons.local_fire_department_rounded,
                label: 'Reading Streak',
                value: _loading ? '…' : '${_sessionStats.streakDays}d',
                color: Colors.amber,
              ),
              _kpiCard(
                icon: Icons.schedule_rounded,
                label: 'Reading Time',
                value: _loading
                    ? '…'
                    : _formatDuration(_sessionStats.totalSeconds),
                color: Colors.purpleAccent,
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Secondary pills
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.outline),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _miniStat('Pages Logged', '${_sessionStats.totalPages}'),
                _divider(),
                _miniStat('History', '$historyCount'),
                _divider(),
                _miniStat('Tracked', '$trackedCount'),
                _divider(),
                _miniStat('Offline Ch.', '$downloadedCount'),
              ],
            ),
          ),

          const SizedBox(height: 22),
          Text('LIBRARY BY TYPE', style: AppText.sectionHeader),
          const SizedBox(height: 8),
          _breakdownCard(
            typeCounts,
            emptyLabel: 'Add titles to your library to see type breakdown.',
          ),

          const SizedBox(height: 22),
          Text('LIBRARY BY STATUS', style: AppText.sectionHeader),
          const SizedBox(height: 8),
          _breakdownCard(
            statusCounts,
            emptyLabel: 'No status metadata recorded yet.',
          ),

          if (topReadTitles.isNotEmpty) ...[
            const SizedBox(height: 22),
            Text('MOST READ TITLES', style: AppText.sectionHeader),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.outline),
              ),
              child: Column(
                children: [
                  for (final (manga, count) in topReadTitles)
                    ListTile(
                      dense: true,
                      leading: SizedBox(
                        width: 34,
                        height: 46,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: CoverImage(imageUrl: manga.cover, mangaId: manga.id),
                        ),
                      ),
                      title: Text(
                        manga.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodyMedium,
                      ),
                      subtitle: Text(
                        '$count chapter${count == 1 ? '' : 's'} read',
                        style: AppText.caption.copyWith(color: AppColors.primary),
                      ),
                      trailing: Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.muted),
                      onTap: () {
                        Navigator.of(context).push(
                          smoothRoute(DetailScreen(manga: manga)),
                        );
                      },
                    ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 22),
          Text('TOP GENRES (TAP TO EXPLORE)', style: AppText.sectionHeader),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.outline),
            ),
            child: top10Genres.isEmpty
                ? Text(
                    'No genre tags in your library yet.',
                    style: AppText.caption,
                  )
                : Column(
                    children: [
                      for (final entry in top10Genres)
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () {
                            Navigator.of(context).push(
                              smoothRoute(
                                SourceCatalogScreen(
                                  sourceId: 'mangadex',
                                  sourceName: 'MangaDex',
                                  initialQuery: entry.key,
                                ),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        entry.key,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppText.bodyMedium,
                                      ),
                                    ),
                                    Text(
                                      '${entry.value}',
                                      style: AppText.caption.copyWith(
                                        color: AppColors.primary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(Icons.chevron_right_rounded, size: 15, color: AppColors.muted),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: (entry.value / maxGenreCount).clamp(0.05, 1.0),
                                    minHeight: 6,
                                    backgroundColor: AppColors.surfaceHigh,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _kpiCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption,
                ),
              ),
            ],
          ),
          Text(value, style: AppText.title.copyWith(fontSize: 22)),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value) {
    return Column(
      children: [
        Text(value, style: AppText.cardTitle),
        const SizedBox(height: 2),
        Text(label, style: AppText.badge.copyWith(color: AppColors.muted)),
      ],
    );
  }

  Widget _divider() => Container(width: 1, height: 28, color: AppColors.outline);

  Widget _breakdownCard(Map<String, int> counts, {required String emptyLabel}) {
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = counts.values.fold<int>(0, (s, v) => s + v);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.outline),
      ),
      child: sorted.isEmpty
          ? Text(emptyLabel, style: AppText.caption)
          : Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in sorted)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${e.key}: ${e.value} (${total > 0 ? ((e.value / total) * 100).round() : 0}%)',
                      style: AppText.chip,
                    ),
                  ),
              ],
            ),
    );
  }
}
