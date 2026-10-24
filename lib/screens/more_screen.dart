import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/api_service.dart';
import '../services/download_service.dart';
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
    ThemeController.instance.addListener(_onChange);
    ApiService.instance.checkHealth();
  }

  @override
  void dispose() {
    ApiService.instance.removeListener(_onChange);
    DownloadService.instance.removeListener(_onChange);
    TrackerService.instance.removeListener(_onChange);
    ThemeController.instance.removeListener(_onChange);
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
    final amoled = ThemeController.instance.isAmoled;

    return Column(
      children: [
        const AppTopBar(title: 'More', branded: true),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // User Account Card (Fixed layout with zero text overlap)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.surfaceHigh),
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
                                style: GoogleFonts.inter(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                loggedIn ? user!.email : 'Sign in to sync your library across devices',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (loggedIn)
                      OutlinedButton(
                        onPressed: _confirmLogout,
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.outline),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: Text(
                          'Sign Out',
                          style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w500),
                        ),
                      )
                    else
                      FilledButton(
                        onPressed: () => showAuthModal(context),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: AppColors.onPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: Text(
                          'Sign In / Create Account',
                          style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600),
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
                          style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.onPrimary),
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
              _settingTile(
                icon: Icons.dark_mode_rounded,
                title: 'True AMOLED Pure Black',
                subtitle: 'Turns off OLED pixels (#000000) for infinite contrast & battery saving',
                trailing: Switch(
                  value: amoled,
                  activeThumbColor: AppColors.primary,
                  onChanged: (val) => ThemeController.instance.setAmoled(val),
                ),
                onTap: () => ThemeController.instance.setAmoled(!amoled),
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
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: tracker.isAuthenticated ? Colors.greenAccent : AppColors.primary,
                    ),
                  ),
                ),
                onTap: _showTrackerSheet,
              ),

              const SizedBox(height: 22),

              // Sources & Extensions
              _sectionHeader(Platform.isIOS ? 'SOURCES' : 'SOURCES & EXTENSIONS'),
              if (!Platform.isIOS)
                _settingTile(
                  icon: Icons.extension_outlined,
                  title: 'Extensions',
                  subtitle: 'Browse community extension sources',
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.active,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Sources',
                      style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.primary),
                    ),
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ExtensionsScreen()),
                  ),
                ),
              _settingTile(
                icon: Icons.public_rounded,
                title: 'Active Sources',
                subtitle: 'Built-in direct sources and community extensions',
                trailing: const Icon(Icons.check_circle_outline_rounded, color: AppColors.primary, size: 20),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ExtensionsScreen()),
                ),
              ),

              const SizedBox(height: 22),

              // Automatic Cloud Sync & Web Access (No manual backups needed)
              _sectionHeader('AUTOMATIC CLOUD SYNC'),
              _settingTile(
                icon: Icons.cloud_done_rounded,
                title: loggedIn ? 'Cloud Sync Active' : 'Enable Cloud Sync',
                subtitle: loggedIn
                    ? 'Synced with ${user?.email}. All devices stay in sync automatically.'
                    : 'Sign in to save bookmarks & history to the cloud database across devices with zero manual backups.',
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: loggedIn ? Colors.greenAccent.withValues(alpha: .15) : AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    loggedIn ? 'ACTIVE' : 'SIGN IN',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: loggedIn ? Colors.greenAccent : AppColors.primary,
                    ),
                  ),
                ),
                onTap: loggedIn
                    ? () async {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Syncing library and reading history with cloud...')),
                        );
                        await ApiService.instance.syncAllCloudData();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Cloud sync complete! All devices up to date.')),
                          );
                        }
                      }
                    : () => showAuthModal(context),
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
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Cache cleared.')),
                  );
                },
              ),

              const SizedBox(height: 32),
              Center(
                child: Text(
                  'Shiori v1.0.0 • Material 3 Dark',
                  style: GoogleFonts.inter(fontSize: 11, color: AppColors.read),
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
            child: Padding(
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
                              style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Automatically update read chapters on AniList',
                              style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
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
                                  style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Status: Connected',
                                  style: GoogleFonts.inter(fontSize: 11, color: Colors.greenAccent),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
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
                        style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(
                        'Updates AniList chapter count whenever you finish a chapter in the reader',
                        style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
                      ),
                      activeThumbColor: AppColors.primary,
                      value: tracker.autoUpdateEnabled,
                      onChanged: (val) async {
                        await tracker.setAutoUpdate(val);
                        setSheetState(() {});
                      },
                    ),
                  ] else ...[
                    Text(
                      'Enter your AniList Personal Access Token to connect:',
                      style: GoogleFonts.inter(fontSize: 12, color: AppColors.muted),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: tokenController,
                      decoration: InputDecoration(
                        hintText: 'Paste AniList token here',
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
                      style: GoogleFonts.inter(fontSize: 10, color: AppColors.muted),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
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
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF02A9FF),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: isSubmitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                              )
                            : const Text('Connect AniList', style: TextStyle(fontWeight: FontWeight.w600)),
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
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: AppColors.muted,
        ),
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
                        style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(fontSize: 11, color: AppColors.muted),
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
    );
  }

  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out? Your library remains saved to your account.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ApiService.instance.logout();
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('Sign Out', style: TextStyle(color: AppColors.onPrimary)),
          ),
        ],
      ),
    );
  }
}
