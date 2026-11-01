import 'package:flutter/material.dart';

import 'screens/browse_screen.dart';
import 'screens/history_screen.dart';
import 'screens/library_screen.dart';
import 'screens/more_screen.dart';
import 'screens/updates_screen.dart';
import 'services/api_service.dart';
import 'services/download_service.dart';
import 'services/tracker_service.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeController.instance.init();
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

class _RootShellState extends State<RootShell> {
  int _index = 0;
  final Set<int> _loadedTabs = {0};

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

  Widget _buildTab(int index) {
    if (!_loadedTabs.contains(index)) {
      return const SizedBox.shrink();
    }
    return RepaintBoundary(
      child: switch (index) {
        0 => const LibraryScreen(),
        1 => const UpdatesScreen(),
        2 => const HistoryScreen(),
        3 => const BrowseScreen(),
        4 => const MoreScreen(),
        _ => const SizedBox.shrink(),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < _destinations.length; i++) _buildTab(i),
        ],
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
