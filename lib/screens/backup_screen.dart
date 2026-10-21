import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/api_service.dart';
import '../services/extension_service.dart';
import '../theme.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _api = ApiService.instance;
  final _extService = ExtensionService.instance;
  bool _exporting = false;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _api.addListener(_onUpdate);
  }

  @override
  void dispose() {
    _api.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _handleExport() async {
    setState(() => _exporting = true);
    try {
      final jsonStr = await _api.exportBackupJson();
      await Clipboard.setData(ClipboardData(text: jsonStr));

      if (!mounted) return;
      setState(() => _exporting = false);

      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: AppColors.primary, size: 22),
              const SizedBox(width: 10),
              Text('Backup Created!', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w700)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your complete backup has been copied to your clipboard. You can paste it into a file, send it to another device via Quick Share, Drive, WhatsApp, or email.',
                style: GoogleFonts.inter(fontSize: 13, color: AppColors.muted, height: 1.4),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Size: ${(jsonStr.length / 1024).toStringAsFixed(1)} KB\n'
                  'Contains all bookmarks, reading progress, and installed sources.',
                  style: GoogleFonts.robotoMono(fontSize: 11, color: AppColors.text),
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              child: const Text('Got it'),
            ),
          ],
        ),
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Backup copied to clipboard! Ready to pass to another device.'),
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _exporting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create backup: $e')),
        );
      }
    }
  }

  Future<void> _handleRestore() async {
    final textController = TextEditingController();

    // Check if clipboard already contains a Shiori backup
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      if (clip?.text != null && clip!.text!.contains('"app": "Shiori"')) {
        textController.text = clip.text!;
      }
    } catch (_) {}

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
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
                const Icon(Icons.settings_backup_restore_rounded, color: AppColors.primary, size: 22),
                const SizedBox(width: 10),
                Text('Restore Backup', style: GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.muted),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Paste the backup JSON text exported from your other device below:',
              style: GoogleFonts.inter(fontSize: 13, color: AppColors.muted),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: textController,
              maxLines: 6,
              style: GoogleFonts.robotoMono(fontSize: 12, color: AppColors.text),
              decoration: InputDecoration(
                hintText: '{\n  "version": 1,\n  "app": "Shiori", ...\n}',
                hintStyle: TextStyle(color: AppColors.muted.withValues(alpha: .5), fontSize: 12),
                filled: true,
                fillColor: AppColors.bg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                final raw = textController.text.trim();
                if (raw.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please paste a valid backup first.')),
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
                      SnackBar(content: Text('Failed to restore backup: Invalid format ($e)')),
                    );
                  }
                }
              },
              icon: const Icon(Icons.download_done_rounded, size: 18),
              label: const Text('Restore Now'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.onPrimary,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
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
        title: Text('Backup & Transfer', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w600)),
      ),
      body: FutureBuilder(
        future: Future.wait([
          _api.getLibrary(),
          _api.getHistory(),
        ]),
        builder: (context, snapshot) {
          final libraryCount = snapshot.hasData ? (snapshot.data![0] as List).length : 0;
          final historyCount = snapshot.hasData ? (snapshot.data![1] as List).length : 0;
          final sourcesCount = _extService.installedPackages.length;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Device Transfer Concept Card
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
                  border: Border.all(color: AppColors.primary.withValues(alpha: .3)),
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
                          child: const Icon(Icons.devices_rounded, color: AppColors.primary, size: 24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Pass Data Across Devices',
                                style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Move bookmarks and reading progress to any phone or tablet.',
                                style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '1. Tap "Export & Copy Backup" on this device.\n'
                      '2. Send the backup to your other device (Drive, Quick Share, chat).\n'
                      '3. Open Shiori on the new device and tap "Restore Backup".',
                      style: GoogleFonts.inter(fontSize: 12, color: AppColors.text, height: 1.5),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // Current Stats Card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.surfaceHigh),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _statItem(label: 'Bookmarks', value: '$libraryCount', icon: Icons.bookmark_outline_rounded),
                    _statDivider(),
                    _statItem(label: 'History', value: '$historyCount', icon: Icons.history_rounded),
                    _statDivider(),
                    _statItem(label: 'Sources', value: '$sourcesCount', icon: Icons.extension_outlined),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              Text('BACKUP ACTIONS', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: AppColors.muted)),
              const SizedBox(height: 10),

              // Export Button
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.surfaceHigh),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: .15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.upload_rounded, color: AppColors.primary, size: 22),
                  ),
                  title: Text('Export & Copy Backup', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600)),
                  subtitle: Text('Generate full backup and copy to clipboard', style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted)),
                  trailing: _exporting
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary))
                      : const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.muted),
                  onTap: _exporting ? null : _handleExport,
                ),
              ),

              const SizedBox(height: 10),

              // Restore Button
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.surfaceHigh),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.blueAccent.withValues(alpha: .15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.download_rounded, color: Colors.blueAccent, size: 22),
                  ),
                  title: Text('Restore from Backup', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600)),
                  subtitle: Text('Paste backup text to restore bookmarks & progress', style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted)),
                  trailing: _restoring
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent))
                      : const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.muted),
                  onTap: _restoring ? null : _handleRestore,
                ),
              ),

              const SizedBox(height: 24),

              Text('AUTOMATIC CLOUD SYNC', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: AppColors.muted)),
              const SizedBox(height: 10),

              // Cloud Sync Info Card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.surfaceHigh),
                ),
                child: Row(
                  children: [
                    Icon(
                      _api.isLoggedIn ? Icons.cloud_done_rounded : Icons.cloud_queue_rounded,
                      color: _api.isLoggedIn ? Colors.greenAccent : AppColors.muted,
                      size: 28,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _api.isLoggedIn ? 'Cloud Sync Active' : 'Automatic Wireless Sync',
                            style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _api.isLoggedIn
                                ? 'Logged in as ${_api.currentUser?.email}. All bookmarks sync automatically.'
                                : 'Sign into the same account on any device to sync without files.',
                            style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _statItem({required String label, required String value, required IconData icon}) {
    return Column(
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(height: 6),
        Text(value, style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label, style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted)),
      ],
    );
  }

  Widget _statDivider() {
    return Container(
      width: 1,
      height: 36,
      color: AppColors.surfaceHigh,
    );
  }
}
