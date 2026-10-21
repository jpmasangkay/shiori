import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/skeleton.dart';
import 'detail_screen.dart';
import 'reader_screen.dart';

class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key});

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen> with WidgetsBindingObserver {
  Map<String, dynamic> _groups = {};
  bool _loading = false;
  Timer? _realtimeTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetch();
    ApiService.instance.addListener(_fetch);
    // Real-time silent background refresh every 45 seconds
    _realtimeTimer = Timer.periodic(const Duration(seconds: 45), (_) => _fetch(silent: true));
  }

  @override
  void dispose() {
    _realtimeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    ApiService.instance.removeListener(_fetch);
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final hasRealUpdates = _groups.values.any((list) => (list as List).isNotEmpty);

    return Column(
      children: [
        AppTopBar(
          title: 'Updates',
          actions: [
            BarIcon(Icons.refresh_rounded, label: 'Refresh', onTap: _fetch),
          ],
        ),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.primary,
            backgroundColor: AppColors.surface,
            onRefresh: _fetch,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _loading && !hasRealUpdates
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
                        if (hasRealUpdates) ...[
                          for (final entry in _groups.entries) ...[
                            if ((entry.value as List).isNotEmpty) ...[
                              _DateHeader(entry.key),
                              for (final item in entry.value as List)
                                _ApiUpdateRow(
                                  item: item as Map<String, dynamic>,
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ReaderScreen(
                                          chapterId: item['id']?.toString() ?? '',
                                          mangaId: item['mangaId']?.toString() ?? '',
                                          mangaTitle: item['mangaTitle'] ?? 'Untitled',
                                          chapterTitle: item['chapterTitle'],
                                          coverUrl: item['cover'],
                                          chapterNumber: item['chapterNumber']?.toString(),
                                        ),
                                      ),
                                    );
                                  },
                                  onCoverTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => DetailScreen(
                                          manga: MangaItem(
                                            id: item['mangaId'] ?? '',
                                            title: item['mangaTitle'] ?? '',
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
                            builder: (_, c) => SizedBox(
                              height: 400,
                              child: const EmptyState(
                                icon: Icons.new_releases_outlined,
                                title: 'No recent updates',
                                message: 'Only new chapters for titles bookmarked in your library will appear here. Pull down to refresh.',
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
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        child: SizedBox(
          height: 21,
          child: Text(
            text,
            style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.primary),
          ),
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
    final mangaTitle = item['mangaTitle'] ?? 'Untitled';
    final chNum = item['chapterNumber'] != null ? 'Chapter ${item['chapterNumber']}' : 'New Chapter';
    final group = item['group'] ?? 'MangaDex';
    final subtitle = '$chNum · $group';

    return InkWell(
      onTap: onTap,
      child: Container(
        height: 60,
        padding: const EdgeInsets.fromLTRB(12, 2, 7, 2),
        child: Row(
          children: [
            GestureDetector(
              onTap: onCoverTap,
              child: SizedBox(
                width: 42,
                height: 56,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CoverImage(imageUrl: item['cover'], saturation: .6),
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
                    style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.file_download_outlined, size: 20, color: AppColors.muted),
              onPressed: onTap,
            ),
          ],
        ),
      ),
    );
  }
}

