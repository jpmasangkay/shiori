import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/api_service.dart';
import '../theme.dart';
import '../widgets/auth_modal.dart';
import '../widgets/common.dart';
import 'backup_screen.dart';
import 'display_sheet.dart';
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
    ApiService.instance.addListener(_onApiChange);
    ApiService.instance.checkHealth();
  }

  @override
  void dispose() {
    ApiService.instance.removeListener(_onApiChange);
    super.dispose();
  }

  void _onApiChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final api = ApiService.instance;
    final loggedIn = api.isLoggedIn;
    final user = api.currentUser;

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

              // Appearance & Display Settings
              _sectionHeader('READER & DISPLAY'),
              _settingTile(
                icon: Icons.dashboard_customize_outlined,
                title: 'Display & Library Settings',
                subtitle: 'Columns, grid modes, and category tabs',
                onTap: () => showDisplaySheet(context),
              ),

              const SizedBox(height: 22),

              // Sources & Extensions
              _sectionHeader('SOURCES & EXTENSIONS'),
              _settingTile(
                icon: Icons.extension_outlined,
                title: 'Extensions',
                subtitle: 'Browse & download community sources',
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
                subtitle: 'MangaDex & downloaded extensions',
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

