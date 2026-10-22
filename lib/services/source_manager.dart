import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DirectSourceInfo {
  final String id;
  final String name;
  final String lang;
  final String badge;
  final String description;
  final String iconLetter;
  final int colorValue;

  const DirectSourceInfo({
    required this.id,
    required this.name,
    required this.lang,
    required this.badge,
    required this.description,
    required this.iconLetter,
    required this.colorValue,
  });
}

class SourceManager extends ChangeNotifier {
  static final SourceManager instance = SourceManager._();
  SourceManager._() {
    _loadPreferences();
  }

  static const String _pinnedKey = 'shiori_pinned_sources_v1';
  static const String _disabledDirectKey = 'shiori_disabled_direct_sources_v1';

  /// Built-in direct sources are only offered on iOS (where Tachiyomi APK
  /// extensions cannot run). Android uses community extensions instead.
  static List<DirectSourceInfo> get directSources =>
      (!kIsWeb && Platform.isIOS) ? allDirectSources : const [];

  static const List<DirectSourceInfo> allDirectSources = [
    DirectSourceInfo(
      id: 'mangadex',
      name: 'MangaDex',
      lang: 'ALL',
      badge: 'API • Multi',
      description: 'Official API • 100,000+ Manga, Manhwa & Manhua in 40+ languages',
      iconLetter: 'M',
      colorValue: 0xFFFF6740,
    ),
    DirectSourceInfo(
      id: 'asura',
      name: 'Asura Scans',
      lang: 'EN',
      badge: 'DIRECT • EN',
      description: 'Top Action Manhwa • Solo Leveling, Mount Hua, Disaster-Class Hero',
      iconLetter: 'A',
      colorValue: 0xFF6366F1,
    ),
    DirectSourceInfo(
      id: 'flamecomics',
      name: 'Flame Comics',
      lang: 'EN',
      badge: 'DIRECT • EN',
      description: 'Action & Fantasy Webtoons • Omniscient Reader, Murim RPG',
      iconLetter: 'F',
      colorValue: 0xFFEF4444,
    ),
    DirectSourceInfo(
      id: 'weebcentral',
      name: 'Weeb Central',
      lang: 'EN',
      badge: 'DIRECT • EN',
      description: 'Huge Manga & Webtoon Archive • Fast high-resolution chapters',
      iconLetter: 'W',
      colorValue: 0xFF10B981,
    ),
    DirectSourceInfo(
      id: 'mangapill',
      name: 'MangaPill',
      lang: 'EN',
      badge: 'DIRECT • EN',
      description: 'Comprehensive Manga Archive • High-speed chapters & zero ads',
      iconLetter: 'P',
      colorValue: 0xFFF59E0B,
    ),
    DirectSourceInfo(
      id: 'mangakatana',
      name: 'MangaKatana',
      lang: 'EN',
      badge: 'DIRECT • EN',
      description: 'Massive Manga Archive • Fast high-res chapters & thousands of series',
      iconLetter: 'K',
      colorValue: 0xFF06B6D4,
    ),
    DirectSourceInfo(
      id: 'mangaread',
      name: 'MangaRead',
      lang: 'EN',
      badge: 'DIRECT • EN',
      description: 'Webtoons & Manhwa • Solo Leveling Ragnarok, daily high-res updates',
      iconLetter: 'R',
      colorValue: 0xFF8B5CF6,
    ),
  ];

  final Set<String> _pinnedSourceIds = {'mangadex', 'asura'};
  Set<String> get pinnedSourceIds => _pinnedSourceIds;

  final Set<String> _disabledSourceIds = {};
  Set<String> get disabledSourceIds => _disabledSourceIds;

  bool isPinned(String sourceId) => _pinnedSourceIds.contains(sourceId);
  bool isEnabled(String sourceId) => !_disabledSourceIds.contains(sourceId);

  DirectSourceInfo? getDirectSource(String sourceId) {
    try {
      return allDirectSources.firstWhere((s) => s.id == sourceId);
    } catch (_) {
      return null;
    }
  }

  Future<void> togglePin(String sourceId) async {
    if (_pinnedSourceIds.contains(sourceId)) {
      _pinnedSourceIds.remove(sourceId);
    } else {
      _pinnedSourceIds.add(sourceId);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_pinnedKey, _pinnedSourceIds.toList());
    } catch (_) {}
  }

  Future<void> toggleEnabled(String sourceId) async {
    if (_disabledSourceIds.contains(sourceId)) {
      _disabledSourceIds.remove(sourceId);
    } else {
      _disabledSourceIds.add(sourceId);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_disabledDirectKey, _disabledSourceIds.toList());
    } catch (_) {}
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pinned = prefs.getStringList(_pinnedKey);
      if (pinned != null) {
        _pinnedSourceIds
          ..clear()
          ..addAll(pinned);
      }
      final disabled = prefs.getStringList(_disabledDirectKey);
      if (disabled != null) {
        _disabledSourceIds
          ..clear()
          ..addAll(disabled);
      }
      notifyListeners();
    } catch (_) {}
  }
}
