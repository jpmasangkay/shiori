import 'dart:async';
import 'package:flutter/material.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
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
  Timer? _realtimeTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetch();
    ApiService.instance.addListener(_onServiceChanged);
    // Real-time silent background refresh every 45 seconds when visible
    _realtimeTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) {
        if (widget.isActive) {
          _fetch(silent: true);
        } else {
          _dirty = true;
        }
      },
    );
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
    _realtimeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    ApiService.instance.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (!widget.isActive) {
      _dirty = true;
      return;
    }
    _fetch(silent: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _fetch(silent: true);
    }
  }

  Future<void> _fetch({bool silent = false}) async {
    if (!silent && _groups.isEmpty) {
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
    final hasUpdates = _groups.values.any((list) => (list as List).isNotEmpty);

    return Column(
      children: [
        const AppTopBar(
          title: 'Updates',
        ),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.primary,
            backgroundColor: AppColors.surface,
            onRefresh: _onRefresh,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _loading && !hasUpdates
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
                          for (final entry in _groups.entries) ...[
                            if ((entry.value as List).isNotEmpty) ...[
                              _DateHeader(entry.key),
                              for (final item in (entry.value as List))
                                if (item is Map<String, dynamic>)
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
                                      Navigator.of(context).push(
                                        smoothRoute(
                                          ReaderScreen(
                                            chapterId: item['id']?.toString() ?? '',
                                            mangaId: mId,
                                            mangaTitle: effTitle,
                                            chapterTitle: item['chapterTitle'],
                                            coverUrl: item['cover'],
                                            chapterNumber: item['chapterNumber']?.toString(),
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
                          ],
                        ] else ...[
                          LayoutBuilder(
                            builder: (_, _) => const SizedBox(
                              height: 400,
                              child: EmptyState(
                                icon: Icons.new_releases_outlined,
                                title: 'No recent updates',
                                message:
                                    'Only new chapters for titles bookmarked in your library will appear here. Pull down to refresh.',
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
                    style: AppText.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
