import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/source_manager.dart';
import '../services/tracker_service.dart';
import '../theme.dart';
import '../widgets/auth_modal.dart';
import '../widgets/common.dart';
import 'backup_screen.dart';
import 'display_sheet.dart';
import 'download_manager_screen.dart';
import 'extensions_screen.dart';

class MoreScreen extends StatefulWidget {
  const MoreScreen({super.key});

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  @override
  void initState() {
    super.initState();
    ApiService.instance.addListener(_onChange);
    DownloadService.instance.addListener(_onChange);
    TrackerService.instance.addListener(_onChange);
    ApiService.instance.checkHealth();
  }

  @override
  void dispose() {
    ApiService.instance.removeListener(_onChange);
    DownloadService.instance.removeListener(_onChange);
    TrackerService.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final api = ApiService.instance;
    final loggedIn = api.isLoggedIn;
    final user = api.currentUser;
    final ds = DownloadService.instance;
    final downloadedCount = ds.downloadedChapters.length;
    final totalDownloadBytes = ds.getTotalDownloadSizeBytes();
    final tracker = TrackerService.instance;

    return Column(
      children: [
        const AppTopBar(title: 'More', branded: true),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // User Account Card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.outline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 24,
                          backgroundColor: loggedIn ? AppColors.active : AppColors.surfaceHigh,
                          child: Icon(
                            loggedIn ? Icons.person_rounded : Icons.person_outline_rounded,
                            color: loggedIn ? AppColors.primary : AppColors.muted,
                            size: 26,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                loggedIn
                                    ? (user?.displayName.isNotEmpty == true ? user!.displayName : user!.email)
                                    : 'Guest User',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.cardTitle,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                loggedIn ? user!.email : 'Sign in to sync your library across devices',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.caption,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (loggedIn) ...[
                      ValueListenableBuilder<SyncState>(
                        valueListenable: ApiService.instance.syncState,
                        builder: (context, state, _) {
                          final Widget icon;
                          final String label;
                          final Color color;
                          switch (state.status) {
                            case SyncStatus.syncing:
                              icon = const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.primary,
                                ),
                              );
                              label = 'Syncing...';
                              color = AppColors.primary;
                            case SyncStatus.error:
                              icon = const Icon(
                                Icons.error_outline_rounded,
                                size: 14,
                                color: Colors.orangeAccent,
                              );
                              label = 'Sync Error';
                              color = Colors.orangeAccent;
                            case SyncStatus.success:
                            case SyncStatus.idle:
                              icon = const Icon(
                                Icons.cloud_done_rounded,
                                size: 14,
                                color: Colors.greenAccent,
                              );
                              label = 'Synced';
                              color = Colors.greenAccent;
                          }

                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceHigh,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                icon,
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    label,
                                    style: AppText.caption.copyWith(color: color, fontWeight: FontWeight.w500),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.cloud_done_rounded, size: 14, color: AppColors.primary),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Auto-Sync Active',
                                        style: AppText.caption.copyWith(
                                          color: AppColors.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      OutlinedButton(
                        onPressed: _confirmLogout,
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.outline),
                          minimumSize: const Size.fromHeight(44),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: Text(
                          'Sign Out',
                          style: AppText.bodyMedium.copyWith(color: AppColors.muted),
                        ),
                      ),
                    ] else
                      FilledButton(
                        onPressed: () => showAuthModal(context),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: AppColors.onPrimary,
                          minimumSize: const Size.fromHeight(44),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: Text(
                          'Sign In / Create Account',
                          style: AppText.bodySemiBold.copyWith(color: AppColors.onPrimary),
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 22),

              // Offline Downloads
              _sectionHeader('DOWNLOADS & OFFLINE'),
              _settingTile(
                icon: Icons.download_for_offline_rounded,
                title: 'Download Manager',
                subtitle: downloadedCount > 0
                    ? '$downloadedCount chapters • ${ds.formatBytes(totalDownloadBytes)} offline storage'
                    : 'Download chapters for 100% offline reading',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (ds.activeTasks.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${ds.activeTasks.length} downloading',
                          style: AppText.badge.copyWith(color: AppColors.onPrimary),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.muted),
                  ],
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DownloadManagerScreen()),
                ),
              ),

              const SizedBox(height: 22),

              // Appearance & Display Settings
              _sectionHeader('READER & DISPLAY'),
              _settingTile(
                icon: Icons.dashboard_customize_outlined,
                title: 'Display & Library Settings',
                subtitle: 'Columns, grid modes, and category tabs',
                onTap: () => showDisplaySheet(context),
              ),

              const SizedBox(height: 22),

              // Tracking Services
              _sectionHeader('TRACKING SERVICES'),
              _settingTile(
                icon: Icons.sync_rounded,
                title: 'AniList Tracker',
                subtitle: tracker.isAuthenticated
                    ? 'Connected as ${tracker.currentUser?.name ?? "User"} • Auto-updates chapters'
                    : 'Sync reading progress automatically to AniList',
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: tracker.isAuthenticated
                        ? Colors.greenAccent.withValues(alpha: .15)
                        : AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    tracker.isAuthenticated ? 'CONNECTED' : 'CONNECT',
                    style: AppText.badge.copyWith(
                      color: tracker.isAuthenticated ? Colors.greenAccent : AppColors.primary,
                    ),
                  ),
                ),
                onTap: _showTrackerSheet,
              ),

              // Sources & Extensions (Android only; iOS uses built-in Direct Sources in Browse)
              if (!SourceManager.isIOSPlatform) ...[
                const SizedBox(height: 22),
                _sectionHeader('EXTENSIONS'),
                _settingTile(
                  icon: Icons.extension_outlined,
                  title: 'Extensions',
                  subtitle: 'Manage installed Tachiyomi / Keiyoushi extensions',
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.active,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Manage',
                      style: AppText.badge.copyWith(color: AppColors.primary),
                    ),
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ExtensionsScreen()),
                  ),
                ),
              ],

              const SizedBox(height: 22),

              // Data & Backup (Cloud sync entry hidden when signed in; silent background sync)
              _sectionHeader('DATA & BACKUP'),
              if (!loggedIn)
                _settingTile(
                  icon: Icons.cloud_upload_outlined,
                  title: 'Sign in to sync',
                  subtitle: 'Save bookmarks & history to the cloud across devices',
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'SIGN IN',
                      style: AppText.badge.copyWith(color: AppColors.primary),
                    ),
                  ),
                  onTap: () => showAuthModal(context),
                ),
              _settingTile(
                icon: Icons.sync_alt_rounded,
                title: 'Offline Backup & File Export',
                subtitle: 'Optional JSON file export for offline local storage',
                trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.muted),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BackupScreen()),
                ),
              ),

              const SizedBox(height: 22),

              // Storage & Cache
              _sectionHeader('STORAGE & CACHE'),
              _settingTile(
                icon: Icons.cleaning_services_outlined,
                title: 'Clear Cache',
                subtitle: 'Free up local cover and reader cache',
                onTap: () async {
                  await ApiService.instance.clearAllCaches();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Cache cleared successfully.')),
                    );
                  }
                },
              ),

              const SizedBox(height: 32),
              Center(
                child: Text(
                  'Shiori v1.0.0 • Material 3 Dark',
                  style: AppText.caption.copyWith(color: AppColors.read),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showTrackerSheet() {
    final tracker = TrackerService.instance;
    final tokenController = TextEditingController();
    var isSubmitting = false;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final isAuth = tracker.isAuthenticated;
          final user = tracker.currentUser;

          return SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF02A9FF).withValues(alpha: .2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.sync_rounded, color: Color(0xFF02A9FF), size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'AniList Tracking',
                              style: AppText.sheetTitle,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Automatically update read chapters on AniList',
                              style: AppText.caption,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  if (isAuth) ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceHigh,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 20,
                            backgroundImage: user?.avatarUrl != null ? NetworkImage(user!.avatarUrl!) : null,
                            child: user?.avatarUrl == null ? const Icon(Icons.person) : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  user?.name ?? 'AniList User',
                                  style: AppText.cardTitle,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Status: Connected',
                                  style: AppText.caption.copyWith(color: Colors.greenAccent),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                            icon: const Icon(Icons.logout_rounded, color: Colors.redAccent),
                            tooltip: 'Disconnect AniList',
                            onPressed: () async {
                              await tracker.logout();
                              setSheetState(() {});
                              if (mounted) setState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Auto-update reading progress',
                        style: AppText.bodyMedium,
                      ),
                      subtitle: Text(
                        'Updates AniList chapter count whenever you finish a chapter in the reader',
                        style: AppText.caption,
                      ),
                      activeThumbColor: AppColors.primary,
                      value: tracker.autoUpdateEnabled,
                      onChanged: (val) async {
                        await tracker.setAutoUpdate(val);
                        setSheetState(() {});
                      },
                    ),
                  ] else ...[
                    FilledButton.icon(
                      onPressed: isSubmitting
                          ? null
                          : () async {
                              setSheetState(() => isSubmitting = true);
                              final ok = await tracker.startOAuthFlow();
                              setSheetState(() => isSubmitting = false);
                              if (ok) {
                                if (ctx.mounted) Navigator.pop(ctx);
                                if (mounted) {
                                  setState(() {});
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Connected to AniList successfully!')),
                                  );
                                }
                              }
                            },
                      icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                      label: Text('Sign in with AniList (OAuth)', style: AppText.bodySemiBold),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF02A9FF),
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(44),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Expanded(child: Divider(color: AppColors.outline)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text('OR USE TOKEN', style: AppText.badge.copyWith(color: AppColors.muted)),
                        ),
                        const Expanded(child: Divider(color: AppColors.outline)),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Enter your AniList Personal Access Token:',
                      style: AppText.caption,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: tokenController,
                      style: AppText.body,
                      decoration: InputDecoration(
                        hintText: 'Paste AniList token here',
                        hintStyle: AppText.caption,
                        filled: true,
                        fillColor: AppColors.surfaceHigh,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                      obscureText: true,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'You can generate a token in AniList Settings > Developer > Create New Client.',
                      style: AppText.caption,
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: isSubmitting
                            ? null
                            : () async {
                                final tok = tokenController.text.trim();
                                if (tok.isEmpty) return;

                                setSheetState(() => isSubmitting = true);
                                final success = await tracker.loginWithToken(tok);
                                setSheetState(() => isSubmitting = false);

                                if (success) {
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  if (mounted) {
                                    setState(() {});
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Connected to AniList successfully!')),
                                    );
                                  }
                                } else {
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      const SnackBar(content: Text('Invalid AniList token. Please try again.')),
                                    );
                                  }
                                }
                              },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF02A9FF)),
                          minimumSize: const Size.fromHeight(44),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: isSubmitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(color: Color(0xFF02A9FF), strokeWidth: 2),
                              )
                            : Text('Connect with Token', style: AppText.bodySemiBold.copyWith(color: const Color(0xFF02A9FF))),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
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

  Widget _settingTile({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(icon, color: AppColors.primary, size: 22),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.bodyMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption,
                        ),
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing,
                  ] else if (onTap != null) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right_rounded, color: AppColors.muted, size: 20),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _confirmLogout() {
    var clearLocalData = false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          scrollable: true,
          backgroundColor: AppColors.surface,
          title: Text('Sign Out', style: AppText.sheetTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Are you sure you want to sign out? Your library remains saved to your account.',
                style: AppText.body,
              ),
              const SizedBox(height: 14),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: clearLocalData,
                activeColor: AppColors.primary,
                title: Text('Clear local library & history from this device', style: AppText.bodyMedium),
                subtitle: Text('Removes cached local data from this device for privacy. Cloud backup remains intact.', style: AppText.caption),
                onChanged: (val) {
                  setDialogState(() => clearLocalData = val ?? false);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
              child: Text('Cancel', style: AppText.bodyMedium.copyWith(color: AppColors.muted)),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                ApiService.instance.logout(clearLocalData: clearLocalData);
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                minimumSize: const Size(64, 44),
              ),
              child: Text('Sign Out', style: AppText.bodySemiBold.copyWith(color: AppColors.onPrimary)),
            ),
          ],
        ),
      ),
    );
  }
}
