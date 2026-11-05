import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/models/tracking_models.dart';
import 'package:manga_reader/services/tracker_service.dart';
import 'package:manga_reader/theme.dart';
import 'package:manga_reader/widgets/tracker_icons.dart';

class TrackingScreen extends StatefulWidget {
  final MangaItem manga;
  final List<ChapterItem> chapters;

  const TrackingScreen({
    super.key,
    required this.manga,
    required this.chapters,
  });

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  final TrackerService _trackerService = TrackerService.instance;

  @override
  void initState() {
    super.initState();
    _trackerService.addListener(_onTrackerChanged);
  }

  @override
  void dispose() {
    _trackerService.removeListener(_onTrackerChanged);
    super.dispose();
  }

  void _onTrackerChanged() {
    if (mounted) setState(() {});
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Tracking', style: AppText.sheetTitle),
        content: Text(
          'Tracking allows you to connect your reading progress with external services such as AniList, MyAnimeList, Kitsu, and MangaUpdates.\n\n'
          'As you read chapters or mark them as read, your linked trackers will be automatically updated with your latest chapter count.',
          style: AppText.bodyMedium.copyWith(color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK', style: TextStyle(color: AppColors.primary)),
          ),
        ],
      ),
    );
  }

  void _showMarkReadOptionDialog() {
    final current = _trackerService.updateProgressWhenMarkedRead;
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.surface,
        title: Text('Update progress when marked as read', style: AppText.sheetTitle),
        children: [
          ListTile(
            title: Text('Always', style: AppText.body),
            trailing: current == 'Always'
                ? const Icon(Icons.check_circle_rounded, color: AppColors.primary)
                : null,
            onTap: () {
              _trackerService.setUpdateProgressWhenMarkedRead('Always');
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            title: Text('Never', style: AppText.body),
            trailing: current == 'Never'
                ? const Icon(Icons.check_circle_rounded, color: AppColors.primary)
                : null,
            onTap: () {
              _trackerService.setUpdateProgressWhenMarkedRead('Never');
              Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  void _handleTrackerTap(TrackerServiceMeta tracker) {
    final record = _trackerService.getTrackingRecord(widget.manga.id, tracker.id);

    if (record != null) {
      _showTrackEditorSheet(tracker, record);
    } else {
      // If AniList and not authenticated, offer login or guest link
      if (tracker.id == 'anilist' && !_trackerService.isAuthenticated) {
        _showAniListAuthSheet(tracker);
      } else {
        _showSearchTrackerSheet(tracker);
      }
    }
  }

  void _showAniListAuthSheet(TrackerServiceMeta tracker) {
    final tokenController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                TrackerLogo(trackerId: tracker.id, size: 28),
                const SizedBox(width: 10),
                Text('Connect ${tracker.name}', style: AppText.sheetTitle),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'Sign in to sync read chapters and scores directly to your ${tracker.name} profile.',
              style: AppText.bodyMedium.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.onPrimary,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const Icon(Icons.open_in_browser_rounded),
              label: const Text('Sign in with AniList (OAuth)', style: TextStyle(fontWeight: FontWeight.w600)),
              onPressed: () async {
                Navigator.pop(ctx);
                final ok = await _trackerService.startOAuthFlow();
                if (!ok && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Could not open browser for AniList auth.')),
                  );
                }
              },
            ),
            const SizedBox(height: 16),
            const Divider(color: AppColors.outline),
            const SizedBox(height: 10),
            Text('Or enter Personal Access Token:', style: AppText.caption),
            const SizedBox(height: 8),
            TextField(
              controller: tokenController,
              style: AppText.body,
              decoration: InputDecoration(
                hintText: 'Paste token here',
                hintStyle: TextStyle(color: AppColors.muted.withValues(alpha: .5)),
                filled: true,
                fillColor: AppColors.surfaceHigh,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.text,
                      side: const BorderSide(color: AppColors.outline),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showSearchTrackerSheet(tracker);
                    },
                    child: const Text('Quick Link (No Login)'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.surfaceHigh,
                      foregroundColor: AppColors.text,
                    ),
                    onPressed: () async {
                      final tok = tokenController.text.trim();
                      if (tok.isNotEmpty) {
                        Navigator.pop(ctx);
                        final success = await _trackerService.loginWithToken(tok);
                        if (mounted) {
                          if (success) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Connected to AniList successfully!')),
                            );
                            _showSearchTrackerSheet(tracker);
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Invalid token. Please try again.')),
                            );
                          }
                        }
                      }
                    },
                    child: const Text('Submit Token'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showSearchTrackerSheet(TrackerServiceMeta tracker) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _TrackerSearchModal(
        tracker: tracker,
        manga: widget.manga,
        chapters: widget.chapters,
        onSelectResult: (result) {
          Navigator.pop(ctx);
          _showTrackEditorSheet(
            tracker,
            MangaTrackingRecord(
              trackerId: tracker.id,
              mangaId: widget.manga.id,
              remoteId: result.remoteId,
              remoteTitle: result.title,
              coverUrl: result.coverUrl,
              totalChapters: result.totalChapters,
              score: result.score ?? 0.0,
              trackingUrl: result.url,
              status: 'Reading',
              lastChapterRead: 0,
              updatedAt: DateTime.now(),
            ),
            isNew: true,
          );
        },
      ),
    );
  }

  void _showTrackEditorSheet(
    TrackerServiceMeta tracker,
    MangaTrackingRecord initialRecord, {
    bool isNew = false,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _TrackerEntryEditorSheet(
        tracker: tracker,
        initialRecord: initialRecord,
        manga: widget.manga,
        totalLocalChapters: widget.chapters.length,
        isNew: isNew,
        onSave: (updated) async {
          Navigator.pop(ctx);
          await _trackerService.saveTrackingRecord(updated);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Tracking updated for ${tracker.name}')),
            );
          }
        },
        onUnlink: () async {
          Navigator.pop(ctx);
          await _trackerService.removeTrackingRecord(widget.manga.id, tracker.id);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Unlinked from ${tracker.name}')),
            );
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.text),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Tracking', style: AppText.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline_rounded, color: AppColors.text),
            tooltip: 'Tracking Help',
            onPressed: _showHelpDialog,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // Update progress after reading switch
          SwitchListTile(
            value: _trackerService.updateProgressAfterReading,
            title: Text('Update progress after reading', style: AppText.body),
            activeThumbColor: AppColors.primary,
            activeTrackColor: AppColors.primary.withValues(alpha: .35),
            inactiveTrackColor: AppColors.surfaceHigh,
            onChanged: (val) {
              _trackerService.setUpdateProgressAfterReading(val);
            },
          ),

          // Update progress when marked as read
          ListTile(
            title: Text('Update progress when marked as read', style: AppText.body),
            subtitle: Text(
              _trackerService.updateProgressWhenMarkedRead,
              style: AppText.caption.copyWith(color: AppColors.muted),
            ),
            onTap: _showMarkReadOptionDialog,
          ),

          const SizedBox(height: 12),

          // Section header: Trackers
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Trackers',
              style: AppText.caption.copyWith(
                color: AppColors.muted,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),

          // Trackers list matching Image 3
          ...TrackerServiceMeta.all.map((tracker) {
            final record = _trackerService.getTrackingRecord(widget.manga.id, tracker.id);
            final isLinked = record != null;
            final isAuth = _trackerService.isTrackerAuthenticated(tracker.id);
            final user = _trackerService.getTrackerUsername(tracker.id);

            String? subtitle;
            if (isLinked) {
              final chStr = 'Ch. ${record.lastChapterRead}'
                  '${record.totalChapters != null && record.totalChapters! > 0 ? ' / ${record.totalChapters}' : ''}';
              final scoreStr = record.score > 0 ? ' • Score: ${record.score.toStringAsFixed(1)}' : '';
              subtitle = '${record.status} • $chStr$scoreStr';
            } else if (isAuth && user != null) {
              subtitle = 'Connected as $user';
            }

            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              leading: TrackerLogo(trackerId: tracker.id, size: 40),
              title: Text(
                tracker.name,
                style: AppText.body.copyWith(
                  fontWeight: FontWeight.w500,
                  color: isLinked ? AppColors.text : AppColors.text.withValues(alpha: .9),
                ),
              ),
              subtitle: subtitle != null
                  ? Text(
                      subtitle,
                      style: AppText.caption.copyWith(
                        color: isLinked ? AppColors.primary : AppColors.muted,
                        fontWeight: isLinked ? FontWeight.w500 : FontWeight.w400,
                      ),
                    )
                  : null,
              trailing: isLinked
                  ? const Icon(Icons.check_circle_rounded, color: AppColors.primary, size: 20)
                  : const Icon(Icons.chevron_right_rounded, color: AppColors.muted, size: 20),
              onTap: () => _handleTrackerTap(tracker),
            );
          }),
        ],
      ),
    );
  }
}

class _TrackerSearchModal extends StatefulWidget {
  final TrackerServiceMeta tracker;
  final MangaItem manga;
  final List<ChapterItem> chapters;
  final ValueChanged<TrackerSearchResult> onSelectResult;

  const _TrackerSearchModal({
    required this.tracker,
    required this.manga,
    required this.chapters,
    required this.onSelectResult,
  });

  @override
  State<_TrackerSearchModal> createState() => _TrackerSearchModalState();
}

class _TrackerSearchModalState extends State<_TrackerSearchModal> {
  late final TextEditingController _searchController;
  bool _loading = false;
  List<TrackerSearchResult> _results = [];
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.manga.title);
    _performSearch(widget.manga.title);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final res = await TrackerService.instance.searchTracker(
        trackerId: widget.tracker.id,
        query: query.trim(),
      );
      if (mounted) {
        setState(() {
          _results = res;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMessage = 'Failed to load results: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              TrackerLogo(trackerId: widget.tracker.id, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Search ${widget.tracker.name}', style: AppText.sheetTitle),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: AppColors.muted),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            style: AppText.body,
            decoration: InputDecoration(
              hintText: 'Search manga title...',
              hintStyle: TextStyle(color: AppColors.muted.withValues(alpha: .5)),
              prefixIcon: const Icon(Icons.search_rounded, color: AppColors.muted),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward_rounded, color: AppColors.primary),
                onPressed: () => _performSearch(_searchController.text),
              ),
              filled: true,
              fillColor: AppColors.surfaceHigh,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            onSubmitted: _performSearch,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
                : _errorMessage != null
                    ? Center(
                        child: Text(_errorMessage!, style: AppText.caption.copyWith(color: Colors.redAccent)),
                      )
                    : _results.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text('No results found.', style: AppText.bodyMedium.copyWith(color: AppColors.muted)),
                                const SizedBox(height: 8),
                                TextButton(
                                  onPressed: () {
                                    widget.onSelectResult(
                                      TrackerSearchResult(
                                        trackerId: widget.tracker.id,
                                        remoteId: 'custom_${widget.manga.id}',
                                        title: widget.manga.title,
                                        totalChapters: widget.chapters.isNotEmpty ? widget.chapters.length : null,
                                      ),
                                    );
                                  },
                                  child: Text('Link as "${widget.manga.title}"'),
                                ),
                              ],
                            ),
                          )
                        : ListView.separated(
                            itemCount: _results.length,
                            separatorBuilder: (context, index) => const Divider(color: AppColors.outline, height: 1),
                            itemBuilder: (ctx, i) {
                              final item = _results[i];
                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                leading: item.coverUrl != null
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Image.network(
                                          item.coverUrl!,
                                          width: 40,
                                          height: 56,
                                          fit: BoxFit.cover,
                                          errorBuilder: (context, error, stackTrace) => Container(
                                            width: 40,
                                            height: 56,
                                            color: AppColors.surfaceHigh,
                                            child: const Icon(Icons.book_rounded, color: AppColors.muted),
                                          ),
                                        ),
                                      )
                                    : Container(
                                        width: 40,
                                        height: 56,
                                        decoration: BoxDecoration(
                                          color: AppColors.surfaceHigh,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Icon(Icons.book_rounded, color: AppColors.muted),
                                      ),
                                title: Text(item.title, style: AppText.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                  '${item.status ?? 'Unknown'} • ${item.totalChapters != null ? '${item.totalChapters} Ch.' : '? Ch.'}'
                                  '${item.score != null ? ' • Score: ${item.score!.toStringAsFixed(1)}' : ''}',
                                  style: AppText.caption.copyWith(color: AppColors.muted),
                                ),
                                onTap: () => widget.onSelectResult(item),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

class _TrackerEntryEditorSheet extends StatefulWidget {
  final TrackerServiceMeta tracker;
  final MangaTrackingRecord initialRecord;
  final MangaItem manga;
  final int totalLocalChapters;
  final bool isNew;
  final ValueChanged<MangaTrackingRecord> onSave;
  final VoidCallback onUnlink;

  const _TrackerEntryEditorSheet({
    required this.tracker,
    required this.initialRecord,
    required this.manga,
    required this.totalLocalChapters,
    this.isNew = false,
    required this.onSave,
    required this.onUnlink,
  });

  @override
  State<_TrackerEntryEditorSheet> createState() => _TrackerEntryEditorSheetState();
}

class _TrackerEntryEditorSheetState extends State<_TrackerEntryEditorSheet> {
  late String _status;
  late int _lastChapterRead;
  late int? _totalChapters;
  late double _score;

  static const _statusOptions = [
    'Reading',
    'Completed',
    'On Hold',
    'Dropped',
    'Plan to Read',
    'Rereading',
  ];

  @override
  void initState() {
    super.initState();
    _status = widget.initialRecord.status;
    _lastChapterRead = widget.initialRecord.lastChapterRead;
    _totalChapters = widget.initialRecord.totalChapters ??
        (widget.totalLocalChapters > 0 ? widget.totalLocalChapters : null);
    _score = widget.initialRecord.score;
  }

  void _incrementChapter() {
    setState(() {
      _lastChapterRead++;
      if (_totalChapters != null && _lastChapterRead >= _totalChapters!) {
        _status = 'Completed';
      }
    });
  }

  void _decrementChapter() {
    if (_lastChapterRead > 0) {
      setState(() => _lastChapterRead--);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              TrackerLogo(trackerId: widget.tracker.id, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.isNew ? 'Track on ${widget.tracker.name}' : widget.tracker.name,
                  style: AppText.sheetTitle,
                ),
              ),
              if (!widget.isNew && widget.initialRecord.trackingUrl != null)
                IconButton(
                  icon: const Icon(Icons.open_in_new_rounded, size: 20, color: AppColors.muted),
                  tooltip: 'Open in web',
                  onPressed: () {
                    final u = Uri.tryParse(widget.initialRecord.trackingUrl!);
                    if (u != null) launchUrl(u, mode: LaunchMode.externalApplication);
                  },
                ),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: AppColors.muted),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            widget.initialRecord.remoteTitle,
            style: AppText.bodySemiBold,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),

          // Status Dropdown
          Row(
            children: [
              Text('Status', style: AppText.bodyMedium.copyWith(color: AppColors.muted)),
              const Spacer(),
              DropdownButton<String>(
                value: _status,
                dropdownColor: AppColors.surfaceHigh,
                style: AppText.body,
                underline: const SizedBox(),
                items: _statusOptions
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _status = val);
                },
              ),
            ],
          ),
          const Divider(color: AppColors.outline),

          // Chapter progress
          Row(
            children: [
              Text('Chapters read', style: AppText.bodyMedium.copyWith(color: AppColors.muted)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline_rounded, color: AppColors.primary),
                onPressed: _decrementChapter,
              ),
              Text(
                '$_lastChapterRead${_totalChapters != null && _totalChapters! > 0 ? ' / $_totalChapters' : ''}',
                style: AppText.bodySemiBold,
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline_rounded, color: AppColors.primary),
                onPressed: _incrementChapter,
              ),
            ],
          ),
          const Divider(color: AppColors.outline),

          // Score
          Row(
            children: [
              Text('Score (0-10)', style: AppText.bodyMedium.copyWith(color: AppColors.muted)),
              const Spacer(),
              DropdownButton<double>(
                value: _score,
                dropdownColor: AppColors.surfaceHigh,
                style: AppText.body,
                underline: const SizedBox(),
                items: List.generate(21, (i) => i * 0.5)
                    .map((val) => DropdownMenuItem(
                          value: val,
                          child: Text(val == 0 ? 'No score' : val.toStringAsFixed(1)),
                        ))
                    .toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _score = val);
                },
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Action buttons: Save & Unlink
          Row(
            children: [
              if (!widget.isNew) ...[
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: widget.onUnlink,
                    child: const Text('Unlink'),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () {
                    final updated = widget.initialRecord.copyWith(
                      status: _status,
                      lastChapterRead: _lastChapterRead,
                      totalChapters: _totalChapters,
                      score: _score,
                      updatedAt: DateTime.now(),
                    );
                    widget.onSave(updated);
                  },
                  child: Text(widget.isNew ? 'Save & Link' : 'Save changes'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
