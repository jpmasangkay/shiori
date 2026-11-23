import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_service.dart';
import '../services/extension_service.dart';
import '../services/platform_bridge.dart';
import '../theme.dart';
import '../widgets/auth_modal.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  static const _autoBackupKey = 'shiori_auto_backup_enabled_v1';
  static const _maxClipboardChars =
      450 * 1024; // Avoid Android 1MB Binder crash

  final _api = ApiService.instance;
  final _extService = ExtensionService.instance;
  bool _exporting = false;
  bool _restoring = false;
  bool _autoBackupEnabled = false;
  String? _lastSavedFilePath;

  @override
  void initState() {
    super.initState();
    _api.addListener(_onUpdate);
    _initStateAsync();
  }

  @override
  void dispose() {
    _api.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _initStateAsync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final autoBk = prefs.getBool(_autoBackupKey) ?? false;
      String? latestPath;
      try {
        final docDir = await getApplicationDocumentsDirectory();
        final file = File(p.join(docDir.path, 'shiori_backup_latest.json'));
        if (await file.exists()) {
          latestPath = file.path;
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          _autoBackupEnabled = autoBk;
          _lastSavedFilePath = latestPath;
        });
      }
      if (autoBk) {
        await _runRotatingLocalBackup();
      }
    } catch (_) {}
  }

  String _timestampTag() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y$m$d';
  }

  Future<String?> _writeLocalBackupBytes(
    String fileName,
    Uint8List bytes,
  ) async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docDir.path, 'shiori_backups'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File(p.join(dir.path, fileName));
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _runRotatingLocalBackup() async {
    try {
      final bytes = await _api.exportCompressedBackupBytes();
      final docDir = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docDir.path, 'shiori_backups'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final fileName = 'shiori_auto_${_timestampTag()}.shiori.json.gz';
      await File(p.join(dir.path, fileName)).writeAsBytes(bytes, flush: true);

      // Keep only the 3 most recent auto-backups
      final autoFiles = <File>[];
      await for (final entity in dir.list()) {
        if (entity is File &&
            p.basename(entity.path).startsWith('shiori_auto_')) {
          autoFiles.add(entity);
        }
      }
      autoFiles.sort((a, b) => b.path.compareTo(a.path));
      for (final old in autoFiles.skip(3)) {
        try {
          await old.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _toggleAutoBackup(bool enabled) async {
    setState(() => _autoBackupEnabled = enabled);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_autoBackupKey, enabled);
      if (enabled) {
        await _runRotatingLocalBackup();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Automatic local backup enabled (keeps last 3 snapshots).',
              ),
            ),
          );
        }
      }
    } catch (_) {}
  }

  Future<void> _handleExportFile({required bool asTachibk}) async {
    setState(() => _exporting = true);
    try {
      final Uint8List bytes;
      final String fileName;
      final String mimeType;
      final String formatLabel;

      if (asTachibk) {
        bytes = await _api.exportTachibkBytes();
        fileName = 'shiori_${_timestampTag()}.tachibk';
        mimeType = 'application/octet-stream';
        formatLabel = 'Mihon / Tachiyomi (.tachibk)';
      } else {
        bytes = await _api.exportCompressedBackupBytes();
        fileName = 'shiori_${_timestampTag()}.shiori.json.gz';
        mimeType = 'application/gzip';
        formatLabel = 'Shiori Archive (.shiori.json.gz)';
      }

      // 1. Try Android SAF save dialog first
      final safUri = await PlatformBridge.instance.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
      );

      // 2. Always persist a local backup copy as well
      final localPath = await _writeLocalBackupBytes(fileName, bytes);
      if (!mounted) return;
      setState(() => _exporting = false);

      final savedDest = safUri ?? localPath;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: AppColors.primary,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Backup Exported', style: AppText.sheetTitle),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Format: $formatLabel\nSize: ${(bytes.length / 1024).toStringAsFixed(1)} KB',
                style: AppText.body.copyWith(color: AppColors.muted),
              ),
              if (savedDest != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(savedDest, style: AppText.mono),
                ),
              ],
            ],
          ),
          actions: [
            if (localPath != null)
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  PlatformBridge.instance.shareFile(
                    filePath: localPath,
                    mimeType: mimeType,
                    subject: fileName,
                  );
                },
                icon: const Icon(Icons.share_rounded, size: 18),
                label: const Text('Share File'),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.onPrimary,
              ),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _exporting = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to export backup: $e')));
      }
    }
  }

  Future<void> _handleExportJsonClipboard() async {
    setState(() => _exporting = true);
    try {
      final jsonStr = await _api.exportBackupJson();
      var copiedToClipboard = false;
      if (jsonStr.length <= _maxClipboardChars) {
        await Clipboard.setData(ClipboardData(text: jsonStr));
        copiedToClipboard = true;
      }

      String? savedPath;
      try {
        final docDir = await getApplicationDocumentsDirectory();
        final file = File(p.join(docDir.path, 'shiori_backup_latest.json'));
        await file.writeAsString(jsonStr);
        savedPath = file.path;
        _lastSavedFilePath = savedPath;
      } catch (_) {}

      if (!mounted) return;
      setState(() => _exporting = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            copiedToClipboard
                ? 'Backup saved locally & copied to clipboard (${(jsonStr.length / 1024).toStringAsFixed(1)} KB)'
                : 'Backup too large for clipboard — saved to local file instead. Use Export Archive or Share!',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _exporting = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to create backup: $e')));
      }
    }
  }

  Future<void> _handlePickFileRestore() async {
    setState(() => _restoring = true);
    try {
      final picked = await PlatformBridge.instance.pickFile(
        mimeTypes: const [
          'application/octet-stream',
          'application/gzip',
          'application/json',
          '*/*',
        ],
      );
      if (picked == null) {
        if (mounted) setState(() => _restoring = false);
        return;
      }
      final result = await _api.restoreBackupBytes(picked.bytes);
      if (!mounted) return;
      setState(() => _restoring = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Restored ${result['bookmarks'] ?? 0} titles, ${result['categories'] ?? 0} categories & ${result['history'] ?? 0} history entries from ${picked.name}',
          ),
          backgroundColor: Colors.green.shade800,
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _restoring = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Restore failed: $e')));
      }
    }
  }

  Future<void> _handleRestorePaste() async {
    final textController = TextEditingController();

    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      if (clip?.text != null && clip!.text!.contains('"app": "Shiori"')) {
        textController.text = clip.text!;
      } else if (_lastSavedFilePath != null) {
        final file = File(_lastSavedFilePath!);
        if (await file.exists()) {
          textController.text = await file.readAsString();
        }
      }
    } catch (_) {}

    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            left: 20,
            right: 20,
            top: 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.settings_backup_restore_rounded,
                    color: AppColors.primary,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Restore JSON Backup',
                      style: AppText.sheetTitle,
                    ),
                  ),
                  IconButton(
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: AppColors.muted,
                    ),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Paste Shiori JSON backup text below (or load from your latest local backup):',
                style: AppText.body.copyWith(color: AppColors.muted),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: textController,
                maxLines: 6,
                style: AppText.mono,
                decoration: InputDecoration(
                  hintText: '{\n  "version": 2,\n  "app": "Shiori", ...\n}',
                  hintStyle: AppText.mono.copyWith(
                    color: AppColors.muted.withValues(alpha: .5),
                  ),
                  filled: true,
                  fillColor: AppColors.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppColors.outline),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () async {
                  final raw = textController.text.trim();
                  if (raw.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Please paste a valid backup first.'),
                      ),
                    );
                    return;
                  }

                  Navigator.pop(ctx);
                  setState(() => _restoring = true);

                  try {
                    final result = await _api.restoreBackupJson(raw);
                    if (mounted) {
                      setState(() => _restoring = false);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Restored ${result['bookmarks']} bookmarks and ${result['history']} reading progress entries!',
                          ),
                          backgroundColor: Colors.green.shade800,
                          duration: const Duration(seconds: 4),
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      setState(() => _restoring = false);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Failed to restore backup: Invalid format ($e)',
                          ),
                        ),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.download_done_rounded, size: 18),
                label: Text(
                  'Restore Now',
                  style: AppText.bodySemiBold.copyWith(
                    color: AppColors.onPrimary,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.onPrimary,
                  minimumSize: const Size.fromHeight(44),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final libraryCount = _api.libraryRepo.localLibrary.length;
    final historyCount = _api.historyRepo.localHistory.length;
    final sourcesCount = _extService.installedPackages.length;
    final categoriesCount = _api.libraryRepo.userCategories.length;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text('Backup & Transfer', style: AppText.title),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Compatibility & Transfer Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.primary.withValues(alpha: .2),
                  AppColors.surface,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: .3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: .2),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.devices_rounded,
                        color: AppColors.primary,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Mihon / Tachiyomi & Shiori Backups',
                            style: AppText.cardTitle,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Import or export standard .tachibk backups or compressed .shiori.json.gz files.',
                            style: AppText.caption,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Current Stats Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.outline),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _statItem(
                  label: 'Bookmarks',
                  value: '$libraryCount',
                  icon: Icons.bookmark_outline_rounded,
                ),
                _statDivider(),
                _statItem(
                  label: 'Categories',
                  value: '$categoriesCount',
                  icon: Icons.label_outline_rounded,
                ),
                _statDivider(),
                _statItem(
                  label: 'History',
                  value: '$historyCount',
                  icon: Icons.history_rounded,
                ),
                _statDivider(),
                _statItem(
                  label: 'Sources',
                  value: '$sourcesCount',
                  icon: Icons.extension_outlined,
                ),
              ],
            ),
          ),

          const SizedBox(height: 22),

          Text('EXPORT BACKUP', style: AppText.sectionHeader),
          const SizedBox(height: 10),

          _actionTile(
            icon: Icons.archive_rounded,
            color: AppColors.primary,
            title: 'Export Mihon / Tachiyomi (.tachibk)',
            subtitle:
                'Standard protobuf backup compatible with Mihon, Tachiyomi & SY',
            busy: _exporting,
            onTap: _exporting ? null : () => _handleExportFile(asTachibk: true),
          ),
          const SizedBox(height: 10),
          _actionTile(
            icon: Icons.folder_zip_rounded,
            color: const Color(0xFF10B981),
            title: 'Export Compressed File (.shiori.json.gz)',
            subtitle:
                'Full Shiori backup including cached chapters & installed sources',
            busy: _exporting,
            onTap: _exporting
                ? null
                : () => _handleExportFile(asTachibk: false),
          ),
          const SizedBox(height: 10),
          _actionTile(
            icon: Icons.copy_rounded,
            color: Colors.amber,
            title: 'Export & Copy JSON',
            subtitle: 'Save local JSON & copy to clipboard (up to 450 KB)',
            busy: _exporting,
            onTap: _exporting ? null : _handleExportJsonClipboard,
          ),

          const SizedBox(height: 22),

          Text('RESTORE BACKUP', style: AppText.sectionHeader),
          const SizedBox(height: 10),

          _actionTile(
            icon: Icons.file_open_rounded,
            color: Colors.blueAccent,
            title: 'Import Backup File (.tachibk / .json.gz / .json)',
            subtitle:
                'Auto-detects Mihon protobuf or Shiori archive from device storage',
            busy: _restoring,
            onTap: _restoring ? null : _handlePickFileRestore,
          ),
          const SizedBox(height: 10),
          _actionTile(
            icon: Icons.paste_rounded,
            color: Colors.lightBlueAccent,
            title: 'Restore from Pasted JSON',
            subtitle: 'Paste Shiori backup JSON or load latest local snapshot',
            busy: _restoring,
            onTap: _restoring ? null : _handleRestorePaste,
          ),

          const SizedBox(height: 22),

          Text('AUTOMATIC BACKUPS', style: AppText.sectionHeader),
          const SizedBox(height: 10),
          Material(
            color: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: AppColors.outline),
            ),
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile(
              value: _autoBackupEnabled,
              activeThumbColor: AppColors.primary,
              title: Text(
                'Automatic Local Snapshots',
                style: AppText.cardTitle,
              ),
              subtitle: Text(
                'Keeps the last 3 compressed backups automatically in app storage',
                style: AppText.caption,
              ),
              onChanged: _toggleAutoBackup,
            ),
          ),

          const SizedBox(height: 24),
          Text('CLOUD SYNC', style: AppText.sectionHeader),
          const SizedBox(height: 10),
          if (!_api.isLoggedIn)
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => showAuthModal(context),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.outline),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.cloud_queue_rounded,
                      color: AppColors.muted,
                      size: 28,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Sign in to sync', style: AppText.cardTitle),
                          const SizedBox(height: 2),
                          Text(
                            'Sign into the same account on any device to sync without files.',
                            style: AppText.caption,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            ValueListenableBuilder<SyncState>(
              valueListenable: ApiService.instance.syncState,
              builder: (context, syncState, _) {
                return Material(
                  color: AppColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: const BorderSide(color: AppColors.outline),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: syncState.isSyncing
                          ? const Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.primary,
                                ),
                              ),
                            )
                          : const Icon(
                              Icons.cloud_sync_rounded,
                              color: AppColors.primary,
                              size: 22,
                            ),
                    ),
                    title: Text(
                      'Cloud Account Synced',
                      style: AppText.cardTitle,
                    ),
                    subtitle: Text(
                      syncState.isSyncing
                          ? 'Syncing library and reading progress...'
                          : (syncState.lastSyncedAt != null
                                ? 'Last synced: ${syncState.lastSyncedAt!.toLocal().toString().split('.').first}'
                                : 'Tap to sync immediately with cloud'),
                      style: AppText.caption,
                    ),
                    trailing: FilledButton.tonal(
                      onPressed: syncState.isSyncing
                          ? null
                          : () async {
                              final ok = await ApiService.instance.syncNow();
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      ok
                                          ? 'Sync completed successfully'
                                          : 'Sync error. Please check network.',
                                    ),
                                    backgroundColor: AppColors.surfaceHigh,
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              }
                            },
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        minimumSize: const Size(80, 36),
                      ),
                      child: const Text('Sync Now'),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required bool busy,
    VoidCallback? onTap,
  }) {
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        title: Text(title, style: AppText.cardTitle),
        subtitle: Text(subtitle, style: AppText.caption),
        trailing: busy
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            : const Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: AppColors.muted,
              ),
        onTap: onTap,
      ),
    );
  }

  Widget _statItem({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Column(
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(height: 6),
        Text(value, style: AppText.title.copyWith(fontSize: 18)),
        const SizedBox(height: 2),
        Text(label, style: AppText.caption),
      ],
    );
  }

  Widget _statDivider() {
    return Container(width: 1, height: 36, color: AppColors.outline);
  }
}
