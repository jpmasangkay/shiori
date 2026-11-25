import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'display_settings.dart';
import 'screens/backup_screen.dart';
import 'screens/browse_screen.dart';
import 'screens/download_manager_screen.dart';
import 'screens/history_screen.dart';
import 'screens/library_screen.dart';
import 'screens/more_screen.dart';
import 'screens/updates_screen.dart';
import 'services/api_service.dart';
import 'services/connectivity_service.dart';
import 'services/download_service.dart';
import 'services/extension_service.dart';
import 'services/privacy_service.dart';
import 'services/reader_settings.dart';
import 'services/source_manager.dart';
import 'services/tracker_service.dart';
import 'theme.dart';
import 'widgets/auth_modal.dart';
import 'widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Generous decoded image cache so going back across pages & webtoon strips stays 0ms instant
  PaintingBinding.instance.imageCache.maximumSize = 500;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 256 * 1024 * 1024; // 256 MB
  await ThemeController.instance.init();
  await PrivacyService.instance.init();
  await DisplaySettings.instance.init();
  await ReaderSettings.instance.init();
  await ConnectivityService.instance.init();
  await ApiService.instance.init();
  await DownloadService.instance.init();
  await TrackerService.instance.init();
  runApp(const ShioriApp());
}

class ShioriApp extends StatelessWidget {
  const ShioriApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) {
        final ctrl = ThemeController.instance;
        return MaterialApp(
          title: 'Shiori',
          debugShowCheckedModeBanner: false,
          themeMode: ctrl.materialThemeMode,
          theme: ctrl.mode == ShioriThemeMode.system
              ? buildTheme(forceLight: true)
              : buildTheme(),
          darkTheme: buildTheme(),
          home: const RootShell(),
        );
      },
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with WidgetsBindingObserver {
  int _index = 0;
  final Set<int> _loadedTabs = {0};
  DateTime _lastAutoRefreshAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastBackPressedAt;
  Timer? _startupSyncTimer;
  static const _resumeRefreshCooldown = Duration(minutes: 30);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Defer lightweight cooldown-gated sync & daily auto-backup until after initial frames settle
    _startupSyncTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      _lastAutoRefreshAt = DateTime.now();
      ApiService.instance.autoRefreshEverything();
      unawaited(BackupScreen.runScheduledAutoBackupIfDue());
    });
  }

  @override
  void dispose() {
    _startupSyncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      PrivacyService.instance.onAppBackgrounded();
    } else if (state == AppLifecycleState.resumed) {
      PrivacyService.instance.onAppResumed();
      if (DateTime.now().difference(_lastAutoRefreshAt) >= _resumeRefreshCooldown) {
        _lastAutoRefreshAt = DateTime.now();
        ApiService.instance.autoRefreshEverything();
      }
    }
  }

  static const _destinations = [
    (Icons.collections_bookmark_outlined, Icons.collections_bookmark_rounded, 'Library'),
    (Icons.update_rounded, Icons.update_rounded, 'Updates'),
    (Icons.history_rounded, Icons.history_rounded, 'History'),
    (Icons.explore_outlined, Icons.explore_rounded, 'Browse'),
    (Icons.more_horiz_rounded, Icons.more_horiz_rounded, 'More'),
  ];

  void _onSelectTab(int i) {
    if (i == _index) return;
    setState(() {
      _index = i;
      _loadedTabs.add(i);
    });
  }

  Widget _buildTabContent(int index) {
    final active = _index == index;
    return RepaintBoundary(
      child: switch (index) {
        0 => LibraryScreen(isActive: active),
        1 => UpdatesScreen(isActive: active),
        2 => HistoryScreen(isActive: active),
        3 => const BrowseScreen(),
        4 => const MoreScreen(),
        _ => const SizedBox.shrink(),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PrivacyService.instance,
      builder: (context, _) {
        if (PrivacyService.instance.isLocked) {
          return const _AppLockScreen();
        }
        return _buildMainScaffold(context);
      },
    );
  }

  int _unreadUpdatesBadgeCount() {
    final cached = ApiService.instance.getCachedUpdates();
    final groups = cached['groups'];
    if (groups is! Map) return 0;
    var unread = 0;
    for (final list in groups.values) {
      if (list is! List) continue;
      for (final item in list) {
        if (item is Map) {
          final mId = item['mangaId']?.toString() ?? '';
          final chId = item['id']?.toString() ?? '';
          if (mId.isNotEmpty &&
              chId.isNotEmpty &&
              !ApiService.instance.isChapterRead(mId, chId)) {
            unread++;
          }
        }
      }
    }
    return unread;
  }

  Widget _badgedNavIcon(IconData icon, int count) {
    if (count <= 0) return Icon(icon, size: 26);
    return Badge(
      label: Text(count > 99 ? '99+' : '$count'),
      backgroundColor: AppColors.primary,
      textColor: AppColors.onPrimary,
      child: Icon(icon, size: 26),
    );
  }

  Widget _buildActiveDownloadsMiniBar() {
    return ListenableBuilder(
      listenable: DownloadService.instance,
      builder: (context, _) {
        final ds = DownloadService.instance;
        final active = ds.activeTasks;
        if (active.isEmpty) return const SizedBox.shrink();
        final current = active.first;
        final pct = current.totalPages > 0
            ? (current.downloadedPages / current.totalPages).clamp(0.0, 1.0)
            : null;
        return Material(
          color: AppColors.surface,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              smoothRoute(const DownloadManagerScreen()),
            ),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.outline)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        ds.isPaused ? Icons.pause_circle_outline_rounded : Icons.downloading_rounded,
                        size: 18,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          ds.isPaused
                              ? 'Downloads paused (${active.length} queued)'
                              : 'Downloading ${current.manga.displayTitle} • ${current.chapter.displayTitle}${active.length > 1 ? ' (+${active.length - 1})' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(
                            color: AppColors.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          ds.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                          size: 18,
                          color: AppColors.primary,
                        ),
                        tooltip: ds.isPaused ? 'Resume downloads' : 'Pause downloads',
                        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        padding: EdgeInsets.zero,
                        onPressed: () {
                          if (ds.isPaused) {
                            ds.resumeQueue();
                          } else {
                            ds.pauseQueue();
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: ds.isPaused ? (pct ?? 0.0) : pct,
                      minHeight: 2.5,
                      color: AppColors.primary,
                      backgroundColor: AppColors.surfaceHigh,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMainScaffold(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_index != 0) {
          _onSelectTab(0);
          return;
        }
        final now = DateTime.now();
        if (_lastBackPressedAt != null &&
            now.difference(_lastBackPressedAt!) < const Duration(seconds: 2)) {
          SystemNavigator.pop();
          return;
        }
        _lastBackPressedAt = now;
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Press back again to exit'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      child: Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 0. Incognito Mode active banner
            if (PrivacyService.instance.incognitoMode)
              Material(
                color: const Color(0xFF312E81),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.visibility_off_rounded, size: 16, color: Colors.white),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Incognito mode — reading history & tracker sync paused',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => PrivacyService.instance.setIncognitoMode(false),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Turn off', style: TextStyle(fontSize: 11.5)),
                      ),
                    ],
                  ),
                ),
              ),

            // 1. Offline connectivity notification banner (#28)
            ListenableBuilder(
              listenable: ConnectivityService.instance,
              builder: (context, _) {
                if (!ConnectivityService.instance.isOffline) {
                  return const SizedBox.shrink();
                }
                return Material(
                  color: const Color(0xFFD97706),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.wifi_off_rounded, size: 18, color: Colors.white),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Offline mode — local library & cached chapters ready',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => ConnectivityService.instance.recheck(),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text(
                            'Retry',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

            // 2. Session expired notification banner (#8, #36)
            ListenableBuilder(
              listenable: ApiService.instance.auth,
              builder: (context, _) {
                if (!ApiService.instance.auth.isSessionExpired) {
                  return const SizedBox.shrink();
                }
                return Material(
                  color: const Color(0xFFDC2626),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.lock_clock_outlined, size: 18, color: Colors.white),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Session expired. Please sign in again.',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => showAuthModal(context),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text(
                            'Sign In',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 16, color: Colors.white70),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () => ApiService.instance.clearSessionExpiredBanner(),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

            // 3. Tab content with optimized Offstage + TickerMode tree (#13)
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  for (var i = 0; i < _destinations.length; i++)
                    if (_loadedTabs.contains(i))
                      Offstage(
                        offstage: _index != i,
                        child: TickerMode(
                          enabled: _index == i,
                          child: _buildTabContent(i),
                        ),
                      ),
                ],
              ),
            ),
            // 4. Compact active downloads indicator bar
            _buildActiveDownloadsMiniBar(),
          ],
        ),
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: Listenable.merge([
          ApiService.instance,
          ExtensionService.instance,
        ]),
        builder: (context, _) {
          final unreadUpdates = _unreadUpdatesBadgeCount();
          final extUpdates = SourceManager.isIOSPlatform
              ? 0
              : ExtensionService.instance.updatesAvailableExtensions
                  .where((e) => e.isCompatible)
                  .length;
          return DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.outline, width: 0.8)),
            ),
            child: NavigationBar(
              height: 74,
              selectedIndex: _index,
              onDestinationSelected: _onSelectTab,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: [
                for (var i = 0; i < _destinations.length; i++)
                  NavigationDestination(
                    icon: _badgedNavIcon(
                      _destinations[i].$1,
                      i == 1 ? unreadUpdates : (i == 3 ? extUpdates : 0),
                    ),
                    selectedIcon: _badgedNavIcon(
                      _destinations[i].$2,
                      i == 1 ? unreadUpdates : (i == 3 ? extUpdates : 0),
                    ),
                    label: _destinations[i].$3,
                  ),
              ],
            ),
          );
        },
      ),
    ),
    );
  }
}

class _AppLockScreen extends StatefulWidget {
  const _AppLockScreen();

  @override
  State<_AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<_AppLockScreen> {
  final _pinController = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    if (PrivacyService.instance.useBiometric) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tryBiometric();
      });
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _tryBiometric() async {
    final ok = await PrivacyService.instance.unlockWithBiometric();
    if (!ok && mounted) {
      setState(() => _error = 'Biometric unlock cancelled or unavailable.');
    }
  }

  Future<void> _submitPin() async {
    final ok = await PrivacyService.instance.verifyPin(_pinController.text);
    if (!ok && mounted) {
      setState(() => _error = 'Incorrect PIN. Please try again.');
      _pinController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final privacy = PrivacyService.instance;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_rounded, size: 52, color: AppColors.primary),
                  const SizedBox(height: 16),
                  Text('Shiori Locked', style: AppText.title),
                  const SizedBox(height: 8),
                  Text(
                    'Authenticate to access your library',
                    textAlign: TextAlign.center,
                    style: AppText.caption,
                  ),
                  const SizedBox(height: 24),
                  if (privacy.hasPin) ...[
                    TextField(
                      controller: _pinController,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      onSubmitted: (_) => _submitPin(),
                      decoration: InputDecoration(
                        hintText: 'Enter PIN',
                        filled: true,
                        fillColor: AppColors.surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: AppColors.outline),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _submitPin,
                        child: const Text('Unlock with PIN'),
                      ),
                    ),
                  ],
                  if (privacy.useBiometric) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _tryBiometric,
                        icon: const Icon(Icons.fingerprint_rounded),
                        label: const Text('Unlock with Biometrics'),
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: AppText.caption.copyWith(color: Colors.redAccent),
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
}
