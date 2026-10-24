import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/manga_models.dart';
import '../services/download_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'reader_screen.dart';

class DownloadManagerScreen extends StatefulWidget {
  const DownloadManagerScreen({super.key});

  @override
  State<DownloadManagerScreen> createState() => _DownloadManagerScreenState();
}

class _DownloadManagerScreenState extends State<DownloadManagerScreen> {
  @override
  void initState() {
    super.initState();
    DownloadService.instance.addListener(_onChange);
  }

  @override
  void dispose() {
    DownloadService.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ds = DownloadService.instance;
    final totalBytes = ds.getTotalDownloadSizeBytes();
    final downloaded = ds.downloadedChapters.values.toList();
    final active = ds.activeTasks;

    // Group downloaded chapters by mangaId
    final Map<String, List<DownloadedChapterInfo>> grouped = {};
    for (final info in downloaded) {
      grouped.putIfAbsent(info.mangaId, () => []).add(info);
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: Text(
          'Downloads',
          style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (downloaded.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded, color: AppColors.muted),
              tooltip: 'Clear all downloads',
              onPressed: _confirmClearAll,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        children: [
          // Storage Summary Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.surfaceHigh),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.active.withValues(alpha: .4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.offline_pin_rounded, color: AppColors.primary, size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Offline Storage',
                        style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        ds.formatBytes(totalBytes),
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppColors.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${downloaded.length} chapters across ${grouped.length} titles',
                        style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Active Downloads Queue (if any)
          if (active.isNotEmpty) ...[
            const SizedBox(height: 24),
            _sectionHeader('ACTIVE DOWNLOADS (${active.length})'),
            for (final task in active)
              _buildActiveTaskCard(task),
          ],

          const SizedBox(height: 24),
          _sectionHeader('DOWNLOADED TITLES (${grouped.length})'),

          if (grouped.isEmpty && active.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Center(
                child: Column(
                  children: [
                    const Icon(Icons.download_for_offline_outlined, size: 54, color: AppColors.muted),
                    const SizedBox(height: 14),
                    Text(
                      'No offline chapters',
                      style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Download chapters from any title to read them completely offline.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
            )
          else
            for (final entry in grouped.entries)
              _buildMangaDownloadGroup(entry.key, entry.value),
        ],
      ),
    );
  }

  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: AppColors.muted,
        ),
      ),
    );
  }

  Widget _buildActiveTaskCard(DownloadTask task) {
    final ds = DownloadService.instance;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surfaceHigh),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.manga.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      task.chapter.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.muted),
                onPressed: () => ds.cancelDownload(task.chapter.id),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: task.status == DownloadStatus.queued ? null : task.progress,
            backgroundColor: AppColors.surfaceHigh,
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(4),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                task.status == DownloadStatus.queued
                    ? 'Queued...'
                    : 'Page ${task.downloadedPages} of ${task.totalPages}',
                style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
              ),
              Text(
                '${(task.progress * 100).toInt()}%',
                style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.primary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMangaDownloadGroup(String mangaId, List<DownloadedChapterInfo> chapters) {
    final first = chapters.first;
    final totalMangaBytes = chapters.fold<int>(0, (sum, c) => sum + c.totalBytes);
    final ds = DownloadService.instance;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.surfaceHigh),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: SizedBox(
          width: 44,
          height: 60,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: CoverImage(imageUrl: first.mangaCover, saturation: .7),
          ),
        ),
        title: Text(
          first.mangaTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${chapters.length} chapters • ${ds.formatBytes(totalMangaBytes)}',
          style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline_rounded, size: 20, color: AppColors.muted),
          tooltip: 'Delete all chapters for this title',
          onPressed: () => _confirmDeleteManga(mangaId, first.mangaTitle),
        ),
        children: [
          const Divider(color: AppColors.surfaceHigh, height: 1),
          for (final ch in chapters)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Text(
                ch.chapterTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500),
              ),
              subtitle: Text(
                '${ch.pageCount} pages • ${ds.formatBytes(ch.totalBytes)}',
                style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.play_circle_outline_rounded, size: 20, color: AppColors.primary),
                    tooltip: 'Read offline',
                    onPressed: () => _openReader(ch, chapters),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded, size: 18, color: AppColors.muted),
                    tooltip: 'Delete chapter',
                    onPressed: () => ds.deleteDownloadedChapter(ch.chapterId),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _openReader(DownloadedChapterInfo chapter, List<DownloadedChapterInfo> allChapters) {
    final chapterItems = allChapters
        .map((c) => ChapterItem(
              id: c.chapterId,
              number: c.chapterNumber,
              title: c.chapterTitle,
              pages: c.pageCount,
            ))
        .toList();

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          chapterId: chapter.chapterId,
          mangaId: chapter.mangaId,
          mangaTitle: chapter.mangaTitle,
          chapterTitle: chapter.chapterTitle,
          chapterNumber: chapter.chapterNumber,
          coverUrl: chapter.mangaCover,
          chapters: chapterItems,
        ),
      ),
    );
  }

  void _confirmDeleteManga(String mangaId, String title) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Delete "$title"?'),
        content: const Text('All downloaded chapters for this title will be removed from your device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              DownloadService.instance.deleteMangaDownloads(mangaId);
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _confirmClearAll() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete all downloads?'),
        content: const Text('All offline chapters will be permanently removed to free up storage.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              DownloadService.instance.deleteAllDownloads();
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }
}
