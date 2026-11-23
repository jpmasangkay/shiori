import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/privacy_service.dart';
import '../services/reader_settings.dart';
import '../services/source_manager.dart';
import '../services/tracker_service.dart';
import '../theme.dart';
import '../widgets/auth_modal.dart';
import '../widgets/common.dart';
import 'backup_screen.dart';
import 'display_sheet.dart';
import 'download_manager_screen.dart';
import 'extensions_screen.dart';
import 'reader_settings_screen.dart';
import 'stats_screen.dart';

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
    PrivacyService.instance.addListener(_onChange);
    ThemeController.instance.addListener(_onChange);
    ApiService.instance.checkHealth();
  }

  @override
  void dispose() {
    ApiService.instance.removeListener(_onChange);
    DownloadService.instance.removeListener(_onChange);
    TrackerService.instance.removeListener(_onChange);
    PrivacyService.instance.removeListener(_onChange);
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
    final privacy = PrivacyService.instance;
    final themeCtrl = ThemeController.instance;

    return Column(
      children: [
        const AppTopBar(title: 'More', branded: true),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                          backgroundColor: loggedIn
                              ? AppColors.active
                              : AppColors.surfaceHigh,
                          child: Icon(
                            loggedIn
                                ? Icons.person_rounded
                                : Icons.person_outline_rounded,
                            color: loggedIn
                                ? AppColors.primary
                                : AppColors.muted,
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
                                    ? (user?.displayName.isNotEmpty == true
                                          ? user!.displayName
                                          : user!.email)
                                    : 'Guest User',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.cardTitle,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                loggedIn
                                    ? user!.email
                                    : 'Sign in to sync your library across devices',
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
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
                                    style: AppText.caption.copyWith(
                                      color: color,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withValues(
                                      alpha: 0.12,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.cloud_done_rounded,
                                        size: 14,
                                        color: AppColors.primary,
                                      ),
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
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: () async {
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
                              icon: const Icon(Icons.sync_rounded, size: 16),
                              label: const Text('Sync Now'),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(42),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _confirmLogout,
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(
                                  color: AppColors.outline,
                                ),
                                minimumSize: const Size.fromHeight(42),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: Text(
                                'Sign Out',
                                style: AppText.bodyMedium.copyWith(
                                  color: AppColors.muted,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ] else
                      FilledButton(
                        onPressed: () => showAuthModal(context),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: AppColors.onPrimary,
                          minimumSize: const Size.fromHeight(44),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: Text(
                          'Sign In / Create Account',
                          style: AppText.bodySemiBold.copyWith(
                            color: AppColors.onPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Quick Incognito Toggle
              _settingTile(
                icon: Icons.visibility_off_outlined,
                title: 'Incognito Mode',
                subtitle: privacy.incognitoMode
                    ? 'Active • History & tracker sync are paused'
                    : 'Pauses reading history and tracker updates',
                trailing: Switch(
                  value: privacy.incognitoMode,
                  activeThumbColor: AppColors.primary,
                  onChanged: (v) => privacy.setIncognitoMode(v),
                ),
                onTap: () => privacy.setIncognitoMode(!privacy.incognitoMode),
              ),

              const SizedBox(height: 18),

              // Insights & Offline Downloads
              _sectionHeader('ACTIVITY & OFFLINE'),
              _settingTile(
                icon: Icons.bar_chart_rounded,
                title: 'Reading Statistics',
                subtitle:
                    'Chapters read, reading streak, genres & library breakdown',
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const StatsScreen())),
              ),
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${ds.activeTasks.length} downloading',
                          style: AppText.badge.copyWith(
                            color: AppColors.onPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    const Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 14,
                      color: AppColors.muted,
                    ),
                  ],
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const DownloadManagerScreen(),
                  ),
                ),
              ),

              const SizedBox(height: 18),

              // Reader & Appearance
              _sectionHeader('READER & APPEARANCE'),
              _settingTile(
                icon: Icons.menu_book_rounded,
                title: 'Global Reader Settings',
                subtitle:
                    'Direction defaults, volume keys, wakelock, double-page & filters',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ReaderSettingsScreen(),
                  ),
                ),
              ),
              _settingTile(
                icon: Icons.palette_outlined,
                title: 'Appearance & Theme',
                subtitle:
                    '${themeCtrl.mode.label} • ${themeCtrl.accent.label} accent',
                onTap: _showAppearanceSheet,
              ),
              _settingTile(
                icon: Icons.dashboard_customize_outlined,
                title: 'Display & Library Settings',
                subtitle: 'Filters, columns, grid modes, and category tabs',
                onTap: () => showDisplaySheet(context),
              ),
              ListenableBuilder(
                listenable: ReaderSettings.instance,
                builder: (context, _) {
                  final rs = ReaderSettings.instance;
                  return _settingTile(
                    icon: Icons.data_saver_on_rounded,
                    title: 'Data Saver (Slow Internet Mode)',
                    subtitle: rs.dataSaver
                        ? 'Enabled • Loads compressed images & conservative prefetch'
                        : 'Prefer compressed chapter images on slow connections',
                    trailing: Switch(
                      value: rs.dataSaver,
                      activeThumbColor: AppColors.primary,
                      onChanged: (val) => rs.setDataSaver(val),
                    ),
                    onTap: () => rs.setDataSaver(!rs.dataSaver),
                  );
                },
              ),

              const SizedBox(height: 18),

              // Tracking Services
              _sectionHeader('TRACKING SERVICES'),
              _settingTile(
                icon: Icons.sync_rounded,
                title: 'AniList Tracker',
                subtitle: tracker.isAuthenticated
                    ? 'Connected as ${tracker.currentUser?.name ?? "User"} • Auto-updates chapters'
                    : 'Sync reading progress automatically to AniList',
                trailing: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: tracker.isAuthenticated
                        ? Colors.greenAccent.withValues(alpha: .15)
                        : AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    tracker.isAuthenticated ? 'CONNECTED' : 'CONNECT',
                    style: AppText.badge.copyWith(
                      color: tracker.isAuthenticated
                          ? Colors.greenAccent
                          : AppColors.primary,
                    ),
                  ),
                ),
                onTap: _showTrackerSheet,
              ),
              _settingTile(
                icon: Icons.track_changes_rounded,
                title: 'MyAnimeList (OAuth2 PKCE)',
                subtitle: tracker.isTrackerAuthenticated('myanimelist')
                    ? 'Connected as ${tracker.getTrackerUsername('myanimelist') ?? 'MAL User'}'
                    : 'Sign in with MyAnimeList to auto-sync chapters & scores',
                trailing: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: tracker.isTrackerAuthenticated('myanimelist')
                        ? Colors.greenAccent.withValues(alpha: .15)
                        : AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    tracker.isTrackerAuthenticated('myanimelist')
                        ? 'CONNECTED'
                        : 'SIGN IN',
                    style: AppText.badge.copyWith(
                      color: tracker.isTrackerAuthenticated('myanimelist')
                          ? Colors.greenAccent
                          : AppColors.primary,
                    ),
                  ),
                ),
                onTap: () async {
                  if (tracker.isTrackerAuthenticated('myanimelist')) {
                    await tracker.logoutTracker('myanimelist');
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Disconnected from MyAnimeList'),
                        ),
                      );
                    }
                  } else {
                    final ok = await tracker.startMalOAuthFlow();
                    if (!ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Could not open browser for MyAnimeList OAuth.',
                          ),
                        ),
                      );
                    }
                  }
                },
              ),

              // Sources & Extensions (Android only; iOS uses built-in Direct Sources in Browse)
              if (!SourceManager.isIOSPlatform) ...[
                const SizedBox(height: 18),
                _sectionHeader('EXTENSIONS'),
                _settingTile(
                  icon: Icons.extension_outlined,
                  title: 'Extensions',
                  subtitle: 'Manage installed Tachiyomi / Keiyoushi extensions',
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
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

              const SizedBox(height: 18),

              // Privacy, Security & Networking
              _sectionHeader('PRIVACY & NETWORK'),
              _settingTile(
                icon: Icons.lock_outline_rounded,
                title: 'Security & App Lock',
                subtitle: privacy.appLockEnabled
                    ? 'App Lock active${privacy.secureScreen ? ' • Secure Screen on' : ''}'
                    : (privacy.secureScreen
                          ? 'Secure Screen enabled'
                          : 'Biometric lock, PIN & screenshot protection'),
                onTap: _showSecuritySheet,
              ),
              _settingTile(
                icon: Icons.dns_outlined,
                title: 'Networking & Sync Server',
                subtitle:
                    'DoH: ${privacy.dohProvider.toUpperCase()} • Custom sync host',
                onTap: _showNetworkingSheet,
              ),

              const SizedBox(height: 18),

              // Data & Backup (Cloud sync entry hidden when signed in; silent background sync)
              _sectionHeader('DATA & BACKUP'),
              if (!loggedIn)
                _settingTile(
                  icon: Icons.cloud_upload_outlined,
                  title: 'Sign in to sync',
                  subtitle:
                      'Save bookmarks & history to the cloud across devices',
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
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
                subtitle:
                    'Export/import .tachibk, .shiori.json.gz & automatic snapshots',
                trailing: const Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 14,
                  color: AppColors.muted,
                ),
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const BackupScreen())),
              ),

              const SizedBox(height: 18),

              // Storage & Cache
              _sectionHeader('STORAGE & CACHE'),
              _settingTile(
                icon: Icons.cleaning_services_outlined,
                title: 'Clear Cache',
                subtitle:
                    'Free up local cover and reader cache (${ds.formatBytes(totalDownloadBytes)} downloaded)',
                onTap: () async {
                  await ApiService.instance.clearAllCaches();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Cache cleared successfully.'),
                      ),
                    );
                  }
                },
              ),

              const SizedBox(height: 28),
              Center(
                child: Text(
                  'Shiori v1.0.0 • Material 3',
                  style: AppText.caption.copyWith(color: AppColors.read),
                ),
              ),
            ],
            ),
          ),
        ),
      ],
    );
  }

  void _showAppearanceSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ListenableBuilder(
        listenable: ThemeController.instance,
        builder: (ctx, _) {
          final tc = ThemeController.instance;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Appearance & Theme', style: AppText.sheetTitle),
                  const SizedBox(height: 14),
                  Text('THEME SURFACE', style: AppText.sectionHeader),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mode in ShioriThemeMode.values)
                        ChoiceChip(
                          label: Text(mode.label),
                          selected: tc.mode == mode,
                          onSelected: (_) => tc.setThemeMode(mode),
                          selectedColor: AppColors.active,
                          backgroundColor: AppColors.surfaceHigh,
                          labelStyle: AppText.chip.copyWith(
                            color: tc.mode == mode
                                ? AppColors.primary
                                : AppColors.muted,
                          ),
                          showCheckmark: false,
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text('ACCENT COLOR', style: AppText.sectionHeader),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final acc in ShioriAccent.values)
                        ChoiceChip(
                          avatar: CircleAvatar(
                            radius: 8,
                            backgroundColor: acc.primary,
                          ),
                          label: Text(acc.label),
                          selected: tc.accent == acc,
                          onSelected: (_) => tc.setAccent(acc),
                          selectedColor: acc.primary.withValues(alpha: 0.22),
                          backgroundColor: AppColors.surfaceHigh,
                          labelStyle: AppText.chip.copyWith(
                            color: tc.accent == acc
                                ? acc.primary
                                : AppColors.muted,
                          ),
                          showCheckmark: false,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showSecuritySheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ListenableBuilder(
        listenable: PrivacyService.instance,
        builder: (ctx, _) {
          final p = PrivacyService.instance;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Security & App Lock', style: AppText.sheetTitle),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: p.secureScreen,
                    activeThumbColor: AppColors.primary,
                    title: Text('Secure Screen', style: AppText.bodyMedium),
                    subtitle: Text(
                      'Hides app content in recent apps switcher & blocks screenshots',
                      style: AppText.caption,
                    ),
                    onChanged: p.setSecureScreen,
                  ),
                  const Divider(color: AppColors.outline),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: p.appLockEnabled,
                    activeThumbColor: AppColors.primary,
                    title: Text('App Lock', style: AppText.bodyMedium),
                    subtitle: Text(
                      'Require biometric authentication or PIN when resuming Shiori',
                      style: AppText.caption,
                    ),
                    onChanged: p.setAppLockEnabled,
                  ),
                  if (p.appLockEnabled) ...[
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: p.useBiometric,
                      activeThumbColor: AppColors.primary,
                      title: Text(
                        'Biometric Unlock',
                        style: AppText.bodyMedium,
                      ),
                      subtitle: Text(
                        'Fingerprint / Face unlock when available',
                        style: AppText.caption,
                      ),
                      onChanged: p.setUseBiometric,
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        p.hasPin ? 'Change Fallback PIN' : 'Set Fallback PIN',
                        style: AppText.bodyMedium,
                      ),
                      subtitle: Text(
                        p.hasPin
                            ? 'PIN configured (SHA-256 protected)'
                            : 'Recommended if biometrics are unavailable',
                        style: AppText.caption,
                      ),
                      trailing: const Icon(
                        Icons.pin_outlined,
                        color: AppColors.primary,
                      ),
                      onTap: () => _promptSetPin(ctx),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Lock Timeout', style: AppText.bodyMedium),
                      subtitle: Text(
                        p.lockTimeoutSeconds == 0
                            ? 'Immediately'
                            : '${p.lockTimeoutSeconds} seconds after leaving app',
                        style: AppText.caption.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                      trailing: DropdownButton<int>(
                        value:
                            const [
                              0,
                              30,
                              60,
                              300,
                            ].contains(p.lockTimeoutSeconds)
                            ? p.lockTimeoutSeconds
                            : 0,
                        dropdownColor: AppColors.surfaceHigh,
                        underline: const SizedBox(),
                        style: AppText.body,
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('Always')),
                          DropdownMenuItem(value: 30, child: Text('30s')),
                          DropdownMenuItem(value: 60, child: Text('1 min')),
                          DropdownMenuItem(value: 300, child: Text('5 min')),
                        ],
                        onChanged: (v) {
                          if (v != null) p.setLockTimeoutSeconds(v);
                        },
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

  void _promptSetPin(BuildContext sheetCtx) {
    final pinCtrl = TextEditingController();
    showDialog<void>(
      context: sheetCtx,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Set App Lock PIN', style: AppText.sheetTitle),
        content: TextField(
          controller: pinCtrl,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 8,
          autofocus: true,
          style: AppText.body,
          decoration: const InputDecoration(hintText: '4–8 digits'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final pin = pinCtrl.text.trim();
              if (pin.length < 4) return;
              await PrivacyService.instance.setPin(pin);
              if (dCtx.mounted) Navigator.pop(dCtx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('App Lock PIN saved securely.')),
                );
              }
            },
            child: const Text('Save PIN'),
          ),
        ],
      ),
    );
  }

  void _showNetworkingSheet() {
    final urlCtrl = TextEditingController(text: ApiService.instance.baseUrl);
    const dohProviders = [
      ('none', 'System Default (Off)'),
      ('cloudflare', 'Cloudflare (1.1.1.1)'),
      ('google', 'Google (8.8.8.8)'),
      ('quad9', 'Quad9 (9.9.9.9)'),
      ('adguard', 'AdGuard DNS'),
    ];

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ListenableBuilder(
        listenable: PrivacyService.instance,
        builder: (ctx, _) {
          final p = PrivacyService.instance;
          return SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                MediaQuery.viewInsetsOf(ctx).bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Networking & Sync Server', style: AppText.sheetTitle),
                  const SizedBox(height: 14),
                  Text(
                    'DNS OVER HTTPS (ANDROID EXTENSIONS)',
                    style: AppText.sectionHeader,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (id, label) in dohProviders)
                        ChoiceChip(
                          label: Text(label),
                          selected: p.dohProvider == id,
                          onSelected: (_) => p.setDohProvider(id),
                          selectedColor: AppColors.active,
                          backgroundColor: AppColors.surfaceHigh,
                          labelStyle: AppText.chip.copyWith(
                            color: p.dohProvider == id
                                ? AppColors.primary
                                : AppColors.muted,
                          ),
                          showCheckmark: false,
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text('SYNC BACKEND HOST URL', style: AppText.sectionHeader),
                  const SizedBox(height: 8),
                  TextField(
                    controller: urlCtrl,
                    style: AppText.mono,
                    decoration: InputDecoration(
                      hintText: 'https://your-shiori-server.example/api',
                      filled: true,
                      fillColor: AppColors.surfaceHigh,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () async {
                      final u = urlCtrl.text.trim();
                      if (u.startsWith('http://') || u.startsWith('https://')) {
                        await ApiService.instance.setBaseUrl(u);
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Sync server updated to ${ApiService.instance.baseUrl}',
                              ),
                            ),
                          );
                        }
                      }
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.onPrimary,
                      minimumSize: const Size.fromHeight(44),
                    ),
                    child: const Text('Save Backend URL'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showTrackerSheet() {
    final tracker = TrackerService.instance;
    final tokenController = TextEditingController();
    var isSubmitting = false;

    showModalBottomSheet<void>(
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
                        child: const Icon(
                          Icons.sync_rounded,
                          color: Color(0xFF02A9FF),
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('AniList Tracking', style: AppText.sheetTitle),
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
                            backgroundImage: user?.avatarUrl != null
                                ? NetworkImage(user!.avatarUrl!)
                                : null,
                            child: user?.avatarUrl == null
                                ? const Icon(Icons.person)
                                : null,
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
                                  style: AppText.caption.copyWith(
                                    color: Colors.greenAccent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            constraints: const BoxConstraints(
                              minWidth: 44,
                              minHeight: 44,
                            ),
                            icon: const Icon(
                              Icons.logout_rounded,
                              color: Colors.redAccent,
                            ),
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
                                    const SnackBar(
                                      content: Text(
                                        'Connected to AniList successfully!',
                                      ),
                                    ),
                                  );
                                }
                              }
                            },
                      icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                      label: Text(
                        'Sign in with AniList (OAuth)',
                        style: AppText.bodySemiBold,
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF02A9FF),
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(44),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Expanded(
                          child: Divider(color: AppColors.outline),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            'OR USE TOKEN',
                            style: AppText.badge.copyWith(
                              color: AppColors.muted,
                            ),
                          ),
                        ),
                        const Expanded(
                          child: Divider(color: AppColors.outline),
                        ),
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
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
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
                                final success = await tracker.loginWithToken(
                                  tok,
                                );
                                setSheetState(() => isSubmitting = false);

                                if (success) {
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  if (mounted) {
                                    setState(() {});
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Connected to AniList successfully!',
                                        ),
                                      ),
                                    );
                                  }
                                } else {
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Invalid AniList token. Please try again.',
                                        ),
                                      ),
                                    );
                                  }
                                }
                              },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF02A9FF)),
                          minimumSize: const Size.fromHeight(44),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: isSubmitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Color(0xFF02A9FF),
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                'Connect with Token',
                                style: AppText.bodySemiBold.copyWith(
                                  color: const Color(0xFF02A9FF),
                                ),
                              ),
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
      child: Text(text, style: AppText.sectionHeader),
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
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.muted,
                      size: 20,
                    ),
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
    showDialog<void>(
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
                title: Text(
                  'Clear local library & history from this device',
                  style: AppText.bodyMedium,
                ),
                subtitle: Text(
                  'Removes cached local data from this device for privacy. Cloud backup remains intact.',
                  style: AppText.caption,
                ),
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
              child: Text(
                'Cancel',
                style: AppText.bodyMedium.copyWith(color: AppColors.muted),
              ),
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
              child: Text(
                'Sign Out',
                style: AppText.bodySemiBold.copyWith(
                  color: AppColors.onPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
