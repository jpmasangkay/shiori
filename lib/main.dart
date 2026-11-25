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

class ShioriApp extends StatefulWidget {
  const ShioriApp({super.key});

  @override
  State<ShioriApp> createState() => _ShioriAppState();
}

class _ShioriAppState extends State<ShioriApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ThemeController.instance.updatePlatformBrightness(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    ThemeController.instance.updatePlatformBrightness(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
  }

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
        0 => LibraryScreen(
            isActive: active,
            onBrowseSources: () => _onSelectTab(3),
          ),
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
      listenable: Listenable.merge([
        PrivacyService.instance,
        ThemeController.instance,
      ]),
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
    final useRail = MediaQuery.sizeOf(context).width >= 720;

    final mainColumn = Column(
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
    );

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
          child: useRail
              ? Row(
                  children: [
                    ListenableBuilder(
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
                        return NavigationRail(
                          selectedIndex: _index,
                          onDestinationSelected: _onSelectTab,
                          backgroundColor: AppColors.surface,
                          indicatorColor: AppColors.active,
                          labelType: NavigationRailLabelType.all,
                          selectedIconTheme: IconThemeData(color: AppColors.primary),
                          unselectedIconTheme: IconThemeData(color: AppColors.muted),
                          selectedLabelTextStyle: AppText.badge.copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                          unselectedLabelTextStyle: AppText.badge.copyWith(
                            color: AppColors.muted,
                          ),
                          destinations: [
                            for (var i = 0; i < _destinations.length; i++)
                              NavigationRailDestination(
                                icon: _badgedNavIcon(
                                  _destinations[i].$1,
                                  i == 1 ? unreadUpdates : (i == 3 ? extUpdates : 0),
                                ),
                                selectedIcon: _badgedNavIcon(
                                  _destinations[i].$2,
                                  i == 1 ? unreadUpdates : (i == 3 ? extUpdates : 0),
                                ),
                                label: Text(_destinations[i].$3),
                              ),
                          ],
                        );
                      },
                    ),
                    VerticalDivider(width: 1, thickness: 0.8, color: AppColors.outline),
                    Expanded(child: mainColumn),
                  ],
                )
              : mainColumn,
        ),
        bottomNavigationBar: useRail
            ? null
            : ListenableBuilder(
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
  String _pin = '';
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

  Future<void> _tryBiometric() async {
    final ok = await PrivacyService.instance.unlockWithBiometric();
    if (!ok && mounted) {
      setState(() => _error = 'Biometric unlock cancelled or unavailable.');
    }
  }

  Future<void> _onDigit(String digit) async {
    if (_pin.length >= 8) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += digit;
      _error = null;
    });
    if (_pin.length >= 4) {
      // Auto-unlock as soon as the entered PIN matches (supports 4–8 digit PINs seamlessly)
      final ok = await PrivacyService.instance.verifyPin(_pin);
      if (ok || !mounted) return;
      if (_pin.length >= 8) {
        HapticFeedback.heavyImpact();
        setState(() {
          _error = 'Incorrect PIN. Please try again.';
          _pin = '';
        });
      }
    }
  }

  void _onBackspace() {
    if (_pin.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = null;
    });
  }

  Future<void> _submitPin() async {
    if (_pin.length < 4) {
      setState(() => _error = 'Enter at least 4 digits.');
      return;
    }
    final ok = await PrivacyService.instance.verifyPin(_pin);
    if (!ok && mounted) {
      HapticFeedback.heavyImpact();
      setState(() {
        _error = 'Incorrect PIN. Please try again.';
        _pin = '';
      });
    }
  }

  Widget _buildKey(String label, {VoidCallback? onTap, IconData? icon}) {
    return SizedBox(
      width: 68,
      height: 54,
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.outline),
            ),
            alignment: Alignment.center,
            child: icon != null
                ? Icon(icon, size: 22, color: AppColors.text)
                : Text(
                    label,
                    style: AppText.title.copyWith(fontSize: 20),
                  ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final privacy = PrivacyService.instance;
    final dotCount = _pin.length > 4 ? _pin.length : 4;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_rounded, size: 46, color: AppColors.primary),
                  const SizedBox(height: 12),
                  Text('Shiori Locked', style: AppText.title),
                  const SizedBox(height: 6),
                  Text(
                    'Authenticate to access your library',
                    textAlign: TextAlign.center,
                    style: AppText.caption,
                  ),
                  const SizedBox(height: 22),
                  if (privacy.hasPin) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < dotCount; i++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i < _pin.length
                                  ? AppColors.primary
                                  : Colors.transparent,
                              border: Border.all(
                                color: i < _pin.length
                                    ? AppColors.primary
                                    : AppColors.muted,
                                width: 1.8,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    for (final row in const [
                      ['1', '2', '3'],
                      ['4', '5', '6'],
                      ['7', '8', '9'],
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            for (final d in row)
                              _buildKey(d, onTap: () => _onDigit(d)),
                          ],
                        ),
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildKey(
                          'Clear',
                          icon: Icons.backspace_outlined,
                          onTap: _onBackspace,
                        ),
                        _buildKey('0', onTap: () => _onDigit('0')),
                        _buildKey(
                          'Unlock',
                          icon: Icons.check_rounded,
                          onTap: _submitPin,
                        ),
                      ],
                    ),
                  ],
                  if (privacy.useBiometric) ...[
                    const SizedBox(height: 16),
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
