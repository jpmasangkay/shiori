import 'dart:async';
import 'package:flutter/material.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../services/connectivity_service.dart';
import '../services/download_service.dart';
import '../services/source_resolver.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/skeleton.dart';
import 'detail_screen.dart';
import 'reader_screen.dart';

class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key, this.isActive = true});

  final bool isActive;

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen>
    with WidgetsBindingObserver {
  Map<String, dynamic> _groups = {};
  bool _loading = false;
  bool _dirty = false;
  bool _unreadOnly = false;
  DateTime _lastFetchAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _resumeCooldown = Duration(minutes: 10);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Hydrate cached updates immediately in 0ms for offline/slow internet
    final cached = ApiService.instance.getCachedUpdates();
    if (cached['groups'] is Map<String, dynamic>) {
      _groups = Map<String, dynamic>.from(cached['groups'] as Map<String, dynamic>);
    }
    _fetch(silent: _groups.values.any((list) => (list as List).isNotEmpty));
    ApiService.instance.addListener(_onServiceChanged);
    DownloadService.instance.addListener(_onDownloadChanged);
  }

  @override
  void didUpdateWidget(covariant UpdatesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive && _dirty) {
      _dirty = false;
      _fetch(silent: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ApiService.instance.removeListener(_onServiceChanged);
    DownloadService.instance.removeListener(_onDownloadChanged);
    super.dispose();
  }

  void _onDownloadChanged() {
    if (mounted) setState(() {});
  }

  void _onServiceChanged() {
    if (!widget.isActive) {
      _dirty = true;
      return;
    }
    if (DateTime.now().difference(_lastFetchAt) >= const Duration(seconds: 30)) {
      _fetch(silent: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        widget.isActive &&
        !ConnectivityService.instance.isOffline &&
        DateTime.now().difference(_lastFetchAt) >= _resumeCooldown) {
      _fetch(silent: true);
    }
  }

  Future<void> _fetch({bool silent = false}) async {
    _lastFetchAt = DateTime.now();
    final hasCurrent = _groups.values.any((list) => (list as List).isNotEmpty);
    if (!silent && !hasCurrent) {
      setState(() => _loading = true);
    }
    try {
      final res = await ApiService.instance.getUpdates();
      if (mounted) {
        setState(() {
          _groups = (res['groups'] as Map<String, dynamic>?) ?? {};
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onRefresh() async {
    final newCount = await ApiService.instance.checkForLibraryUpdates();
    await _fetch();
    if (mounted && newCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Checked library: $newCount new chapters found!'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredGroups = <String, List<Map<String, dynamic>>>{};
    for (final entry in _groups.entries) {
      final rawList = entry.value;
      if (rawList is! List) continue;
      final kept = <Map<String, dynamic>>[];
      for (final item in rawList) {
        if (item is! Map<String, dynamic>) continue;
        if (_unreadOnly) {
          final mId = item['mangaId']?.toString() ?? '';
          final chId = item['id']?.toString() ?? '';
          if (mId.isNotEmpty &&
              chId.isNotEmpty &&
              ApiService.instance.isChapterRead(mId, chId)) {
            continue;
          }
        }
        kept.add(item);
      }
      if (kept.isNotEmpty) {
        filteredGroups[entry.key] = kept;
      }
    }
    final hasAnyUpdates = _groups.values.any((list) => (list as List).isNotEmpty);
    final hasUpdates = filteredGroups.isNotEmpty;

    return Column(
      children: [
        AppTopBar(
          title: 'Updates',
          actions: [
            if (hasAnyUpdates)
              IconButton(
                tooltip: _unreadOnly ? 'Showing unread only' : 'Filter unread only',
                icon: Icon(
                  _unreadOnly ? Icons.filter_alt_rounded : Icons.filter_alt_outlined,
                  size: 22,
                  color: _unreadOnly ? AppColors.primary : AppColors.muted,
                ),
                onPressed: () => setState(() => _unreadOnly = !_unreadOnly),
              ),
          ],
        ),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.primary,
            backgroundColor: AppColors.surface,
            onRefresh: _onRefresh,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _loading && !hasAnyUpdates
                  ? ListView(
                      key: const ValueKey('updates_loading'),
                      padding: const EdgeInsets.only(top: 8, bottom: 16),
                      children: const [
                        _DateHeader('Checking for new chapters...'),
                        UpdateRowSkeleton(),
                        UpdateRowSkeleton(),
                        UpdateRowSkeleton(),
                        UpdateRowSkeleton(),
                        UpdateRowSkeleton(),
                      ],
                    )
                  : ListView(
                      key: const ValueKey('updates_content'),
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        if (hasUpdates) ...[
                          for (final entry in filteredGroups.entries) ...[
                            _DateHeader(entry.key),
                            for (final item in entry.value)
                              _ApiUpdateRow(
                                item: item,
                                onTap: () {
                                  final mId = item['mangaId']?.toString() ?? '';
                                  final known = ApiService.instance.libraryRepo.knownManga[mId] ??
                                      ApiService.instance.libraryRepo.localLibrary[mId];
                                  final rawT = item['mangaTitle']?.toString() ?? '';
                                  final effTitle = (rawT.isNotEmpty && rawT != 'Untitled' && !rawT.startsWith('ext:') && rawT != mId)
                                      ? rawT
                                      : (known?.displayTitle ?? MangaItem.cleanTitleFromIdOrSlug(mId));
                                  final cachedChapters = ApiService.instance.getCachedChapters(mId);
                                  Navigator.of(context).push(
                                    smoothRoute(
                                      ReaderScreen(
                                        chapterId: item['id']?.toString() ?? '',
                                        mangaId: mId,
                                        mangaTitle: effTitle,
                                        chapterTitle: item['chapterTitle'],
                                        coverUrl: item['cover'],
                                        chapterNumber: item['chapterNumber']?.toString(),
                                        chapters: cachedChapters,
                                        mangaType: known?.type ?? item['type']?.toString(),
                                        tags: known?.tags,
                                      ),
                                    ),
                                  );
                                },
                                onCoverTap: () {
                                  final mId = item['mangaId']?.toString() ?? '';
                                  final known = ApiService.instance.libraryRepo.knownManga[mId] ??
                                      ApiService.instance.libraryRepo.localLibrary[mId];
                                  final rawT = item['mangaTitle']?.toString() ?? '';
                                  final effTitle = (rawT.isNotEmpty && rawT != 'Untitled' && !rawT.startsWith('ext:') && rawT != mId)
                                      ? rawT
                                      : (known?.displayTitle ?? MangaItem.cleanTitleFromIdOrSlug(mId));
                                  Navigator.of(context).push(
                                    smoothRoute(
                                      DetailScreen(
                                        manga: known ??
                                            MangaItem(
                                              id: mId,
                                              title: effTitle,
                                              cover: item['cover'] ?? '',
                                            ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ] else ...[
                          LayoutBuilder(
                            builder: (_, _) => SizedBox(
                              height: 400,
                              child: EmptyState(
                                icon: _unreadOnly
                                    ? Icons.done_all_rounded
                                    : Icons.new_releases_outlined,
                                title: _unreadOnly ? 'All caught up' : 'No recent updates',
                                message: _unreadOnly
                                    ? 'All recent chapters have been read. Tap the filter icon to show read updates.'
                                    : 'Only new chapters for titles bookmarked in your library will appear here. Pull down to refresh.',
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DateHeader extends StatelessWidget {
  const _DateHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
    child: Text(
      text,
      style: AppText.sectionHeader.copyWith(color: AppColors.primary),
    ),
  );
}

class _ApiUpdateRow extends StatelessWidget {
  const _ApiUpdateRow({
    required this.item,
    required this.onTap,
    required this.onCoverTap,
  });

  final Map<String, dynamic> item;
  final VoidCallback onTap;
  final VoidCallback onCoverTap;

  @override
  Widget build(BuildContext context) {
    final mId = item['mangaId']?.toString() ?? '';
    final chId = item['id']?.toString() ?? '';
    final isRead = mId.isNotEmpty &&
        chId.isNotEmpty &&
        ApiService.instance.isChapterRead(mId, chId);
    final dlStatus = chId.isNotEmpty
        ? DownloadService.instance.getStatus(chId)
        : DownloadStatus.notDownloaded;
    final known = ApiService.instance.libraryRepo.knownManga[mId] ??
        ApiService.instance.libraryRepo.localLibrary[mId];
    final rawT = item['mangaTitle']?.toString() ?? '';
    final mangaTitle = (rawT.isNotEmpty && rawT != 'Untitled' && !rawT.startsWith('ext:') && rawT != mId)
        ? rawT
        : (known?.displayTitle ?? MangaItem.cleanTitleFromIdOrSlug(mId.isNotEmpty ? mId : rawT));

    final chNum = item['chapterNumber'] != null
        ? 'Chapter ${item['chapterNumber']}'
        : 'New Chapter';
    final groupRaw = item['group'] ?? item['source'] ?? '';
    final group = groupRaw.toString().isNotEmpty
        ? SourceResolver.displayName(groupRaw.toString())
        : SourceResolver.displayName(SourceResolver.resolveSource(mId));
    final subtitle = '$chNum · $group';

    void handleDownloadTap() {
      if (chId.isEmpty || mId.isEmpty) return;
      if (dlStatus == DownloadStatus.downloaded) {
        DownloadService.instance.deleteDownloadedChapter(chId);
        return;
      }
      if (dlStatus == DownloadStatus.downloading || dlStatus == DownloadStatus.queued) {
        return;
      }
      final manga = known ??
          MangaItem(
            id: mId,
            title: mangaTitle,
            cover: item['cover']?.toString() ?? '',
          );
      final chapter = ChapterItem(
        id: chId,
        number: item['chapterNumber']?.toString(),
        title: item['chapterTitle']?.toString() ?? '',
        group: group,
      );
      DownloadService.instance.downloadChapter(manga, chapter);
    }

    Widget buildDownloadBtn() {
      switch (dlStatus) {
        case DownloadStatus.downloaded:
          return IconButton(
            constraints: const BoxConstraints(minWidth: 42, minHeight: 42),
            icon: Icon(Icons.check_circle_rounded, size: 20, color: AppColors.primary),
            tooltip: 'Downloaded (tap to delete)',
            onPressed: handleDownloadTap,
          );
        case DownloadStatus.downloading:
          return SizedBox(
            width: 42,
            height: 42,
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
              ),
            ),
          );
        case DownloadStatus.queued:
          return SizedBox(
            width: 42,
            height: 42,
            child: Icon(Icons.schedule_rounded, size: 20, color: AppColors.muted),
          );
        case DownloadStatus.failed:
          return IconButton(
            constraints: const BoxConstraints(minWidth: 42, minHeight: 42),
            icon: const Icon(Icons.error_outline_rounded, size: 20, color: Colors.redAccent),
            tooltip: 'Retry download',
            onPressed: handleDownloadTap,
          );
        case DownloadStatus.notDownloaded:
          return IconButton(
            constraints: const BoxConstraints(minWidth: 42, minHeight: 42),
            icon: Icon(
              Icons.download_rounded,
              size: 20,
              color: AppColors.muted.withValues(alpha: isRead ? .35 : .7),
            ),
            tooltip: 'Download chapter',
            onPressed: handleDownloadTap,
          );
      }
    }

    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 62),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            GestureDetector(
              onTap: onCoverTap,
              child: SizedBox(
                width: 44,
                height: 56,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CoverImage(
                    imageUrl: item['cover']?.toString(),
                    mangaId: item['mangaId']?.toString(),
                    saturation: isRead ? 0.3 : 1.0,
                    memCacheWidth: 90,
                    memCacheHeight: 120,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mangaTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodyMedium.copyWith(
                      color: isRead ? AppColors.read : AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: isRead ? AppColors.read : AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (chId.isNotEmpty) buildDownloadBtn(),
          ],
        ),
      ),
    );
  }
}
