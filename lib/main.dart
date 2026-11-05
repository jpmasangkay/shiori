import 'dart:async';
import 'package:flutter/material.dart';

import 'display_settings.dart';
import 'screens/browse_screen.dart';
import 'screens/history_screen.dart';
import 'screens/library_screen.dart';
import 'screens/more_screen.dart';
import 'screens/updates_screen.dart';
import 'services/api_service.dart';
import 'services/connectivity_service.dart';
import 'services/download_service.dart';
import 'services/reader_settings.dart';
import 'services/tracker_service.dart';
import 'theme.dart';
import 'widgets/auth_modal.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Performance tuning for low-end phones: constrain decoded image cache to prevent OOM
  PaintingBinding.instance.imageCache.maximumSize = 250;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 64 * 1024 * 1024; // 64 MB
  await ThemeController.instance.init();
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
    return MaterialApp(
      title: 'Shiori',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const RootShell(),
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
  Timer? _autoRefreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Continuous background automatic refresh (every 60 seconds)
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      ApiService.instance.autoRefreshEverything();
    });
    // Automatic refresh on initial launch
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ApiService.instance.autoRefreshEverything();
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When returning to app from background / another app, automatically refresh everything!
    if (state == AppLifecycleState.resumed) {
      ApiService.instance.autoRefreshEverything();
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
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
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
                            'Offline mode — reading downloaded content',
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
          ],
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.outline, width: 0.8)),
        ),
        child: NavigationBar(
          height: 74,
          selectedIndex: _index,
          onDestinationSelected: _onSelectTab,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            for (final (icon, selected, label) in _destinations)
              NavigationDestination(
                icon: Icon(icon, size: 26),
                selectedIcon: Icon(selected, size: 26),
                label: label,
              ),
          ],
        ),
      ),
    );
  }
}
