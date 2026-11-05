import 'dart:async';

import 'package:flutter/material.dart';

import '../models/manga_models.dart';
import '../screens/detail_screen.dart';
import '../services/api_service.dart';
import '../services/source_resolver.dart';
import '../theme.dart';
import 'common.dart';

enum DuplicateResolutionAction {
  cancel,
  addAnyway,
  copied,
  migrated,
}

class DuplicateResolutionResult {
  final DuplicateResolutionAction action;
  final MangaItem? targetManga;
  final MangaItem? duplicateManga;
  final bool includeChapters;
  final bool includeCategories;

  const DuplicateResolutionResult({
    required this.action,
    this.targetManga,
    this.duplicateManga,
    this.includeChapters = true,
    this.includeCategories = true,
  });
}

/// Displays the "Possible duplicates" bottom sheet matching the Tachiyomi/Mihon UX.
Future<DuplicateResolutionResult?> showPossibleDuplicatesSheet({
  required BuildContext context,
  required MangaItem targetManga,
  required List<MangaItem> duplicates,
  List<ChapterItem> targetChapters = const [],
}) {
  return showModalBottomSheet<DuplicateResolutionResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1E1E22),
    barrierColor: Colors.black87,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) => _PossibleDuplicatesSheetWidget(
      targetManga: targetManga,
      duplicates: duplicates,
      targetChapters: targetChapters,
    ),
  );
}

class _PossibleDuplicatesSheetWidget extends StatefulWidget {
  final MangaItem targetManga;
  final List<MangaItem> duplicates;
  final List<ChapterItem> targetChapters;

  const _PossibleDuplicatesSheetWidget({
    required this.targetManga,
    required this.duplicates,
    this.targetChapters = const [],
  });

  @override
  State<_PossibleDuplicatesSheetWidget> createState() =>
      _PossibleDuplicatesSheetWidgetState();
}

class _PossibleDuplicatesSheetWidgetState
    extends State<_PossibleDuplicatesSheetWidget> {
  final Map<String, int> _counts = {};

  @override
  void initState() {
    super.initState();
    for (final d in widget.duplicates) {
      final recorded = ApiService.instance.getChapterCount(d.id);
      if (recorded > 0) {
        _counts[d.id] = recorded;
      } else {
        // Fallback: parse lastChapter if available or fetch in background
        final parsed = double.tryParse(d.lastChapter ?? '');
        if (parsed != null && parsed > 0) {
          _counts[d.id] = parsed.toInt();
        } else {
          _fetchCount(d.id);
        }
      }
    }
  }

  Future<void> _fetchCount(String mangaId) async {
    try {
      final chs = await ApiService.instance.getChapters(mangaId);
      if (mounted && chs.isNotEmpty) {
        setState(() {
          _counts[mangaId] = chs.length;
        });
      }
    } catch (_) {}
  }

  Future<void> _onSelectDuplicate(MangaItem dup) async {
    final result = await showSelectDataToIncludeSheet(
      context: context,
      targetManga: widget.targetManga,
      duplicateManga: dup,
      targetChapters: widget.targetChapters,
    );
    if (result != null && mounted) {
      Navigator.of(context).pop(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'Possible duplicates',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'You have entries in your library with a similar name.\n\nSelect an entry to migrate or add anyway.',
              style: TextStyle(
                fontSize: 14,
                height: 1.4,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 320,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                itemCount: widget.duplicates.length,
                separatorBuilder: (context, index) => const SizedBox(width: 14),
                itemBuilder: (ctx, index) {
                  final dup = widget.duplicates[index];
                  final count = _counts[dup.id] ?? 0;
                  final authorText =
                      dup.authors.isNotEmpty ? dup.authors.first : 'Unknown';
                  final statusText =
                      dup.status.isNotEmpty ? dup.status : 'Unknown';
                  final sourceName = SourceResolver.displayName(
                    SourceResolver.resolve(dup.id, dup.source),
                  );

                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _onSelectDuplicate(dup),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: 175,
                        decoration: BoxDecoration(
                          color: const Color(0xFF24242A),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white12, width: 1),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Cover with Chapter Count Badge
                            Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(15),
                                  ),
                                  child: SizedBox(
                                    height: 185,
                                    width: double.infinity,
                                    child: CoverImage(
                                      imageUrl: dup.cover,
                                      mangaId: dup.id,
                                      saturation: 0.7,
                                    ),
                                  ),
                                ),
                                if (count > 0)
                                  Positioned(
                                    top: 8,
                                    left: 8,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xDD282834),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        '$count chapters',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            // Details Below Cover
                            Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    dup.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.person_outline_rounded,
                                        size: 13,
                                        color: Colors.white60,
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          authorText,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                            color: Colors.white60,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.done_all_rounded,
                                        size: 13,
                                        color: Colors.white60,
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          statusText,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                            color: Colors.white60,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Center(
                                    child: Text(
                                      sourceName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 12),
            InkWell(
              onTap: () {
                Navigator.of(context).pop(
                  DuplicateResolutionResult(
                    action: DuplicateResolutionAction.addAnyway,
                    targetManga: widget.targetManga,
                  ),
                );
              },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.add_rounded, color: AppColors.primary, size: 24),
                    SizedBox(width: 12),
                    Text(
                      'Add anyway',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton(
                onPressed: () {
                  Navigator.of(context).pop(
                    const DuplicateResolutionResult(
                      action: DuplicateResolutionAction.cancel,
                    ),
                  );
                },
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white24, width: 1),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  backgroundColor: const Color(0xFF282830),
                ),
                child: const Text(
                  'Cancel',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Displays the "Select data to include" bottom sheet matching Screenshot 2.
Future<DuplicateResolutionResult?> showSelectDataToIncludeSheet({
  required BuildContext context,
  required MangaItem targetManga,
  required MangaItem duplicateManga,
  List<ChapterItem> targetChapters = const [],
}) {
  return showModalBottomSheet<DuplicateResolutionResult>(
    context: context,
    backgroundColor: const Color(0xFF202026),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => _SelectDataToIncludeSheetWidget(
      targetManga: targetManga,
      duplicateManga: duplicateManga,
      targetChapters: targetChapters,
    ),
  );
}

class _SelectDataToIncludeSheetWidget extends StatefulWidget {
  final MangaItem targetManga;
  final MangaItem duplicateManga;
  final List<ChapterItem> targetChapters;

  const _SelectDataToIncludeSheetWidget({
    required this.targetManga,
    required this.duplicateManga,
    this.targetChapters = const [],
  });

  @override
  State<_SelectDataToIncludeSheetWidget> createState() =>
      _SelectDataToIncludeSheetWidgetState();
}

class _SelectDataToIncludeSheetWidgetState
    extends State<_SelectDataToIncludeSheetWidget> {
  bool _includeChapters = true;
  bool _includeCategories = true;
  bool _working = false;

  void _showEntry() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailScreen(manga: widget.duplicateManga),
      ),
    );
  }

  Future<void> _applyDataTransfer({required bool isMigrate}) async {
    setState(() => _working = true);
    try {
      // 1. Transfer categories first if selected
      if (_includeCategories) {
        final existingCats =
            ApiService.instance.getMangaCategoryIds(widget.duplicateManga.id);
        if (existingCats.isNotEmpty) {
          await ApiService.instance.setMangaCategories(
            widget.targetManga.id,
            existingCats,
            manga: widget.targetManga,
          );
        }
      }

      // 2. Add target manga to library (already carrying transferred categories)
      await ApiService.instance.addToLibrary(widget.targetManga);

      // 3. Transfer reading progress & read chapters if selected
      if (_includeChapters) {
        await ApiService.instance.migrateOrCopyReadingProgress(
          sourceMangaId: widget.duplicateManga.id,
          targetManga: widget.targetManga,
          targetChapters: widget.targetChapters,
        );
      }

      // 4. If migrating, remove the duplicate manga from library
      if (isMigrate) {
        await ApiService.instance.removeFromLibrary(widget.duplicateManga.id);
      }

      // 5. Instantly persist changes to the cloud
      if (ApiService.instance.isLoggedIn) {
        try {
          await ApiService.instance
              .syncAllCloudData()
              .timeout(const Duration(seconds: 4));
        } catch (_) {}
      }

      if (mounted) {
        Navigator.of(context).pop(
          DuplicateResolutionResult(
            action: isMigrate
                ? DuplicateResolutionAction.migrated
                : DuplicateResolutionAction.copied,
            targetManga: widget.targetManga,
            duplicateManga: widget.duplicateManga,
            includeChapters: _includeChapters,
            includeCategories: _includeCategories,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _working = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Operation failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select data to include',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: AppColors.primary,
              checkColor: Colors.white,
              value: _includeChapters,
              onChanged: _working
                  ? null
                  : (v) => setState(() => _includeChapters = v ?? true),
              title: const Text(
                'Chapters',
                style: TextStyle(fontSize: 16, color: Colors.white),
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: AppColors.primary,
              checkColor: Colors.white,
              value: _includeCategories,
              onChanged: _working
                  ? null
                  : (v) => setState(() => _includeCategories = v ?? true),
              title: const Text(
                'Categories',
                style: TextStyle(fontSize: 16, color: Colors.white),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                TextButton(
                  onPressed: _working ? null : _showEntry,
                  child: const Text(
                    'Show entry',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                if (_working)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else ...[
                  TextButton(
                    onPressed: () => _applyDataTransfer(isMigrate: false),
                    child: const Text(
                      'Copy',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => _applyDataTransfer(isMigrate: true),
                    child: const Text(
                      'Migrate',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Displays a sheet to review and resolve duplicate titles already present in the library.
Future<void> showLibraryDuplicatesSheet({
  required BuildContext context,
  required Map<String, List<MangaItem>> duplicateGroups,
  required VoidCallback onRefresh,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1E1E22),
    barrierColor: Colors.black87,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) => _LibraryDuplicatesSheetWidget(
      duplicateGroups: duplicateGroups,
      onRefresh: onRefresh,
    ),
  );
}

class _LibraryDuplicatesSheetWidget extends StatefulWidget {
  final Map<String, List<MangaItem>> duplicateGroups;
  final VoidCallback onRefresh;

  const _LibraryDuplicatesSheetWidget({
    required this.duplicateGroups,
    required this.onRefresh,
  });

  @override
  State<_LibraryDuplicatesSheetWidget> createState() =>
      _LibraryDuplicatesSheetWidgetState();
}

class _LibraryDuplicatesSheetWidgetState
    extends State<_LibraryDuplicatesSheetWidget> {
  late Map<String, List<MangaItem>> _groups;

  @override
  void initState() {
    super.initState();
    _groups = Map.from(widget.duplicateGroups);
  }

  void _refreshGroups() {
    final library = ApiService.instance.libraryRepo.localLibrary.values.toList();
    final newGroups = <String, List<MangaItem>>{};
    for (int i = 0; i < library.length; i++) {
      for (int j = i + 1; j < library.length; j++) {
        if (DuplicateDetector.isPossibleDuplicate(
          library[i].title,
          library[j].title,
        )) {
          final norm = DuplicateDetector.normalize(library[i].title);
          newGroups.putIfAbsent(norm, () => []).addAll([library[i], library[j]]);
        }
      }
    }
    final filtered = <String, List<MangaItem>>{};
    newGroups.forEach((k, list) {
      final seen = <String>{};
      final unique = list.where((m) => seen.add(m.id)).toList();
      if (unique.length > 1) filtered[k] = unique;
    });

    setState(() {
      _groups = filtered;
    });
    widget.onRefresh();
    if (_groups.isEmpty && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _migratePair(MangaItem target, MangaItem source) async {
    final result = await showSelectDataToIncludeSheet(
      context: context,
      targetManga: target,
      duplicateManga: source,
    );
    if (result != null && mounted) {
      _refreshGroups();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.action == DuplicateResolutionAction.migrated
                ? 'Migrated to ${target.title} (${SourceResolver.displayName(SourceResolver.resolve(target.id, target.source))})'
                : 'Copied data from ${source.title}',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _removeItem(MangaItem item) async {
    await ApiService.instance.removeFromLibrary(item.id);
    if (mounted) {
      _refreshGroups();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Removed ${item.title} from library'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupList = _groups.entries.toList();
    final screenHeight = MediaQuery.of(context).size.height;

    return SafeArea(
      top: false,
      child: SizedBox(
        height: screenHeight * 0.82,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Resolve Duplicates',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Text(
                    '${groupList.length} groups',
                    style: const TextStyle(fontSize: 13, color: AppColors.muted),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Select an entry to migrate reading progress and categories into, or remove redundant versions.',
                style: TextStyle(fontSize: 13.5, color: Colors.white70, height: 1.35),
              ),
              const SizedBox(height: 14),
              const Divider(color: Colors.white12, height: 1),
              const SizedBox(height: 12),
              Expanded(
                child: groupList.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(
                            'No duplicates found in your library!',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: groupList.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 16),
                        itemBuilder: (ctx, idx) {
                          final entry = groupList[idx];
                          final items = entry.value;
                          final displayTitle = items.first.title;

                          return Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF25252B),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white12),
                            ),
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  displayTitle,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${items.length} duplicate entries',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.muted,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                for (int i = 0; i < items.length; i++) ...[
                                  if (i > 0)
                                    const Divider(
                                      color: Colors.white10,
                                      height: 16,
                                    ),
                                  _buildItemRow(items[i], items),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItemRow(MangaItem item, List<MangaItem> group) {
    final src = SourceResolver.displayName(
      SourceResolver.resolve(item.id, item.source),
    );
    final count = ApiService.instance.getChapterCount(item.id);
    final unread = ApiService.instance.getUnreadCount(item.id);
    final otherItems = group.where((m) => m.id != item.id).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 44,
                height: 60,
                child: CoverImage(
                  imageUrl: item.cover,
                  mangaId: item.id,
                  saturation: 0.7,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceHigh,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          src,
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                      if (count > 0)
                        Text(
                          '$count ch',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white60,
                          ),
                        ),
                      if (unread > 0)
                        Text(
                          '($unread unread)',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.muted,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              if (otherItems.isNotEmpty)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    minimumSize: const Size(0, 30),
                    side: const BorderSide(
                      color: AppColors.primary,
                      width: 0.9,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(
                    Icons.swap_horiz_rounded,
                    size: 15,
                    color: AppColors.primary,
                  ),
                  label: const Text(
                    'Migrate to this',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: () => _migratePair(item, otherItems.first),
                ),
              IconButton(
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: Colors.redAccent,
                ),
                tooltip: 'Remove from library',
                onPressed: () => _removeItem(item),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
