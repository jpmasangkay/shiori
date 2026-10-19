import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data.dart';
import '../models/manga_models.dart';
import '../services/api_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';
import 'reader_screen.dart';

class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key});

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen> {
  Map<String, dynamic> _groups = {};
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _loading = true);
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
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                if (_loading && !hasRealUpdates) ...[
                  const _DateHeader('Loading Updates...'),
                  const _Skeleton(),
                  const _Skeleton(),
                  const _Skeleton(),
                  const _Skeleton(),
                ] else if (hasRealUpdates) ...[
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
                                  chapterId: item['id'],
                                  mangaId: item['mangaId'],
                                  mangaTitle: item['mangaTitle'] ?? 'Manga',
                                  chapterTitle: item['chapterTitle'],
                                  coverUrl: item['cover'],
                                  chapter: int.tryParse(item['chapterNumber']?.toString() ?? '1') ?? 1,
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
                  const _DateHeader('Today'),
                  for (final r in updateRows.sublist(0, 3)) _UpdateRow(r),
                  const _DateHeader('Yesterday'),
                  for (final r in updateRows.sublist(3, 5)) _UpdateRow(r),
                  const _DateHeader('Oct 14'),
                  for (final r in updateRows.sublist(5)) _UpdateRow(r),
                  const _Skeleton(),
                  const _Skeleton(),
                ],
              ],
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
                  child: CoverImage(0, imageUrl: item['cover'], saturation: .6),
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

class _UpdateRow extends StatelessWidget {
  const _UpdateRow(this.entry);
  final UpdateEntry entry;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DetailScreen(cover: entry.cover)),
      ),
      child: Container(
        height: 60,
        padding: const EdgeInsets.fromLTRB(12, 2, 7, 2),
        child: Row(
          children: [
            SizedBox(
              width: 42,
              height: 56,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: CoverImage(entry.cover, saturation: .6),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    entry.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            const BarIcon(Icons.file_download_outlined, label: 'Download chapter'),
          ],
        ),
      ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: .6,
      child: Container(
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 56,
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(4)),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FractionallySizedBox(
                    widthFactor: .75,
                    child: Container(
                      height: 9,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceHigh,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FractionallySizedBox(
                    widthFactor: .54,
                    child: Container(
                      height: 9,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
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
