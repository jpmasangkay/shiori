import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'extension_bridge.dart';
import 'source_manager.dart';
import 'source_resolver.dart';

class ExtensionSource {
  final String id;
  final String name;
  final String lang;
  final String baseUrl;
  final bool supportsLatest;

  const ExtensionSource({
    required this.id,
    required this.name,
    required this.lang,
    required this.baseUrl,
    this.supportsLatest = true,
  });

  Map<String, String> toSubSourceMap() => {
    'id': id,
    'name': name,
    'lang': lang.toUpperCase(),
    'baseUrl': baseUrl,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'lang': lang,
    'baseUrl': baseUrl,
    'supportsLatest': supportsLatest,
  };

  factory ExtensionSource.fromJson(Map<dynamic, dynamic> json) {
    return ExtensionSource(
      id: (json['id'] ?? '').toString().trim(),
      name: (json['name'] ?? '').toString().trim(),
      lang: (json['lang'] ?? json['language'] ?? 'ALL').toString().trim(),
      baseUrl: (json['baseUrl'] ?? json['homeUrl'] ?? '').toString().trim(),
      supportsLatest: json['supportsLatest'] as bool? ?? true,
    );
  }
}

class ExtensionRepoMeta {
  final String name;
  final String shortName;
  final String signingKeyFingerprint;
  final String website;
  final String discord;
  final List<MangaExtension> extensions;

  const ExtensionRepoMeta({
    this.name = '',
    this.shortName = '',
    this.signingKeyFingerprint = '',
    this.website = '',
    this.discord = '',
    this.extensions = const [],
  });
}

class MangaExtension {
  static const double libVersionMin = 1.4;
  static const double libVersionMax = 1.6;

  final String id;
  final String name;
  final String pkg;
  String version;
  int versionCode;
  String libVersion;
  String apkUrl;
  String iconUrl;
  String jarUrl;
  final String lang;
  final bool isNsfw;
  final int contentRating; // 1=safe, 2=suggestive, 3=nsfw
  final List<String> sourceNames;
  final List<String> supportedLangs;
  final List<Map<String, String>> subSources;
  final List<ExtensionSource> sources;
  String homeUrl;
  Uint8List? iconBytes;
  bool isInstalled;
  bool hasUpdate;
  String? repoVersion;
  int? repoVersionCode;

  MangaExtension({
    required this.id,
    required this.name,
    required this.pkg,
    required this.version,
    required this.versionCode,
    required this.apkUrl,
    required this.iconUrl,
    required this.lang,
    required this.isNsfw,
    required this.sourceNames,
    this.libVersion = '1.6',
    this.jarUrl = '',
    this.contentRating = 1,
    this.supportedLangs = const [],
    this.subSources = const [],
    this.sources = const [],
    this.homeUrl = '',
    this.iconBytes,
    this.isInstalled = false,
    this.hasUpdate = false,
    this.repoVersion,
    this.repoVersionCode,
  });

  /// Returns true if [libVersion] is within the supported 1.4–1.6 range.
  bool get isCompatible {
    final trimmed = libVersion.trim();
    if (trimmed.isEmpty) return true;
    final parts = trimmed.split('.');
    final normalized = parts.length >= 2 ? '${parts[0]}.${parts[1]}' : trimmed;
    final parsed = double.tryParse(normalized);
    if (parsed == null) return true;
    return parsed >= libVersionMin && parsed <= libVersionMax;
  }

  /// Derives extension language from package name (`eu.kanade.tachiyomi.extension.<lang>.<name>`),
  /// mapping `"all"` to `"ALL"` (multi-language).
  static String deriveLangFromPkg(String pkg) {
    final base = pkg.split('@').first.trim();
    if (base.contains('.extension.')) {
      final after = base.split('.extension.').last;
      final langPart = after.split('.').first.trim();
      if (langPart.isNotEmpty) {
        return langPart.toUpperCase();
      }
    }
    final parts = base.split('.');
    if (parts.length >= 5 && parts[3] == 'extension' && parts[4].isNotEmpty) {
      return parts[4].toUpperCase();
    }
    if (parts.length >= 4 && parts[3].isNotEmpty && parts[3] != 'extension') {
      return parts[3].toUpperCase();
    }
    return 'ALL';
  }

  /// Always filter out the two Keiyoushi/Mihon deprecation stub packages.
  static bool isStubPackage(String pkg, [String name = '']) {
    final lowerPkg = pkg.split('@').first.trim().toLowerCase();
    if (lowerPkg == 'eu.kanade.tachiyomi.extension.all.keiyoushi' ||
        lowerPkg == 'eu.kanade.tachiyomi.extension.all.mihon' ||
        lowerPkg.endsWith('.extension.all.keiyoushi') ||
        lowerPkg.endsWith('.extension.all.mihon')) {
      return true;
    }
    final lowerName = name.trim().toLowerCase();
    if (lowerName == 'outdated app' || lowerName.startsWith('update to mihon')) {
      return true;
    }
    return false;
  }

  /// Returns true if this extension serves content in [filterLang] (e.g. 'EN', 'ALL').
  bool supportsLang(String filterLang) {
    final target = filterLang.toUpperCase().trim();
    if (target.isEmpty || target == 'ALL') return true;
    final primary = lang.toUpperCase().trim();
    if (primary == target || primary == 'ALL') return true;
    if (primary.startsWith('$target-') || primary.startsWith('${target}_')) {
      return true;
    }
    for (final l in supportedLangs) {
      final lu = l.toUpperCase().trim();
      if (lu == target ||
          lu == 'ALL' ||
          lu.startsWith('$target-') ||
          lu.startsWith('${target}_')) {
        return true;
      }
    }
    for (final s in sources) {
      final su = s.lang.toUpperCase().trim();
      if (su == target ||
          su == 'ALL' ||
          su.startsWith('$target-') ||
          su.startsWith('${target}_')) {
        return true;
      }
    }
    return false;
  }

  MangaExtension copyWith({
    String? id,
    String? name,
    String? pkg,
    String? version,
    int? versionCode,
    String? libVersion,
    String? apkUrl,
    String? iconUrl,
    String? jarUrl,
    String? lang,
    bool? isNsfw,
    int? contentRating,
    List<String>? sourceNames,
    List<String>? supportedLangs,
    List<Map<String, String>>? subSources,
    List<ExtensionSource>? sources,
    String? homeUrl,
    Uint8List? iconBytes,
    bool? isInstalled,
    bool? hasUpdate,
    String? repoVersion,
    int? repoVersionCode,
    bool clearRepoUpdate = false,
  }) {
    return MangaExtension(
      id: id ?? this.id,
      name: name ?? this.name,
      pkg: pkg ?? this.pkg,
      version: version ?? this.version,
      versionCode: versionCode ?? this.versionCode,
      libVersion: libVersion ?? this.libVersion,
      apkUrl: apkUrl ?? this.apkUrl,
      iconUrl: iconUrl ?? this.iconUrl,
      jarUrl: jarUrl ?? this.jarUrl,
      lang: lang ?? this.lang,
      isNsfw: isNsfw ?? this.isNsfw,
      contentRating: contentRating ?? this.contentRating,
      sourceNames: sourceNames ?? List<String>.from(this.sourceNames),
      supportedLangs: supportedLangs ?? List<String>.from(this.supportedLangs),
      subSources: subSources ?? List<Map<String, String>>.from(this.subSources),
      sources: sources ?? List<ExtensionSource>.from(this.sources),
      homeUrl: homeUrl ?? this.homeUrl,
      iconBytes: iconBytes ?? this.iconBytes,
      isInstalled: isInstalled ?? this.isInstalled,
      hasUpdate: hasUpdate ?? this.hasUpdate,
      repoVersion: clearRepoUpdate ? null : (repoVersion ?? this.repoVersion),
      repoVersionCode: clearRepoUpdate
          ? null
          : (repoVersionCode ?? this.repoVersionCode),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'pkg': pkg,
    'version': version,
    'versionCode': versionCode,
    'libVersion': libVersion,
    'apkUrl': apkUrl,
    'iconUrl': iconUrl,
    if (jarUrl.isNotEmpty) 'jarUrl': jarUrl,
    'lang': lang,
    'isNsfw': isNsfw,
    'contentRating': contentRating,
    'sourceNames': sourceNames,
    if (supportedLangs.isNotEmpty) 'supportedLangs': supportedLangs,
    if (subSources.isNotEmpty) 'subSources': subSources,
    if (sources.isNotEmpty) 'sources': sources.map((s) => s.toJson()).toList(),
    'homeUrl': homeUrl,
    'isInstalled': isInstalled,
    'hasUpdate': hasUpdate,
    if (repoVersion != null) 'repoVersion': repoVersion,
    if (repoVersionCode != null) 'repoVersionCode': repoVersionCode,
  };

  factory MangaExtension.fromJson(Map<String, dynamic> json) {
    final parsedSources =
        (json['sources'] as List<dynamic>?)
            ?.whereType<Map>()
            .map((m) => ExtensionSource.fromJson(m))
            .toList() ??
        <ExtensionSource>[];
    final parsedSubSources =
        (json['subSources'] as List<dynamic>?)
            ?.whereType<Map>()
            .map(
              (m) =>
                  m.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')),
            )
            .toList() ??
        (parsedSources.length > 1
            ? parsedSources.map((s) => s.toSubSourceMap()).toList()
            : <Map<String, String>>[]);
    final pkg = json['pkg'] as String? ?? json['id'] as String? ?? '';
    final version =
        json['version'] as String? ?? json['versionName'] as String? ?? '';
    final rawLib = json['libVersion'] as String? ?? '';
    final libVersion = rawLib.isNotEmpty
        ? rawLib
        : (version.contains('.')
              ? version.split('.').take(2).join('.')
              : '1.6');
    final rating =
        json['contentRating'] as int? ?? ((json['isNsfw'] == true) ? 3 : 1);
    return MangaExtension(
      id: json['id'] as String? ?? pkg,
      name: json['name'] as String? ?? '',
      pkg: pkg,
      version: version,
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      libVersion: libVersion,
      apkUrl: json['apkUrl'] as String? ?? '',
      iconUrl: json['iconUrl'] as String? ?? '',
      jarUrl: json['jarUrl'] as String? ?? '',
      lang: json['lang'] as String? ?? deriveLangFromPkg(pkg),
      isNsfw: json['isNsfw'] as bool? ?? (rating == 3),
      contentRating: rating,
      sourceNames:
          (json['sourceNames'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          parsedSources
              .map((s) => s.name)
              .where((s) => s.isNotEmpty)
              .toSet()
              .toList(),
      supportedLangs:
          (json['supportedLangs'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      subSources: parsedSubSources,
      sources: parsedSources,
      homeUrl: json['homeUrl'] as String? ?? '',
      isInstalled: json['isInstalled'] as bool? ?? false,
      hasUpdate: json['hasUpdate'] as bool? ?? false,
      repoVersion: json['repoVersion'] as String?,
      repoVersionCode: (json['repoVersionCode'] as num?)?.toInt(),
    );
  }

  /// Constructs a [MangaExtension] from the map returned by the Android
  /// `getInstalledExtensions` MethodChannel.
  factory MangaExtension.fromDeviceMap(Map<dynamic, dynamic> map) {
    final pkg = (map['pkg'] ?? map['packageName'] ?? '').toString().trim();
    final rawName = (map['name'] ?? '').toString().trim();
    final name = ExtensionService._cleanExtensionName(
      rawName,
    ).ifEmpty(pkg.split('.').last);
    final versionName = (map['versionName'] ?? map['version'] ?? '1.0')
        .toString()
        .trim();
    final versionCode =
        int.tryParse((map['versionCode'] ?? '0').toString()) ?? 0;
    final rawLib = (map['libVersion'] ?? '').toString().trim();
    final libVersion = rawLib.isNotEmpty
        ? rawLib
        : (versionName.contains('.')
              ? versionName.split('.').take(2).join('.')
              : '1.6');
    final derivedLang = deriveLangFromPkg(pkg);
    final rawLang = (map['lang'] ?? '').toString().trim().toUpperCase();
    final lang = derivedLang != 'ALL'
        ? derivedLang
        : (rawLang.isNotEmpty ? rawLang : 'ALL');
    final nsfwVal = map['nsfw'] ?? map['isNsfw'];
    final isNsfw = nsfwVal == true || nsfwVal == 1 || nsfwVal == '1';

    Uint8List? iconBytes;
    final rawIcon = map['iconBytes'];
    if (rawIcon is Uint8List) {
      iconBytes = rawIcon;
    } else if (rawIcon is List<int>) {
      iconBytes = Uint8List.fromList(rawIcon);
    }

    final rawSources = (map['sources'] as List<dynamic>?) ?? const [];
    final parsedSources = <ExtensionSource>[];
    final sourceNames = <String>[];
    final seenNames = <String>{};
    final langSet = <String>{lang};
    final subSources = <Map<String, String>>[];
    String enHomeUrl = '';
    String firstHomeUrl = '';

    for (final s in rawSources) {
      if (s is Map) {
        final src = ExtensionSource.fromJson(s);
        parsedSources.add(src);
        if (src.name.isNotEmpty && seenNames.add(src.name)) {
          sourceNames.add(src.name);
        }
        final sl = src.lang.toUpperCase();
        if (sl.isNotEmpty) langSet.add(sl);
        final firstBase = src.baseUrl
            .split(RegExp(r'[,;\s]+'))
            .firstWhere((u) => u.startsWith('http'), orElse: () => src.baseUrl);
        if (firstHomeUrl.isEmpty && firstBase.isNotEmpty) {
          firstHomeUrl = firstBase;
        }
        if (enHomeUrl.isEmpty &&
            (sl == 'EN' || sl == 'ALL') &&
            firstBase.isNotEmpty) {
          enHomeUrl = firstBase;
        }
        if (src.name.isNotEmpty || src.id.isNotEmpty) {
          subSources.add({
            'id': src.id,
            'name': src.name.isNotEmpty ? src.name : name,
            'lang': sl.isNotEmpty ? sl : lang,
            'baseUrl': firstBase,
          });
        }
      }
    }

    final homeUrl = enHomeUrl.isNotEmpty ? enHomeUrl : firstHomeUrl;
    final iconUrl =
        'https://raw.githubusercontent.com/keiyoushi/extensions/repo/icon/$pkg.png';

    return MangaExtension(
      id: pkg,
      name: name,
      pkg: pkg,
      version: versionName,
      versionCode: versionCode,
      libVersion: libVersion,
      apkUrl: '',
      iconUrl: iconUrl,
      lang: lang,
      isNsfw: isNsfw,
      contentRating: isNsfw ? 3 : 1,
      sourceNames: sourceNames.isNotEmpty ? sourceNames : [name],
      supportedLangs: langSet.toList(),
      subSources: subSources.length > 1 ? subSources : const [],
      sources: parsedSources,
      homeUrl: homeUrl,
      iconBytes: iconBytes,
      isInstalled: true,
    );
  }
}

extension _StringIfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class ExtensionService extends ChangeNotifier {
  static final ExtensionService instance = ExtensionService._();
  ExtensionService._() {
    _setupMethodCallListener();
    SourceResolver.extensionNameLookup = (pkg) => getExtensionByPkg(pkg)?.name;
    _init();
  }

  static const String defaultRepoUrl =
      'https://raw.githubusercontent.com/keiyoushi/extensions/repo/repo.json';
  static const String defaultIndexPbUrl =
      'https://github.com/keiyoushi/extensions/raw/repo/index.pb';
  static const String fallbackIndexPbUrl =
      'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb';

  static const String _repoUrlKey = 'shiori_extension_repo_url_v2';
  static const String _installedKey = 'shiori_installed_extensions';
  static const String _installedMetaKey = 'shiori_installed_extensions_meta_v2';
  static const String _cacheKey = 'shiori_extensions_cache_v3';

  static final RegExp _baseUrlSplitRe = RegExp(r'[,;\s]+');
  static final RegExp _cleanPkgRe = RegExp(r'[^a-zA-Z0-9_\.]');

  String _repoUrl = defaultRepoUrl;
  String get repoUrl => _repoUrl;

  ExtensionRepoMeta? _repoMeta;
  ExtensionRepoMeta? get repoMeta => _repoMeta;
  ExtensionRepoMeta? get repoMetadata => _repoMeta;

  List<MangaExtension> _extensions = [];
  List<MangaExtension> get extensions => _extensions;

  List<MangaExtension> _cachedInstalled = const [];
  List<MangaExtension> _cachedUpdates = const [];
  List<MangaExtension> _cachedUpToDate = const [];
  List<MangaExtension> _cachedAvailable = const [];

  final Set<String> _installedPackages = {};
  Set<String> get installedPackages => _installedPackages;

  /// Extensions discovered directly from the Android device via PackageManager.
  final Map<String, MangaExtension> _deviceExtensionsMap = {};
  Map<String, MangaExtension> get deviceExtensionsMap => _deviceExtensionsMap;

  /// Persisted/manual installed extension metadata (fallback & testing).
  final Map<String, MangaExtension> _installedExtensionsMap = {};
  Map<String, MangaExtension> get installedExtensionsMap =>
      _installedExtensionsMap;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  Future<void>? _activeFetchFuture;

  String? _error;
  String? get error => _error;

  String? _lastInstallError;
  String? get lastInstallError => _lastInstallError;

  final Map<String, ({String version, int versionCode, String libVersion, DateTime expiresAt})>
      _pendingOsSyncOverrides = {};

  static const MethodChannel _installerChannel = MethodChannel(
    'com.example.manga_reader/installer',
  );

  void _setupMethodCallListener() {
    try {
      _installerChannel.setMethodCallHandler((call) async {
        if (call.method == 'onPackagesChanged') {
          await refreshInstalledPackages();
        }
      });
    } catch (_) {}
  }

  static String _normalizeRepoUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return defaultRepoUrl;
    if (trimmed.contains('keiyoushi/extensions') &&
        (trimmed.endsWith('/index.json') ||
            trimmed.endsWith('/index.min.json'))) {
      return defaultRepoUrl;
    }
    return trimmed;
  }

  Future<void> _init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedRepoUrl = prefs.getString(_repoUrlKey);
      _repoUrl = _normalizeRepoUrl(savedRepoUrl ?? defaultRepoUrl);
      if (savedRepoUrl != null && savedRepoUrl != _repoUrl) {
        await prefs.setString(_repoUrlKey, _repoUrl);
      }

      final installedList = prefs.getStringList(_installedKey);
      if (installedList != null) {
        _installedPackages.clear();
        for (final pkg in installedList) {
          final p = pkg.toLowerCase().trim();
          if (p.isNotEmpty && !MangaExtension.isStubPackage(p)) {
            _installedPackages.add(p);
          }
        }
      }

      final metaJson = prefs.getString(_installedMetaKey);
      if (metaJson != null && metaJson.isNotEmpty) {
        try {
          final Map<String, dynamic> decoded = json.decode(metaJson);
          _installedExtensionsMap.clear();
          decoded.forEach((k, v) {
            if (v is Map<String, dynamic>) {
              final ext = MangaExtension.fromJson(v);
              if (!MangaExtension.isStubPackage(ext.pkg, ext.name)) {
                ext.isInstalled = true;
                _installedExtensionsMap[k.toLowerCase().trim()] = ext;
              }
            }
          });
        } catch (_) {}
      }

      // Load repo cache if present (filtering out any legacy stubs)
      final cachedJson = prefs.getString(_cacheKey);
      if (cachedJson != null && cachedJson.isNotEmpty) {
        try {
          _extensions = cachedJson.length > 4096
              ? await compute(_decodeCachedExtensionsIsolate, cachedJson)
              : _decodeCachedExtensionsIsolate(cachedJson);
          _mergeInstalledWithRepo();
          notifyListeners();
        } catch (_) {}
      }

      // Query system for installed packages on Android first so installed extensions
      // appear immediately even when offline or before repo fetch completes.
      await refreshInstalledPackages();

      // Fetch fresh data from repository
      fetchExtensions();
    } catch (e) {
      debugPrint('ExtensionService init error: $e');
    }
  }

  Future<void> refreshDeviceExtensions() => refreshInstalledPackages();

  Future<void> refreshInstalledPackages() async {
    if (!kIsWeb && (Platform.isAndroid || SourceManager.isAndroidPlatform)) {
      try {
        final List<dynamic>? installed = await _installerChannel.invokeMethod(
          'getInstalledExtensions',
        );
        if (installed != null) {
          final now = DateTime.now();
          _pendingOsSyncOverrides.removeWhere(
            (_, v) => !now.isBefore(v.expiresAt),
          );

          final nextDeviceMap = <String, MangaExtension>{};
          final nextInstalledSet = <String>{};
          var persistedChanged = false;

          for (final item in installed) {
            if (item is Map) {
              final ext = MangaExtension.fromDeviceMap(item);
              if (ext.pkg.isNotEmpty &&
                  !MangaExtension.isStubPackage(ext.pkg, ext.name)) {
                final key = ext.pkg.toLowerCase().trim();
                final pending = _pendingOsSyncOverrides[key];
                if (pending != null) {
                  if (ext.versionCode >= pending.versionCode) {
                    _pendingOsSyncOverrides.remove(key);
                  } else {
                    ext.version = pending.version;
                    ext.versionCode = pending.versionCode;
                    if (pending.libVersion.isNotEmpty) {
                      ext.libVersion = pending.libVersion;
                    }
                  }
                }
                final persisted = _installedExtensionsMap[key];
                if (persisted != null &&
                    (persisted.versionCode != ext.versionCode ||
                        persisted.version != ext.version)) {
                  _installedExtensionsMap[key] = ext.copyWith(
                    isInstalled: true,
                  );
                  persistedChanged = true;
                }
                nextDeviceMap[key] = ext;
                nextInstalledSet.add(key);
              }
            } else if (item != null) {
              final pkg = item.toString().toLowerCase().trim();
              if (pkg.isNotEmpty && !MangaExtension.isStubPackage(pkg)) {
                nextInstalledSet.add(pkg);
              }
            }
          }

          final staleKeys = _installedExtensionsMap.keys
              .where(
                (k) =>
                    !nextDeviceMap.containsKey(k) &&
                    !nextInstalledSet.contains(k) &&
                    !_pendingOsSyncOverrides.containsKey(k),
              )
              .toList();
          if (staleKeys.isNotEmpty) {
            for (final k in staleKeys) {
              _installedExtensionsMap.remove(k);
            }
            persistedChanged = true;
          }

          _deviceExtensionsMap
            ..clear()
            ..addAll(nextDeviceMap);
          _installedPackages
            ..clear()
            ..addAll(nextInstalledSet)
            ..addAll(_installedExtensionsMap.keys);

          if (persistedChanged) {
            await _persistInstalledState();
          } else {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setStringList(
              _installedKey,
              _installedPackages.toList(),
            );
          }
        }
      } catch (e) {
        debugPrint('Error getting installed extensions from device: $e');
      }
    }
    _mergeInstalledWithRepo();
    notifyListeners();
  }

  /// Test helper to reload persisted installed extension metadata from SharedPreferences.
  @visibleForTesting
  Future<void> reloadPersistedInstalledStateForTesting() async {
    _pendingOsSyncOverrides.clear();
    _installedPackages.clear();
    _installedExtensionsMap.clear();
    final prefs = await SharedPreferences.getInstance();
    final installedList = prefs.getStringList(_installedKey);
    if (installedList != null) {
      for (final pkg in installedList) {
        final p = pkg.toLowerCase().trim();
        if (p.isNotEmpty && !MangaExtension.isStubPackage(p)) {
          _installedPackages.add(p);
        }
      }
    }
    final metaJson = prefs.getString(_installedMetaKey);
    if (metaJson != null && metaJson.isNotEmpty) {
      final Map<String, dynamic> decoded = json.decode(metaJson);
      decoded.forEach((k, v) {
        if (v is Map<String, dynamic>) {
          final ext = MangaExtension.fromJson(v);
          if (!MangaExtension.isStubPackage(ext.pkg, ext.name)) {
            ext.isInstalled = true;
            _installedExtensionsMap[k.toLowerCase().trim()] = ext;
          }
        }
      });
    }
    _mergeInstalledWithRepo();
    notifyListeners();
  }

  /// Test helper to populate device-installed extensions directly in unit/widget tests.
  @visibleForTesting
  void setDeviceExtensionsForTesting(List<MangaExtension> deviceExtensions) {
    _deviceExtensionsMap.clear();
    _installedPackages.clear();
    _installedExtensionsMap.clear();
    _pendingOsSyncOverrides.clear();
    _installingPackages.clear();
    _lastInstallError = null;
    for (final ext in deviceExtensions) {
      if (MangaExtension.isStubPackage(ext.pkg, ext.name)) continue;
      final key = ext.pkg.toLowerCase().trim();
      ext.isInstalled = true;
      _deviceExtensionsMap[key] = ext;
      _installedPackages.add(key);
    }
    _mergeInstalledWithRepo();
    notifyListeners();
  }

  /// Test helper to populate repo extensions directly in unit/widget tests and run update merging.
  @visibleForTesting
  void setRepoExtensionsForTesting(
    List<MangaExtension> repoExtensions, {
    ExtensionRepoMeta? meta,
  }) {
    _repoMeta = meta;
    _extensions = repoExtensions
        .where((e) => !MangaExtension.isStubPackage(e.pkg, e.name))
        .toList();
    _mergeInstalledWithRepo();
    notifyListeners();
  }

  /// Merges device-installed extensions with repo extensions strictly for update detection
  /// (`repo.versionCode > installed.versionCode -> hasUpdate = true`).
  void _mergeInstalledWithRepo() {
    final repoByPkg = <String, MangaExtension>{};
    for (final repoExt in _extensions) {
      repoByPkg[repoExt.pkg.toLowerCase().trim()] = repoExt;
    }

    // Update device extensions with repo update info
    for (final entry in _deviceExtensionsMap.entries) {
      final key = entry.key;
      final installed = entry.value;
      installed.isInstalled = true;
      final repoExt = repoByPkg[key];
      if (repoExt != null) {
        if (repoExt.versionCode > installed.versionCode &&
            installed.versionCode > 0) {
          installed.hasUpdate = true;
          installed.repoVersion = repoExt.version;
          installed.repoVersionCode = repoExt.versionCode;
          installed.apkUrl = repoExt.apkUrl;
        } else {
          installed.hasUpdate = false;
          installed.repoVersion = null;
          installed.repoVersionCode = null;
          if (installed.apkUrl.isEmpty) {
            installed.apkUrl = repoExt.apkUrl;
          }
        }
        if (installed.iconUrl.isEmpty) {
          installed.iconUrl = repoExt.iconUrl;
        }
        if (installed.homeUrl.isEmpty && repoExt.homeUrl.isNotEmpty) {
          installed.homeUrl = repoExt.homeUrl;
        }
      } else {
        installed.hasUpdate = false;
        installed.repoVersion = null;
        installed.repoVersionCode = null;
      }
    }

    // Also update persisted/manual installed extensions
    for (final entry in _installedExtensionsMap.entries) {
      final key = entry.key;
      final installed = entry.value;
      installed.isInstalled = true;
      final repoExt = repoByPkg[key];
      if (repoExt != null) {
        if (repoExt.versionCode > installed.versionCode &&
            installed.versionCode > 0) {
          installed.hasUpdate = true;
          installed.repoVersion = repoExt.version;
          installed.repoVersionCode = repoExt.versionCode;
          installed.apkUrl = repoExt.apkUrl;
        } else {
          installed.hasUpdate = false;
          installed.repoVersion = null;
          installed.repoVersionCode = null;
          if (installed.apkUrl.isEmpty) {
            installed.apkUrl = repoExt.apkUrl;
          }
        }
      }
    }

    // Mark repo entries as installed/hasUpdate where matching
    for (final ext in _extensions) {
      final pkgLower = ext.pkg.toLowerCase().trim();
      final idLower = ext.id.toLowerCase().trim();
      final deviceExt =
          _deviceExtensionsMap[pkgLower] ?? _deviceExtensionsMap[idLower];
      final manualExt =
          _installedExtensionsMap[pkgLower] ?? _installedExtensionsMap[idLower];
      final installedObj = deviceExt ?? manualExt;

      final isInst =
          installedObj != null ||
          _installedPackages.contains(pkgLower) ||
          _installedPackages.contains(idLower);
      ext.isInstalled = isInst;
      if (installedObj != null) {
        ext.hasUpdate = installedObj.hasUpdate;
        ext.repoVersion = installedObj.repoVersion;
        ext.repoVersionCode = installedObj.repoVersionCode;
      } else {
        ext.hasUpdate = false;
      }
    }

    _rebuildCachedLists();
  }

  void _rebuildCachedLists() {
    final byPkg = <String, MangaExtension>{};

    // 1. Primary source: device-installed extensions
    for (final ext in _deviceExtensionsMap.values) {
      if (MangaExtension.isStubPackage(ext.pkg, ext.name)) continue;
      ext.isInstalled = true;
      byPkg[ext.pkg.toLowerCase().trim()] = ext;
    }

    // 2. Persisted/manual installed extensions
    for (final ext in _installedExtensionsMap.values) {
      if (MangaExtension.isStubPackage(ext.pkg, ext.name)) continue;
      final key = ext.pkg.toLowerCase().trim();
      if (!byPkg.containsKey(key)) {
        ext.isInstalled = true;
        byPkg[key] = ext;
      }
    }

    // 3. If _installedPackages has a package name from a legacy string-only mock
    for (final pkg in _installedPackages) {
      final key = pkg.toLowerCase().trim();
      if (!byPkg.containsKey(key) && !MangaExtension.isStubPackage(key)) {
        for (final repoExt in _extensions) {
          if (repoExt.pkg.toLowerCase().trim() == key ||
              repoExt.id.toLowerCase().trim() == key) {
            repoExt.isInstalled = true;
            byPkg[key] = repoExt;
            break;
          }
        }
      }
    }

    final installed = byPkg.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _cachedInstalled = List<MangaExtension>.unmodifiable(installed);
    _cachedUpdates = List<MangaExtension>.unmodifiable(
      installed.where((e) => e.hasUpdate),
    );
    _cachedUpToDate = List<MangaExtension>.unmodifiable(
      installed.where((e) => !e.hasUpdate),
    );
    final installedKeys = byPkg.keys.toSet();
    _cachedAvailable = List<MangaExtension>.unmodifiable(
      _extensions.where(
        (e) => !installedKeys.contains(e.pkg.toLowerCase().trim()),
      ),
    );
  }

  /// Installed extensions come from the device (and persisted in-app installs),
  /// NOT from the repo index. They always appear even when offline or when the repo fails.
  List<MangaExtension> get installedExtensions => _cachedInstalled;

  /// Installed extensions that have a newer `versionCode` in the repo.
  List<MangaExtension> get updatesAvailableExtensions => _cachedUpdates;

  /// Installed extensions that are up to date.
  List<MangaExtension> get upToDateInstalledExtensions => _cachedUpToDate;

  /// Extensions in the repository that are not currently installed.
  List<MangaExtension> get availableExtensions => _cachedAvailable;

  bool isPackageInstalled(String pkgOrId) {
    final lower = pkgOrId.split('@').first.toLowerCase().trim();
    if (lower.isEmpty) return false;
    if (_deviceExtensionsMap.containsKey(lower)) return true;
    if (_installedExtensionsMap.containsKey(lower)) return true;
    if (_installedPackages.contains(lower)) return true;
    return _deviceExtensionsMap.keys.any(
          (p) => p == lower || p.contains(lower) || lower.contains(p),
        ) ||
        _installedPackages.any((p) {
          final pl = p.toLowerCase().trim();
          return pl == lower || pl.contains(lower) || lower.contains(pl);
        });
  }

  Future<void> _persistInstalledState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_installedKey, _installedPackages.toList());
      final mapToSave = <String, dynamic>{};
      _installedExtensionsMap.forEach((k, v) {
        mapToSave[k] = v.toJson();
      });
      await prefs.setString(_installedMetaKey, json.encode(mapToSave));
    } catch (e) {
      debugPrint('Error persisting installed extensions: $e');
    }
  }

  Future<void> setRepoUrl(String newUrl) async {
    _repoUrl = _normalizeRepoUrl(newUrl);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_repoUrlKey, _repoUrl);
    await fetchExtensions(force: true);
  }

  static String _cleanExtensionName(String raw) {
    final trimmed = raw.trim();
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('tachiyomi: ')) {
      return trimmed.substring(11).trim();
    }
    if (lower.startsWith('tachiyomi:')) {
      return trimmed.substring(10).trim();
    }
    if (lower.startsWith('mihon: ')) {
      return trimmed.substring(7).trim();
    }
    if (lower.startsWith('mihon:')) {
      return trimmed.substring(6).trim();
    }
    return trimmed;
  }

  static String _resolveRepoAssetUrl(
    String asset,
    String folder,
    String repoUrl,
  ) {
    final trimmed = asset.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http')) return trimmed;
    final slashIdx = repoUrl.lastIndexOf('/');
    final baseRepo = slashIdx > 8
        ? repoUrl.substring(0, slashIdx)
        : 'https://raw.githubusercontent.com/keiyoushi/extensions/repo';
    return '$baseRepo/$folder/$trimmed';
  }

  @visibleForTesting
  static List<MangaExtension> parseJsonIndexForTesting(
    String jsonStr, {
    String repoUrl = defaultRepoUrl,
  }) => _parseJsonIndex(jsonStr, repoUrl: repoUrl);

  @visibleForTesting
  static ExtensionRepoMeta parseRepoProtobufForTesting(
    Uint8List rawBytes, {
    String repoUrl = defaultRepoUrl,
  }) => _parseRepoProtobuf(rawBytes, repoUrl: repoUrl);

  @visibleForTesting
  static List<MangaExtension> parseProtobufIndexForTesting(
    Uint8List rawBytes, {
    String repoUrl = defaultRepoUrl,
  }) => _parseProtobuf(rawBytes, repoUrl: repoUrl);

  static List<MangaExtension> _parseJsonIndex(
    String jsonStr, {
    String repoUrl = defaultRepoUrl,
  }) {
    try {
      final decoded = json.decode(jsonStr);
      final list = <MangaExtension>[];
      List<dynamic> items = [];

      if (decoded is Map<String, dynamic>) {
        final extListRaw = decoded['extensionList'];
        if (extListRaw is Map<String, dynamic>) {
          if (extListRaw['extensions'] is List) {
            items = extListRaw['extensions'] as List<dynamic>;
          } else {
            for (final v in extListRaw.values) {
              if (v is List) items.addAll(v);
            }
          }
        } else if (extListRaw is List) {
          items = extListRaw;
        } else if (decoded['extensions'] is List) {
          items = decoded['extensions'] as List<dynamic>;
        }
      } else if (decoded is List) {
        items = decoded;
      }

      for (final item in items) {
        if (item is Map<String, dynamic>) {
          final pkg =
              (item['packageName'] ?? item['pkg'] ?? item['package'] ?? '')
                  .toString()
                  .trim();
          final rawName = (item['name'] ?? '').toString().trim();
          final name = _cleanExtensionName(rawName);
          if (pkg.isEmpty || name.isEmpty) continue;
          if (MangaExtension.isStubPackage(pkg, name)) continue;

          final res = item['resources'] as Map<String, dynamic>? ?? {};
          var apkUrl = res['apkUrl']?.toString() ?? '';
          if (apkUrl.isEmpty && item['apk'] != null) {
            apkUrl = _resolveRepoAssetUrl(
              item['apk'].toString(),
              'apk',
              repoUrl,
            );
          }

          var iconUrl = res['iconUrl']?.toString() ?? '';
          if (iconUrl.isEmpty) {
            if (item['icon'] != null) {
              iconUrl = _resolveRepoAssetUrl(
                item['icon'].toString(),
                'icon',
                repoUrl,
              );
            } else {
              iconUrl = _resolveRepoAssetUrl('$pkg.png', 'icon', repoUrl);
            }
          }

          final rawSources = (item['sources'] as List<dynamic>?) ?? [];
          final sources = <String>[];
          final parsedSources = <ExtensionSource>[];
          final seenSourceNames = <String>{};
          final langSet = <String>{};
          final subSources = <Map<String, String>>[];
          String enHomeUrl = '';
          String firstHomeUrl = '';

          for (final rawSrc in rawSources) {
            if (rawSrc is! Map) continue;
            final srcMap = rawSrc;
            final sName = (srcMap['name'] ?? '').toString().trim();
            final sId = (srcMap['id'] ?? '').toString().trim();
            final sLang = (srcMap['language'] ?? srcMap['lang'] ?? '')
                .toString()
                .trim()
                .toUpperCase();
            final sBase = (srcMap['baseUrl'] ?? srcMap['homeUrl'] ?? '')
                .toString()
                .trim();
            final firstBase = sBase
                .split(_baseUrlSplitRe)
                .firstWhere((u) => u.startsWith('http'), orElse: () => sBase);

            if (sName.isNotEmpty && seenSourceNames.add(sName)) {
              sources.add(sName);
            }
            if (sLang.isNotEmpty) {
              langSet.add(sLang);
            }
            if (firstHomeUrl.isEmpty && firstBase.isNotEmpty) {
              firstHomeUrl = firstBase;
            }
            if (enHomeUrl.isEmpty &&
                (sLang == 'EN' || sLang == 'ALL') &&
                firstBase.isNotEmpty) {
              enHomeUrl = firstBase;
            }
            if (sName.isNotEmpty || sId.isNotEmpty) {
              final resolvedLang = sLang.isNotEmpty ? sLang : 'ALL';
              subSources.add({
                'id': sId,
                'name': sName.isNotEmpty ? sName : name,
                'lang': resolvedLang,
                'baseUrl': firstBase,
              });
              parsedSources.add(
                ExtensionSource(
                  id: sId,
                  name: sName.isNotEmpty ? sName : name,
                  lang: resolvedLang,
                  baseUrl: firstBase,
                ),
              );
            }
          }

          final homeUrl = enHomeUrl.isNotEmpty
              ? enHomeUrl
              : (firstHomeUrl.isNotEmpty
                    ? firstHomeUrl
                    : (item['baseUrl']?.toString() ??
                          item['homeUrl']?.toString() ??
                          ''));

          final version = (item['versionName'] ?? item['version'] ?? '')
              .toString();
          final versionCode =
              int.tryParse(item['versionCode']?.toString() ?? '') ??
              int.tryParse(item['code']?.toString() ?? '') ??
              0;
          final rawLib = (item['libVersion'] ?? '').toString().trim();
          final libVersion = rawLib.isNotEmpty
              ? rawLib
              : (version.contains('.')
                    ? version.split('.').take(2).join('.')
                    : '1.6');

          final isNsfw =
              item['contentWarning'] == 'CONTENT_WARNING_NSFW' ||
              item['nsfw'] == 1 ||
              item['isNsfw'] == true;

          final derivedFromPkg = MangaExtension.deriveLangFromPkg(pkg);
          final itemLang = (item['lang'] ?? '').toString().trim().toUpperCase();
          if (itemLang.isNotEmpty) {
            langSet.add(itemLang);
          }
          String lang = derivedFromPkg;
          if (itemLang == 'ALL' ||
              derivedFromPkg == 'ALL' ||
              langSet.where((l) => l != 'ALL').length > 1) {
            lang = 'ALL';
          } else if (itemLang.isNotEmpty) {
            lang = itemLang;
          } else if (derivedFromPkg.isNotEmpty) {
            lang = derivedFromPkg;
          } else if (langSet.isNotEmpty) {
            lang = langSet.first;
          }
          langSet.add(lang);

          list.add(
            MangaExtension(
              id: pkg,
              name: name,
              pkg: pkg,
              version: version,
              versionCode: versionCode,
              libVersion: libVersion,
              apkUrl: apkUrl,
              iconUrl: iconUrl,
              lang: lang,
              isNsfw: isNsfw,
              contentRating: isNsfw ? 3 : 1,
              sourceNames: sources,
              supportedLangs: langSet.toList(),
              subSources: subSources.length > 1 ? subSources : const [],
              sources: parsedSources,
              homeUrl: homeUrl,
            ),
          );
        }
      }
      return list;
    } catch (e) {
      debugPrint('Error parsing index.json: $e');
      return [];
    }
  }

  Future<void> fetchExtensions({bool force = false}) async {
    if (_activeFetchFuture != null) {
      await _activeFetchFuture;
      if (!force) return;
    }
    final fut = _performFetchExtensions();
    _activeFetchFuture = fut;
    try {
      await fut;
    } finally {
      if (identical(_activeFetchFuture, fut)) {
        _activeFetchFuture = null;
      }
    }
  }

  Future<void> _performFetchExtensions() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    const noCacheHeaders = <String, String>{
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
    };
    final client = http.Client();
    try {
      final targetUrl = _normalizeRepoUrl(_repoUrl);
      List<MangaExtension> parsed = [];

      if (targetUrl.endsWith('/repo.json') || targetUrl.endsWith('.pb')) {
        String indexV2Url = targetUrl.endsWith('.pb') ? targetUrl : '';

        if (indexV2Url.isEmpty) {
          try {
            final repoRes = await client
                .get(Uri.parse(targetUrl), headers: noCacheHeaders)
                .timeout(const Duration(seconds: 15));
            if (repoRes.statusCode == 200 && repoRes.bodyBytes.isNotEmpty) {
              final decoded = json.decode(
                utf8.decode(repoRes.bodyBytes, allowMalformed: true),
              );
              if (decoded is Map && decoded['index_v2'] != null) {
                indexV2Url = decoded['index_v2'].toString().trim();
              }
            }
          } catch (e) {
            debugPrint('repo.json fetch warning: $e');
          }
        }

        final pbCandidates = <String>{
          if (indexV2Url.isNotEmpty) indexV2Url,
          defaultIndexPbUrl,
          fallbackIndexPbUrl,
        }.toList();

        http.Response? pbRes;
        String usedPbUrl = defaultIndexPbUrl;
        for (final candidate in pbCandidates) {
          try {
            final attempt = await client
                .get(Uri.parse(candidate), headers: noCacheHeaders)
                .timeout(const Duration(seconds: 25));
            if (attempt.statusCode == 200 && attempt.bodyBytes.isNotEmpty) {
              pbRes = attempt;
              usedPbUrl = candidate;
              break;
            }
          } catch (_) {}
        }

        if (pbRes != null && pbRes.statusCode == 200) {
          final meta = pbRes.bodyBytes.length > 4096
              ? await compute(
                  _parseRepoProtobufIsolate,
                  (bytes: pbRes.bodyBytes, repoUrl: usedPbUrl),
                )
              : _parseRepoProtobuf(pbRes.bodyBytes, repoUrl: usedPbUrl);
          _repoMeta = meta;
          parsed = meta.extensions;
        } else {
          _error =
              'Failed to load extension index${pbRes != null ? ' (HTTP ${pbRes.statusCode})' : ''}';
        }
      } else {
        // Custom repository URL: support repo.json with index_v2, .pb, or legacy .json fallback
        final res = await client
            .get(Uri.parse(targetUrl), headers: noCacheHeaders)
            .timeout(const Duration(seconds: 20));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          if (targetUrl.contains('.json')) {
            final bodyStr = utf8.decode(res.bodyBytes, allowMalformed: true);
            Map<String, dynamic>? maybeRepoObj;
            if (bodyStr.length < 4096) {
              try {
                final d = json.decode(bodyStr);
                if (d is Map<String, dynamic> && d['index_v2'] != null) {
                  maybeRepoObj = d;
                }
              } catch (_) {}
            }

            if (maybeRepoObj != null) {
              final pbUrl = maybeRepoObj['index_v2'].toString().trim();
              final pbRes = await client
                  .get(Uri.parse(pbUrl), headers: noCacheHeaders)
                  .timeout(const Duration(seconds: 25));
              if (pbRes.statusCode == 200 && pbRes.bodyBytes.isNotEmpty) {
                final meta = pbRes.bodyBytes.length > 4096
                    ? await compute(
                        _parseRepoProtobufIsolate,
                        (bytes: pbRes.bodyBytes, repoUrl: pbUrl),
                      )
                    : _parseRepoProtobuf(pbRes.bodyBytes, repoUrl: pbUrl);
                _repoMeta = meta;
                parsed = meta.extensions;
              }
            } else {
              parsed = bodyStr.length > 4096
                  ? await compute(
                      _parseJsonIndexIsolate,
                      (jsonStr: bodyStr, repoUrl: targetUrl),
                    )
                  : _parseJsonIndex(bodyStr, repoUrl: targetUrl);
            }
          } else {
            final meta = res.bodyBytes.length > 4096
                ? await compute(
                    _parseRepoProtobufIsolate,
                    (bytes: res.bodyBytes, repoUrl: targetUrl),
                  )
                : _parseRepoProtobuf(res.bodyBytes, repoUrl: targetUrl);
            _repoMeta = meta;
            parsed = meta.extensions;
          }
        } else {
          _error = 'Failed to load extensions (HTTP ${res.statusCode})';
        }
      }

      if (parsed.isNotEmpty) {
        _extensions = parsed
            .where((e) => !MangaExtension.isStubPackage(e.pkg, e.name))
            .toList();
        _mergeInstalledWithRepo();

        final prioritized = [
          ..._extensions.where((e) => e.isInstalled),
          ..._extensions.where(
            (e) => !e.isInstalled && e.supportsLang('EN'),
          ),
          ..._extensions.where(
            (e) => !e.isInstalled && !e.supportsLang('EN'),
          ),
        ].take(900).toList();
        compute(_encodeExtensionsCacheIsolate, prioritized)
            .then((jsonStr) async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString(_cacheKey, jsonStr);
            })
            .catchError((_) {});
      }
    } catch (e) {
      _error = 'Failed to fetch repository: $e';
      debugPrint('Extension fetch error: $e');
    } finally {
      client.close();
      _isLoading = false;
      notifyListeners();
    }
  }

  bool get hasMangaDex => isPackageInstalled('mangadex');
  bool get hasAsura => isPackageInstalled('asura');

  Future<bool> isAppInstalled(String packageName) async {
    return isPackageInstalled(packageName);
  }

  Future<bool> launchApp(String packageName) async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _installerChannel.invokeMethod<bool>('launchPackage', {
        'packageName': packageName,
      });
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  MangaExtension? getExtensionByPkg(String pkgOrId) {
    final lower = pkgOrId.split('@').first.toLowerCase().trim();
    if (lower.isEmpty) return null;

    if (_deviceExtensionsMap.containsKey(lower)) {
      return _deviceExtensionsMap[lower];
    }
    if (_installedExtensionsMap.containsKey(lower)) {
      return _installedExtensionsMap[lower];
    }
    for (final ext in _extensions) {
      final p = ext.pkg.toLowerCase().trim();
      final id = ext.id.toLowerCase().trim();
      if (p == lower || id == lower) return ext;
    }
    for (final ext in _deviceExtensionsMap.values) {
      if (ext.name.toLowerCase().trim() == lower) return ext;
    }
    for (final ext in _extensions) {
      if (ext.name.toLowerCase().trim() == lower) return ext;
    }
    for (final entry in _deviceExtensionsMap.entries) {
      if (entry.key.contains(lower) || lower.contains(entry.key)) {
        return entry.value;
      }
    }
    for (final entry in _installedExtensionsMap.entries) {
      if (entry.key.contains(lower) || lower.contains(entry.key)) {
        return entry.value;
      }
    }
    for (final ext in _extensions) {
      final p = ext.pkg.toLowerCase().trim();
      final id = ext.id.toLowerCase().trim();
      if (p.contains(lower) || lower.contains(p) || id.contains(lower)) {
        return ext;
      }
    }
    return null;
  }

  Future<void> installExtension(MangaExtension ext) async {
    if (MangaExtension.isStubPackage(ext.pkg, ext.name)) return;
    final key = (ext.pkg.isNotEmpty ? ext.pkg : ext.id).toLowerCase().trim();
    _installedPackages.add(key);
    if (ext.pkg.isNotEmpty) {
      _installedPackages.add(ext.pkg.toLowerCase().trim());
    }
    if (ext.id.isNotEmpty) {
      _installedPackages.add(ext.id.toLowerCase().trim());
    }

    MangaExtension? repoMatch;
    for (final r in _extensions) {
      if (r.pkg.toLowerCase().trim() == key ||
          r.id.toLowerCase().trim() == key) {
        repoMatch = r;
        break;
      }
    }

    final targetVersion =
        (ext.repoVersion != null && ext.repoVersion!.isNotEmpty)
        ? ext.repoVersion!
        : (repoMatch != null && repoMatch.versionCode > ext.versionCode
              ? repoMatch.version
              : ext.version);
    final targetVersionCode =
        (ext.repoVersionCode != null && ext.repoVersionCode! > ext.versionCode)
        ? ext.repoVersionCode!
        : (repoMatch != null && repoMatch.versionCode > ext.versionCode
              ? repoMatch.versionCode
              : ext.versionCode);
    final targetLibVersion =
        (repoMatch != null && repoMatch.libVersion.isNotEmpty)
        ? repoMatch.libVersion
        : ext.libVersion;

    ext.version = targetVersion;
    ext.versionCode = targetVersionCode;
    ext.libVersion = targetLibVersion;
    ext.isInstalled = true;
    ext.hasUpdate = false;
    ext.repoVersion = null;
    ext.repoVersionCode = null;

    final installedCopy = ext.copyWith(
      version: targetVersion,
      versionCode: targetVersionCode,
      libVersion: targetLibVersion,
      isInstalled: true,
      hasUpdate: false,
      clearRepoUpdate: true,
    );
    _pendingOsSyncOverrides[key] = (
      version: targetVersion,
      versionCode: targetVersionCode,
      libVersion: targetLibVersion,
      expiresAt: DateTime.now().add(const Duration(seconds: 15)),
    );
    _installedExtensionsMap[key] = installedCopy;
    if (_deviceExtensionsMap.containsKey(key) ||
        !kIsWeb && (Platform.isAndroid || SourceManager.isAndroidPlatform)) {
      _deviceExtensionsMap[key] = installedCopy;
    }
    ExtensionBridge.instance.evictSourceCache(key);
    _mergeInstalledWithRepo();
    await _persistInstalledState();
    notifyListeners();
  }

  Future<void> installPackageByNameOrId(String pkgOrId) async {
    final lower = pkgOrId.toLowerCase().trim();
    if (MangaExtension.isStubPackage(lower)) return;
    _installedPackages.add(lower);
    final ext = getExtensionByPkg(lower);
    if (ext != null) {
      _installedExtensionsMap[lower] = ext;
      ext.isInstalled = true;
    }
    ExtensionBridge.instance.evictSourceCache(lower);
    _mergeInstalledWithRepo();
    await _persistInstalledState();
    notifyListeners();
  }

  Future<void> uninstallExtension(MangaExtension ext) async {
    final key = (ext.pkg.isNotEmpty ? ext.pkg : ext.id).toLowerCase().trim();
    final pkgLower = ext.pkg.toLowerCase().trim();
    final idLower = ext.id.toLowerCase().trim();

    _installedPackages.remove(key);
    _installedPackages.remove(pkgLower);
    _installedPackages.remove(idLower);
    _installedPackages.removeWhere(
      (p) =>
          p == key ||
          p == pkgLower ||
          p == idLower ||
          (pkgLower.isNotEmpty && p.contains(pkgLower)),
    );

    _deviceExtensionsMap.remove(key);
    _deviceExtensionsMap.remove(pkgLower);
    _deviceExtensionsMap.remove(idLower);

    _installedExtensionsMap.remove(key);
    _installedExtensionsMap.remove(pkgLower);
    _installedExtensionsMap.remove(idLower);
    _installedExtensionsMap.removeWhere(
      (k, _) =>
          k == key ||
          k == pkgLower ||
          k == idLower ||
          (pkgLower.isNotEmpty && k.contains(pkgLower)),
    );
    _pendingOsSyncOverrides.removeWhere(
      (k, _) =>
          k == key ||
          k == pkgLower ||
          k == idLower ||
          (pkgLower.isNotEmpty && k.contains(pkgLower)),
    );

    ext.isInstalled = false;
    ext.hasUpdate = false;

    if (ext.pkg.isNotEmpty) SourceManager.instance.unpin(ext.pkg);
    if (ext.id.isNotEmpty) SourceManager.instance.unpin(ext.id);

    if (!kIsWeb && Platform.isAndroid && ext.pkg.isNotEmpty) {
      try {
        await _installerChannel.invokeMethod('uninstallPackage', {
          'packageName': ext.pkg,
        });
      } catch (e) {
        debugPrint('Native uninstall error: $e');
      }
    }

    try {
      final cleanName = ext.pkg.replaceAll(_cleanPkgRe, '_');
      final f1 = File(
        '${Directory.systemTemp.path}/shiori_extensions/$cleanName.apk',
      );
      if (await f1.exists()) await f1.delete();
      final f2 = File(
        '${Directory.systemTemp.path}/shiori_extensions/${ext.pkg}.apk',
      );
      if (await f2.exists()) await f2.delete();
    } catch (_) {}

    ExtensionBridge.instance.evictSourceCache(key);
    _mergeInstalledWithRepo();
    await _persistInstalledState();
    notifyListeners();
  }

  Future<void> uninstallPackage(String pkgOrId) async {
    final lower = pkgOrId.toLowerCase().trim();
    _installedPackages.remove(pkgOrId);
    _installedPackages.remove(lower);
    _installedPackages.removeWhere((p) {
      final pl = p.toLowerCase().trim();
      return pl == lower || pl.contains(lower) || lower.contains(pl);
    });
    _deviceExtensionsMap.remove(lower);
    _installedExtensionsMap.remove(lower);
    _installedExtensionsMap.removeWhere(
      (k, _) => k == lower || k.contains(lower) || lower.contains(k),
    );
    _pendingOsSyncOverrides.removeWhere(
      (k, _) => k == lower || k.contains(lower) || lower.contains(k),
    );

    SourceManager.instance.unpin(pkgOrId);
    SourceManager.instance.unpin(lower);

    if (!kIsWeb && Platform.isAndroid && pkgOrId.isNotEmpty) {
      try {
        await _installerChannel.invokeMethod('uninstallPackage', {
          'packageName': pkgOrId,
        });
      } catch (e) {
        debugPrint('Native uninstall error: $e');
      }
    }

    try {
      final cleanName = pkgOrId.replaceAll(_cleanPkgRe, '_');
      final f1 = File(
        '${Directory.systemTemp.path}/shiori_extensions/$cleanName.apk',
      );
      if (await f1.exists()) await f1.delete();
      final f2 = File(
        '${Directory.systemTemp.path}/shiori_extensions/$pkgOrId.apk',
      );
      if (await f2.exists()) await f2.delete();
    } catch (_) {}

    ExtensionBridge.instance.evictSourceCache(lower);
    _mergeInstalledWithRepo();
    await _persistInstalledState();
    notifyListeners();
  }

  Future<void> uninstallAll() async {
    _installedPackages.clear();
    _deviceExtensionsMap.clear();
    _installedExtensionsMap.clear();
    _pendingOsSyncOverrides.clear();
    for (final e in _extensions) {
      e.isInstalled = false;
      e.hasUpdate = false;
    }
    _mergeInstalledWithRepo();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_installedKey);
    await prefs.remove(_installedMetaKey);
    notifyListeners();
  }

  final Map<String, double> _downloadProgress = {};
  Map<String, double> get downloadProgress => _downloadProgress;

  final Set<String> _downloadingPackages = {};
  Set<String> get downloadingPackages => _downloadingPackages;

  final Set<String> _installingPackages = {};
  Set<String> get installingPackages => _installingPackages;

  final Map<String, Future<String?>> _inFlightApkDownloads = {};

  /// Optional test hook to override HTTP client when testing on-demand APK downloads.
  @visibleForTesting
  http.Client Function()? httpClientFactory;

  bool isDownloading(String pkgOrId) {
    final lower = pkgOrId.split('@').first.toLowerCase().trim();
    return _downloadingPackages.contains(lower) ||
        _installingPackages.contains(lower);
  }

  double getProgress(String pkgOrId) {
    final lower = pkgOrId.split('@').first.toLowerCase().trim();
    return _downloadProgress[lower] ?? 0.0;
  }

  Future<bool> downloadApk(MangaExtension ext) async {
    return downloadAndInstallExtension(ext);
  }

  Future<bool> downloadAndInstallApk(MangaExtension ext) async {
    return downloadAndInstallExtension(ext);
  }

  Future<void> _deleteTempExtensionApks(String basePkg) async {
    if (basePkg.isEmpty) return;
    try {
      final dir = Directory('${Directory.systemTemp.path}/shiori_extensions');
      final cleanName = basePkg.replaceAll(_cleanPkgRe, '_');
      for (final f in [
        File('${dir.path}/$cleanName.apk'),
        File('${dir.path}/$basePkg.apk'),
        File('${dir.path}/$cleanName.apk.part'),
      ]) {
        if (await f.exists()) {
          await f.delete();
        }
      }
    } catch (_) {}
  }

  /// Ensures [ext]'s APK binary is downloaded locally (and optionally persisted
  /// into `filesDir/shiori_extensions` on Android for uninstalled private-storage fallback).
  Future<String?> ensureApkDownloaded(
    MangaExtension ext, {
    bool notify = true,
    bool forceDownload = false,
    bool persistToPrivateStorage = true,
  }) {
    final basePkg = ext.pkg.split('@').first.trim();
    final key = (basePkg.isNotEmpty ? basePkg : ext.id).toLowerCase().trim();
    final existing = _inFlightApkDownloads[key];
    if (existing != null) return existing;

    final fut = () async {
      final dir = Directory('${Directory.systemTemp.path}/shiori_extensions');
      final cleanName = basePkg.replaceAll(_cleanPkgRe, '_');
      final apkFile = File('${dir.path}/$cleanName.apk');
      final directFile = File('${dir.path}/$basePkg.apk');

      if (!forceDownload && !ext.hasUpdate) {
        for (final f in [directFile, apkFile]) {
          try {
            if (await f.exists() && await f.length() > 1024) {
              if (persistToPrivateStorage && !kIsWeb && Platform.isAndroid) {
                try {
                  final persisted = await _installerChannel
                      .invokeMethod<String>('persistExtensionApk', {
                        'packageName': basePkg,
                        'pkg': basePkg,
                        'filePath': f.path,
                        'sourcePath': f.path,
                      });
                  if (persisted != null && persisted.isNotEmpty) {
                    return persisted;
                  }
                } catch (_) {}
              }
              return f.path;
            }
          } catch (_) {}
        }
      }

      String url = ext.apkUrl.trim();
      if (url.isEmpty || forceDownload || ext.hasUpdate) {
        for (final r in _extensions) {
          if (r.pkg.toLowerCase().trim() == key && r.apkUrl.trim().isNotEmpty) {
            url = r.apkUrl.trim();
            break;
          }
        }
      }
      if (url.isEmpty) return null;

      final candidateUrls = <String>[url];
      if (url.contains('github.com/keiyoushi/extensions/raw/repo/')) {
        candidateUrls.add(
          url.replaceFirst(
            'github.com/keiyoushi/extensions/raw/repo/',
            'raw.githubusercontent.com/keiyoushi/extensions/repo/',
          ),
        );
      } else if (url.contains(
        'raw.githubusercontent.com/keiyoushi/extensions/repo/',
      )) {
        candidateUrls.add(
          url.replaceFirst(
            'raw.githubusercontent.com/keiyoushi/extensions/repo/',
            'github.com/keiyoushi/extensions/raw/repo/',
          ),
        );
      }

      _downloadingPackages.add(key);
      _downloadProgress[key] = 0.05;
      if (notify) notifyListeners();

      final client = httpClientFactory != null
          ? httpClientFactory!()
          : http.Client();
      try {
        http.StreamedResponse? response;
        for (final candidateUrl in candidateUrls) {
          try {
            final uri = Uri.parse(candidateUrl);
            final request = http.Request('GET', uri)
              ..headers['User-Agent'] =
                  'Mozilla/5.0 (Linux; Android 14; SM-S921W) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36'
              ..followRedirects = true;
            final res = await client
                .send(request)
                .timeout(const Duration(seconds: 30));
            if (res.statusCode == 200) {
              response = res;
              break;
            }
          } catch (_) {}
        }

        if (response == null || response.statusCode != 200) {
          debugPrint(
            'Failed to download APK for $basePkg: HTTP ${response?.statusCode}',
          );
          return null;
        }

        final totalBytes = response.contentLength ?? 0;
        var receivedBytes = 0;

        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }

        final tmpDownload = File('${dir.path}/$cleanName.apk.part');
        final sink = tmpDownload.openWrite();
        try {
          await for (final chunk in response.stream) {
            sink.add(chunk);
            receivedBytes += chunk.length;
            if (totalBytes > 0) {
              _downloadProgress[key] = (receivedBytes / totalBytes).clamp(
                0.05,
                0.98,
              );
              if (notify) notifyListeners();
            }
          }
          await sink.flush();
        } finally {
          await sink.close();
        }

        if (await tmpDownload.length() < 512) {
          try {
            await tmpDownload.delete();
          } catch (_) {}
          return null;
        }

        if (await apkFile.exists()) {
          await apkFile.delete();
        }
        await tmpDownload.rename(apkFile.path);

        if (cleanName != basePkg && basePkg.isNotEmpty) {
          try {
            if (await directFile.exists()) await directFile.delete();
            await apkFile.copy(directFile.path);
          } catch (_) {}
        }

        _downloadProgress[key] = 1.0;
        if (notify) notifyListeners();

        if (persistToPrivateStorage &&
            !kIsWeb &&
            Platform.isAndroid &&
            basePkg.isNotEmpty) {
          try {
            final persisted = await _installerChannel.invokeMethod<String>(
              'persistExtensionApk',
              {
                'packageName': basePkg,
                'pkg': basePkg,
                'filePath': apkFile.path,
                'sourcePath': apkFile.path,
              },
            );
            if (persisted != null && persisted.isNotEmpty) {
              return persisted;
            }
          } catch (_) {}
        }
        return apkFile.path;
      } catch (e) {
        debugPrint('ensureApkDownloaded error for $basePkg: $e');
        return null;
      } finally {
        client.close();
        _downloadingPackages.remove(key);
        _downloadProgress.remove(key);
        if (notify) notifyListeners();
      }
    }();

    _inFlightApkDownloads[key] = fut;
    fut.whenComplete(() => _inFlightApkDownloads.remove(key));
    return fut;
  }

  /// Downloads the extension APK and installs/updates it through Android's
  /// PackageInstaller (shared with Mihon), awaiting actual OS completion.
  Future<bool> downloadAndInstallExtension(MangaExtension ext) async {
    if (!kIsWeb && (Platform.isIOS || SourceManager.isIOSPlatform)) {
      _lastInstallError = 'Community APK extensions cannot be installed on iOS.';
      debugPrint('Community APK extensions cannot be installed on iOS');
      return false;
    }

    final basePkg = ext.pkg.split('@').first.trim();
    final key = (basePkg.isNotEmpty ? basePkg : ext.id).toLowerCase().trim();
    if (_installingPackages.contains(key)) {
      return false;
    }

    _lastInstallError = null;
    _installingPackages.add(key);
    notifyListeners();

    try {
      String effectiveApkUrl = ext.apkUrl.trim();
      if (effectiveApkUrl.isEmpty || ext.hasUpdate) {
        for (final r in _extensions) {
          if (r.pkg.toLowerCase().trim() == key && r.apkUrl.trim().isNotEmpty) {
            effectiveApkUrl = r.apkUrl.trim();
            break;
          }
        }
      }

      if (effectiveApkUrl.isEmpty && !kIsWeb && Platform.isAndroid) {
        await fetchExtensions(force: true);
        for (final r in _extensions) {
          if (r.pkg.toLowerCase().trim() == key && r.apkUrl.trim().isNotEmpty) {
            effectiveApkUrl = r.apkUrl.trim();
            break;
          }
        }
        if (effectiveApkUrl.isEmpty) {
          _lastInstallError =
              'Extension download URL not found. Pull to refresh repository.';
          return false;
        }
      }

      String? apkPath;
      if (effectiveApkUrl.isNotEmpty) {
        final downloadTarget = ext.apkUrl.trim() == effectiveApkUrl
            ? ext
            : ext.copyWith(apkUrl: effectiveApkUrl);
        apkPath = await ensureApkDownloaded(
          downloadTarget,
          forceDownload: ext.hasUpdate,
          persistToPrivateStorage: false,
        );
        if (apkPath == null || apkPath.isEmpty) {
          _lastInstallError =
              'Failed to download ${ext.name} APK. Check your connection and try again.';
          return false;
        }
      } else {
        _downloadingPackages.add(key);
        _downloadProgress[key] = 0.5;
        notifyListeners();
        await Future.delayed(const Duration(milliseconds: 150));
        _downloadingPackages.remove(key);
        _downloadProgress.remove(key);
      }

      final isAndroidTarget =
          !kIsWeb && (Platform.isAndroid || SourceManager.isAndroidPlatform);
      if (isAndroidTarget && apkPath != null && apkPath.isNotEmpty) {
        try {
          final fingerprint = _repoMeta?.signingKeyFingerprint ?? '';
          final installedOk = await _installerChannel.invokeMethod<bool>(
            'installApk',
            {
              'filePath': apkPath,
              if (fingerprint.isNotEmpty) 'expectedFingerprint': fingerprint,
            },
          );
          if (installedOk != true) {
            _lastInstallError =
                'Installation was cancelled or did not complete.';
            await _deleteTempExtensionApks(basePkg);
            return false;
          }
        } on PlatformException catch (e) {
          _lastInstallError =
              (e.message != null && e.message!.trim().isNotEmpty)
              ? e.message!.trim()
              : 'Failed to install ${ext.name} (${e.code}).';
          debugPrint(
            'PackageInstaller installApk failed (${e.code}): ${e.message}',
          );
          await _deleteTempExtensionApks(basePkg);
          return false;
        } catch (e) {
          _lastInstallError = 'Failed to install ${ext.name}: $e';
          debugPrint('PackageInstaller installApk error: $e');
          await _deleteTempExtensionApks(basePkg);
          return false;
        }
        if (!kIsWeb && Platform.isAndroid) {
          await _deleteTempExtensionApks(basePkg);
        }
      }

      if (effectiveApkUrl.isNotEmpty) {
        ext.apkUrl = effectiveApkUrl;
      }
      await installExtension(ext);
      if (isAndroidTarget) {
        await refreshInstalledPackages();
      }
      return true;
    } catch (e) {
      _lastInstallError ??= 'Error updating ${ext.name}: $e';
      debugPrint('downloadAndInstallExtension error: $e');
      return false;
    } finally {
      _installingPackages.remove(key);
      notifyListeners();
    }
  }

  /// Updates all extensions that currently have an update available.
  Future<int> updateAllExtensions() async {
    final outdated = List<MangaExtension>.from(updatesAvailableExtensions);
    var updated = 0;
    for (final ext in outdated) {
      final ok = await downloadAndInstallExtension(ext);
      if (ok) updated++;
    }
    return updated;
  }

  // ---------------------------------------------------------------------------
  // Hand-written Protobuf Varint Decoder for Keiyoushi index.pb (index_v2)
  // ---------------------------------------------------------------------------
  // Field map:
  // Repo: 1=name, 2=shortName, 3=signingKeyFingerprint,
  //       4=links{1=website, 2=discord}, 101=index{repeated 1=Extension}
  // Extension: 1=name, 2=pkg, 3=urls{1=apkUrl, 2=iconUrl, 501=jarUrl},
  //            4=libVersion ("1.6"), 5=versionCode, 6=versionName,
  //            7=contentRating (1=safe, 2=suggestive, 3=nsfw),
  //            8=repeated Source{1=id int64, 2=name, 3=lang, 4=baseUrl}

  static ({int value, int nextPos}) _readVarint(Uint8List data, int pos) {
    int value = 0;
    int shift = 0;
    while (pos < data.length) {
      final b = data[pos++];
      value |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
    }
    return (value: value, nextPos: pos);
  }

  static ({BigInt value, int nextPos}) _readVarintBig(Uint8List data, int pos) {
    BigInt value = BigInt.zero;
    int shift = 0;
    while (pos < data.length) {
      final b = data[pos++];
      value |= BigInt.from(b & 0x7f) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
    }
    return (value: value, nextPos: pos);
  }

  static List<MangaExtension> _decodeCachedExtensionsIsolate(String cachedJson) {
    final List<dynamic> decoded = json.decode(cachedJson);
    return decoded
        .map((e) => MangaExtension.fromJson(e as Map<String, dynamic>))
        .where((e) => !MangaExtension.isStubPackage(e.pkg, e.name))
        .toList();
  }

  static String _encodeExtensionsCacheIsolate(List<MangaExtension> list) {
    return json.encode(list.map((e) => e.toJson()).toList());
  }

  static ExtensionRepoMeta _parseRepoProtobufIsolate(
    ({Uint8List bytes, String repoUrl}) args,
  ) {
    return _parseRepoProtobuf(args.bytes, repoUrl: args.repoUrl);
  }

  static List<MangaExtension> _parseJsonIndexIsolate(
    ({String jsonStr, String repoUrl}) args,
  ) {
    return _parseJsonIndex(args.jsonStr, repoUrl: args.repoUrl);
  }

  static List<MangaExtension> _parseProtobuf(
    Uint8List rawBytes, {
    String repoUrl = defaultRepoUrl,
  }) {
    return _parseRepoProtobuf(rawBytes, repoUrl: repoUrl).extensions;
  }

  static ExtensionRepoMeta _parseRepoProtobuf(
    Uint8List rawBytes, {
    String repoUrl = defaultRepoUrl,
  }) {
    Uint8List data = rawBytes;
    if (rawBytes.length >= 2 && rawBytes[0] == 0x1f && rawBytes[1] == 0x8b) {
      data = Uint8List.fromList(gzip.decode(rawBytes));
    }

    String repoName = '';
    String shortName = '';
    String signingKeyFingerprint = '';
    String website = '';
    String discord = '';
    final extensions = <MangaExtension>[];
    final legacyTopLevelField1 = <Uint8List>[];

    int pos = 0;
    while (pos < data.length) {
      final tagRes = _readVarint(data, pos);
      final tag = tagRes.value;
      pos = tagRes.nextPos;
      if (tag == 0) break;

      final wire = tag & 0x07;
      final field = tag >> 3;

      if (wire == 2) {
        final lenRes = _readVarint(data, pos);
        final len = lenRes.value;
        pos = lenRes.nextPos;
        if (len < 0 || pos + len > data.length) break;

        final sub = Uint8List.sublistView(data, pos, pos + len);
        pos += len;

        if (field == 1) {
          // In Repo schema, field 1 is repo.name ("Keiyoushi"), whereas in
          // raw Index messages field 1 is repeated Extension.
          legacyTopLevelField1.add(sub);
          if (repoName.isEmpty && sub.length < 120) {
            repoName = utf8.decode(sub, allowMalformed: true).trim();
          }
        } else if (field == 2) {
          shortName = utf8.decode(sub, allowMalformed: true).trim();
        } else if (field == 3) {
          signingKeyFingerprint = utf8.decode(sub, allowMalformed: true).trim();
        } else if (field == 4) {
          final links = _parseRepoLinks(sub);
          website = links.website;
          discord = links.discord;
        } else if (field == 101) {
          // Repo.index { repeated 1 = Extension }
          _parseIndexContainer(sub, extensions, repoUrl: repoUrl);
        }
      } else if (wire == 0) {
        pos = _readVarintBig(data, pos).nextPos;
      } else if (wire == 5) {
        pos += 4;
      } else if (wire == 1) {
        pos += 8;
      } else {
        break;
      }
    }

    // Fallback if someone passed an unwrapped Index message (repeated 1 = Extension)
    if (extensions.isEmpty && legacyTopLevelField1.isNotEmpty) {
      for (final sub in legacyTopLevelField1) {
        try {
          final ext = _parseExtensionItem(sub, repoUrl: repoUrl);
          if (ext != null &&
              ext.pkg.isNotEmpty &&
              !MangaExtension.isStubPackage(ext.pkg, ext.name)) {
            extensions.add(ext);
          }
        } catch (_) {}
      }
    }

    return ExtensionRepoMeta(
      name: repoName,
      shortName: shortName,
      signingKeyFingerprint: signingKeyFingerprint,
      website: website,
      discord: discord,
      extensions: extensions,
    );
  }

  static void _parseIndexContainer(
    Uint8List indexBytes,
    List<MangaExtension> out, {
    required String repoUrl,
  }) {
    int pos = 0;
    while (pos < indexBytes.length) {
      final tagRes = _readVarint(indexBytes, pos);
      final tag = tagRes.value;
      pos = tagRes.nextPos;
      if (tag == 0) break;

      final wire = tag & 0x07;
      final field = tag >> 3;

      if (wire == 2) {
        final lenRes = _readVarint(indexBytes, pos);
        final len = lenRes.value;
        pos = lenRes.nextPos;
        if (len < 0 || pos + len > indexBytes.length) break;

        final sub = Uint8List.sublistView(indexBytes, pos, pos + len);
        pos += len;

        if (field == 1) {
          try {
            final ext = _parseExtensionItem(sub, repoUrl: repoUrl);
            if (ext != null &&
                ext.pkg.isNotEmpty &&
                !MangaExtension.isStubPackage(ext.pkg, ext.name)) {
              out.add(ext);
            }
          } catch (_) {}
        }
      } else if (wire == 0) {
        pos = _readVarintBig(indexBytes, pos).nextPos;
      } else if (wire == 5) {
        pos += 4;
      } else if (wire == 1) {
        pos += 8;
      } else {
        break;
      }
    }
  }

  static ({String website, String discord}) _parseRepoLinks(Uint8List chunk) {
    int pos = 0;
    String website = '';
    String discord = '';

    while (pos < chunk.length) {
      final tagRes = _readVarint(chunk, pos);
      final tag = tagRes.value;
      pos = tagRes.nextPos;
      if (tag == 0) break;

      final wire = tag & 0x07;
      final field = tag >> 3;

      if (wire == 2) {
        final lenRes = _readVarint(chunk, pos);
        final len = lenRes.value;
        pos = lenRes.nextPos;
        if (len < 0 || pos + len > chunk.length) break;
        final s = utf8.decode(
          Uint8List.sublistView(chunk, pos, pos + len),
          allowMalformed: true,
        );
        pos += len;
        if (field == 1) website = s;
        if (field == 2) discord = s;
      } else if (wire == 0) {
        pos = _readVarintBig(chunk, pos).nextPos;
      } else if (wire == 5) {
        pos += 4;
      } else if (wire == 1) {
        pos += 8;
      } else {
        break;
      }
    }
    return (website: website, discord: discord);
  }

  static MangaExtension? _parseExtensionItem(
    Uint8List sub, {
    String repoUrl = defaultRepoUrl,
  }) {
    int pos = 0;
    String name = '';
    String pkg = '';
    String libVersion = '1.6';
    int versionCode = 0;
    String versionName = '';
    String apkUrl = '';
    String iconUrl = '';
    String jarUrl = '';
    int contentRating = 1; // 1=safe, 2=suggestive, 3=nsfw
    final sourceNames = <String>[];
    final parsedSources = <ExtensionSource>[];
    final seenNames = <String>{};
    final langSet = <String>{};
    final subSources = <Map<String, String>>[];
    String enHomeUrl = '';
    String firstHomeUrl = '';

    while (pos < sub.length) {
      final tagRes = _readVarint(sub, pos);
      final tag = tagRes.value;
      pos = tagRes.nextPos;
      if (tag == 0) break;

      final wire = tag & 0x07;
      final field = tag >> 3;

      if (wire == 2) {
        final lenRes = _readVarint(sub, pos);
        final len = lenRes.value;
        pos = lenRes.nextPos;
        if (len < 0 || pos + len > sub.length) break;
        final chunk = Uint8List.sublistView(sub, pos, pos + len);
        pos += len;

        if (field == 1) {
          name = _cleanExtensionName(
            utf8.decode(chunk, allowMalformed: true),
          );
        } else if (field == 2) {
          pkg = utf8.decode(chunk, allowMalformed: true).trim();
        } else if (field == 3) {
          final assets = _parseAssets(chunk);
          apkUrl = assets.apk.isNotEmpty
              ? _resolveRepoAssetUrl(assets.apk, 'apk', repoUrl)
              : '';
          iconUrl = assets.icon.isNotEmpty
              ? _resolveRepoAssetUrl(assets.icon, 'icon', repoUrl)
              : '';
          jarUrl = assets.jar.isNotEmpty
              ? _resolveRepoAssetUrl(assets.jar, 'jar', repoUrl)
              : '';
        } else if (field == 4) {
          libVersion = utf8.decode(chunk, allowMalformed: true).trim();
        } else if (field == 6) {
          versionName = utf8.decode(chunk, allowMalformed: true).trim();
        } else if (field == 8) {
          final src = _parseSource(chunk);
          if (src.name.isNotEmpty && seenNames.add(src.name)) {
            sourceNames.add(src.name);
          }
          final sl = src.lang.trim().toUpperCase();
          if (sl.isNotEmpty) langSet.add(sl);
          final firstBase = src.baseUrl
              .split(_baseUrlSplitRe)
              .firstWhere((u) => u.startsWith('http'), orElse: () => src.baseUrl);
          if (firstHomeUrl.isEmpty && firstBase.isNotEmpty) {
            firstHomeUrl = firstBase;
          }
          if (enHomeUrl.isEmpty &&
              (sl == 'EN' || sl == 'ALL') &&
              firstBase.isNotEmpty) {
            enHomeUrl = firstBase;
          }
          if (src.name.isNotEmpty || src.id.isNotEmpty) {
            final resolvedLang = sl.isNotEmpty ? sl : 'ALL';
            subSources.add({
              'id': src.id,
              'name': src.name,
              'lang': resolvedLang,
              'baseUrl': firstBase,
            });
            parsedSources.add(
              ExtensionSource(
                id: src.id,
                name: src.name,
                lang: resolvedLang,
                baseUrl: firstBase,
              ),
            );
          }
        }
      } else if (wire == 0) {
        final valRes = _readVarint(sub, pos);
        final val = valRes.value;
        pos = valRes.nextPos;
        if (field == 5) {
          versionCode = val;
        } else if (field == 7) {
          contentRating = val;
        }
      } else if (wire == 5) {
        pos += 4;
      } else if (wire == 1) {
        pos += 8;
      } else {
        break;
      }
    }

    if (name.isEmpty && pkg.isEmpty) return null;
    if (MangaExtension.isStubPackage(pkg, name)) return null;

    if (iconUrl.isEmpty && pkg.isNotEmpty) {
      iconUrl = _resolveRepoAssetUrl('$pkg.png', 'icon', repoUrl);
    }

    // Derive extension lang from pkg (eu.kanade.tachiyomi.extension.<lang>.<name>),
    // "all" -> multi-language ('ALL').
    final lang = MangaExtension.deriveLangFromPkg(pkg);
    langSet.add(lang);

    final homeUrl = enHomeUrl.isNotEmpty ? enHomeUrl : firstHomeUrl;

    return MangaExtension(
      id: pkg,
      name: name.isNotEmpty
          ? name
          : (sourceNames.isNotEmpty ? sourceNames.first : pkg),
      pkg: pkg,
      version: versionName,
      versionCode: versionCode,
      libVersion: libVersion.isNotEmpty ? libVersion : '1.6',
      apkUrl: apkUrl,
      iconUrl: iconUrl,
      jarUrl: jarUrl,
      lang: lang,
      isNsfw: contentRating == 3,
      contentRating: contentRating,
      sourceNames: sourceNames,
      supportedLangs: langSet.toList(),
      subSources: subSources.length > 1 ? subSources : const [],
      sources: parsedSources,
      homeUrl: homeUrl,
    );
  }

  static ({String apk, String icon, String jar}) _parseAssets(Uint8List chunk) {
    int pos = 0;
    String apk = '';
    String icon = '';
    String jar = '';

    while (pos < chunk.length) {
      final tagRes = _readVarint(chunk, pos);
      final tag = tagRes.value;
      pos = tagRes.nextPos;
      if (tag == 0) break;

      final wire = tag & 0x07;
      final field = tag >> 3;

      if (wire == 2) {
        final lenRes = _readVarint(chunk, pos);
        final len = lenRes.value;
        pos = lenRes.nextPos;
        if (len < 0 || pos + len > chunk.length) break;
        final s = utf8.decode(
          Uint8List.sublistView(chunk, pos, pos + len),
          allowMalformed: true,
        );
        pos += len;
        if (field == 1) apk = s;
        if (field == 2) icon = s;
        if (field == 501) jar = s;
      } else if (wire == 0) {
        pos = _readVarintBig(chunk, pos).nextPos;
      } else if (wire == 5) {
        pos += 4;
      } else if (wire == 1) {
        pos += 8;
      } else {
        break;
      }
    }
    return (apk: apk, icon: icon, jar: jar);
  }

  static ({String id, String name, String lang, String baseUrl}) _parseSource(
    Uint8List chunk,
  ) {
    int pos = 0;
    String id = '';
    String name = '';
    String lang = '';
    String baseUrl = '';

    while (pos < chunk.length) {
      final tagRes = _readVarint(chunk, pos);
      final tag = tagRes.value;
      pos = tagRes.nextPos;
      if (tag == 0) break;

      final wire = tag & 0x07;
      final field = tag >> 3;

      if (wire == 2) {
        final lenRes = _readVarint(chunk, pos);
        final len = lenRes.value;
        pos = lenRes.nextPos;
        if (len < 0 || pos + len > chunk.length) break;
        final s = utf8.decode(
          Uint8List.sublistView(chunk, pos, pos + len),
          allowMalformed: true,
        );
        pos += len;
        if (field == 2) name = s;
        if (field == 3) lang = s;
        if (field == 4) baseUrl = s;
      } else if (wire == 0) {
        final valRes = _readVarintBig(chunk, pos);
        pos = valRes.nextPos;
        if (field == 1) id = valRes.value.toString();
      } else if (wire == 5) {
        pos += 4;
      } else if (wire == 1) {
        pos += 8;
      } else {
        break;
      }
    }
    return (id: id, name: name, lang: lang, baseUrl: baseUrl);
  }
}
