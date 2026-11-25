import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/platform_bridge.dart';
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
    final failed = ds.failedTasks;

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
          style: AppText.title,
        ),
        actions: [
          if (active.isNotEmpty)
            IconButton(
              icon: Icon(
                ds.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                color: AppColors.primary,
              ),
              tooltip: ds.isPaused ? 'Resume downloads' : 'Pause downloads',
              onPressed: () {
                if (ds.isPaused) {
                  ds.resumeQueue();
                } else {
                  ds.pauseQueue();
                }
              },
            ),
          if (downloaded.isNotEmpty)
            IconButton(
              icon: Icon(Icons.delete_sweep_rounded, color: AppColors.muted),
              tooltip: 'Clear all downloads',
              onPressed: _confirmClearAll,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        children: [
          // Storage Summary & Policy Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.outline),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.active.withValues(alpha: .5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.offline_pin_rounded, color: AppColors.primary, size: 26),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Total Offline Storage',
                            style: AppText.caption.copyWith(color: AppColors.muted),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            ds.formatBytes(totalBytes),
                            style: AppText.title,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${downloaded.length} chapters across ${grouped.length} titles',
                            style: AppText.caption.copyWith(color: AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Divider(color: AppColors.outline, height: 1),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Wi-Fi only downloads', style: AppText.bodyMedium),
                  subtitle: Text(
                    'Pause queue on cellular connections to save mobile data',
                    style: AppText.caption,
                  ),
                  activeThumbColor: AppColors.primary,
                  value: ds.wifiOnlyDownloads,
                  onChanged: (val) => ds.setWifiOnlyDownloads(val),
                ),
                Divider(color: AppColors.outline, height: 1),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Auto-download new chapters', style: AppText.bodyMedium),
                  subtitle: Text(
                    'Queue newly discovered library chapters automatically',
                    style: AppText.caption,
                  ),
                  activeThumbColor: AppColors.primary,
                  value: ds.autoDownloadNewChapters,
                  onChanged: (val) => ds.setAutoDownloadNewChapters(val),
                ),
                Divider(color: AppColors.outline, height: 1),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Auto-delete after reading', style: AppText.bodyMedium),
                  subtitle: Text(
                    'Automatically delete downloaded chapter once finished to free storage',
                    style: AppText.caption,
                  ),
                  activeThumbColor: AppColors.primary,
                  value: ds.autoDeleteReadChapters,
                  onChanged: (val) => ds.setAutoDeleteReadChapters(val),
                ),
              ],
            ),
          ),

          // Active Downloads Queue (if any)
          if (active.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _sectionHeader(
                  ds.isPaused
                      ? 'PAUSED QUEUE (${active.length})'
                      : 'ACTIVE DOWNLOADS (${active.length})',
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        if (ds.isPaused) {
                          ds.resumeQueue();
                        } else {
                          ds.pauseQueue();
                        }
                      },
                      icon: Icon(
                        ds.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                        size: 16,
                      ),
                      label: Text(ds.isPaused ? 'Resume' : 'Pause'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 4),
                    TextButton(
                      onPressed: ds.cancelAllActiveDownloads,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Cancel All'),
                    ),
                  ],
                ),
              ],
            ),
            for (final task in active)
              _buildActiveTaskCard(task),
          ],

          // Failed Downloads (if any)
          if (failed.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _sectionHeader('FAILED DOWNLOADS (${failed.length})'),
                TextButton.icon(
                  onPressed: ds.retryFailedDownloads,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Retry All'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            for (final task in failed)
              _buildActiveTaskCard(task),
          ],

          const SizedBox(height: 24),
          _sectionHeader('DOWNLOADED TITLES (${grouped.length})'),

          if (grouped.isEmpty && active.isEmpty && failed.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.download_for_offline_outlined, size: 54, color: AppColors.muted),
                    const SizedBox(height: 14),
                    Text(
                      'No offline chapters',
                      style: AppText.cardTitle,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Download chapters from any title to read them completely offline.',
                      textAlign: TextAlign.center,
                      style: AppText.caption.copyWith(color: AppColors.muted),
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
        style: AppText.sectionHeader,
      ),
    );
  }

  Widget _buildActiveTaskCard(DownloadTask task) {
    final ds = DownloadService.instance;
    final isFailed = task.status == DownloadStatus.failed;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isFailed ? Colors.redAccent.withValues(alpha: .4) : AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 34,
                height: 46,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: CoverImage(
                    imageUrl: task.manga.cover,
                    mangaId: task.manga.id,
                    saturation: .7,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.manga.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodySemiBold,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      task.chapter.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              if (isFailed)
                IconButton(
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  icon: Icon(Icons.refresh_rounded, size: 18, color: AppColors.primary),
                  tooltip: 'Retry download',
                  onPressed: () => ds.downloadChapter(task.manga, task.chapter),
                ),
              IconButton(
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                icon: Icon(Icons.close_rounded, size: 18, color: AppColors.muted),
                onPressed: () => ds.cancelDownload(task.chapter.id),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!isFailed)
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
              Expanded(
                child: Text(
                  isFailed
                      ? (task.error ?? 'Download failed')
                      : (ds.isPaused
                          ? 'Paused'
                          : (task.status == DownloadStatus.queued
                              ? 'Queued...'
                              : 'Page ${task.downloadedPages} of ${task.totalPages}')),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.badge.copyWith(color: isFailed ? Colors.redAccent : AppColors.muted),
                ),
              ),
              if (!isFailed)
                Text(
                  '${(task.progress * 100).toInt()}%',
                  style: AppText.badge.copyWith(color: AppColors.primary),
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
        border: Border.all(color: AppColors.outline),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: SizedBox(
          width: 44,
          height: 60,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: CoverImage(
              imageUrl: first.mangaCover,
              mangaId: mangaId,
              saturation: .7,
            ),
          ),
        ),
        title: Text(
          first.mangaTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.cardTitle,
        ),
        subtitle: Text(
          '${chapters.length} chapters • ${ds.formatBytes(totalMangaBytes)}',
          style: AppText.caption.copyWith(color: AppColors.muted),
        ),
        trailing: IconButton(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          icon: Icon(Icons.delete_outline_rounded, size: 20, color: AppColors.muted),
          tooltip: 'Delete all chapters for this title',
          onPressed: () => _confirmDeleteManga(mangaId, first.mangaTitle),
        ),
        children: [
          Divider(color: AppColors.outline, height: 1),
          for (final ch in chapters)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Text(
                ch.chapterTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyMedium,
              ),
              subtitle: Text(
                '${ch.pageCount} pages • ${ds.formatBytes(ch.totalBytes)}',
                style: AppText.caption.copyWith(color: AppColors.muted),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
                    icon: Icon(Icons.archive_outlined, size: 19, color: AppColors.muted),
                    tooltip: 'Export chapter as .cbz',
                    onPressed: () => _exportChapterCbz(ch),
                  ),
                  IconButton(
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
                    icon: Icon(Icons.play_circle_outline_rounded, size: 20, color: AppColors.primary),
                    tooltip: 'Read offline',
                    onPressed: () => _openReader(ch, chapters),
                  ),
                  IconButton(
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
                    icon: Icon(Icons.delete_outline_rounded, size: 18, color: AppColors.muted),
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

  Future<void> _exportChapterCbz(DownloadedChapterInfo ch) async {
    final bytes = await DownloadService.instance.exportChapterAsCbz(ch.chapterId);
    if (!mounted) return;
    if (bytes == null || bytes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No chapter images found to export.')),
      );
      return;
    }
    final safeName = '${ch.mangaTitle}_${ch.chapterTitle}'
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_');
    final fileName = '$safeName.cbz';
    final savedUri = await PlatformBridge.instance.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: 'application/zip',
    );
    if (savedUri != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported $fileName (${(bytes.length / 1024).toStringAsFixed(0)} KB)')),
        );
      }
      return;
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final outDir = Directory('${dir.path}/shiori_exports');
      if (!await outDir.exists()) await outDir.create(recursive: true);
      final outFile = File('${outDir.path}/$fileName');
      await outFile.writeAsBytes(bytes, flush: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved CBZ to ${outFile.path}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
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

    final known = ApiService.instance.libraryRepo.knownManga[chapter.mangaId] ??
        ApiService.instance.libraryRepo.localLibrary[chapter.mangaId];

    Navigator.of(context).push(
      smoothRoute(
        ReaderScreen(
          chapterId: chapter.chapterId,
          mangaId: chapter.mangaId,
          mangaTitle: chapter.mangaTitle,
          chapterTitle: chapter.chapterTitle,
          chapterNumber: chapter.chapterNumber,
          coverUrl: chapter.mangaCover,
          chapters: chapterItems,
          mangaType: known?.type,
          tags: known?.tags,
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
