import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class MangaExtension {
  final String id;
  final String name;
  final String pkg;
  final String version;
  final int versionCode;
  final String apkUrl;
  final String iconUrl;
  final String lang;
  final bool isNsfw;
  final List<String> sourceNames;
  final String homeUrl;
  bool isInstalled;

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
    this.homeUrl = '',
    this.isInstalled = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'pkg': pkg,
    'version': version,
    'versionCode': versionCode,
    'apkUrl': apkUrl,
    'iconUrl': iconUrl,
    'lang': lang,
    'isNsfw': isNsfw,
    'sourceNames': sourceNames,
    'homeUrl': homeUrl,
    'isInstalled': isInstalled,
  };

  factory MangaExtension.fromJson(Map<String, dynamic> json) => MangaExtension(
    id: json['id'] as String? ?? json['pkg'] as String? ?? '',
    name: json['name'] as String? ?? '',
    pkg: json['pkg'] as String? ?? '',
    version: json['version'] as String? ?? '',
    versionCode: json['versionCode'] as int? ?? 0,
    apkUrl: json['apkUrl'] as String? ?? '',
    iconUrl: json['iconUrl'] as String? ?? '',
    lang: json['lang'] as String? ?? 'ALL',
    isNsfw: json['isNsfw'] as bool? ?? false,
    sourceNames: (json['sourceNames'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
    homeUrl: json['homeUrl'] as String? ?? '',
    isInstalled: json['isInstalled'] as bool? ?? false,
  );
}

class ExtensionService extends ChangeNotifier {
  static final ExtensionService instance = ExtensionService._();
  ExtensionService._() {
    _init();
  }

  static const String defaultRepoUrl = 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.json';
  static const String _repoUrlKey = 'shiori_extension_repo_url_v2';
  static const String _installedKey = 'shiori_installed_extensions';
  static const String _cacheKey = 'shiori_extensions_cache_v2';

  String _repoUrl = defaultRepoUrl;
  String get repoUrl => _repoUrl;

  List<MangaExtension> _extensions = [];
  List<MangaExtension> get extensions => _extensions;

  final Set<String> _installedPackages = {};
  Set<String> get installedPackages => _installedPackages;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  Future<void> _init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _repoUrl = prefs.getString(_repoUrlKey) ?? defaultRepoUrl;
      final installedList = prefs.getStringList(_installedKey);
      if (installedList != null) {
        _installedPackages.clear();
        _installedPackages.addAll(installedList);
      }

      // Load cache if present
      final cachedJson = prefs.getString(_cacheKey);
      if (cachedJson != null && cachedJson.isNotEmpty) {
        try {
          final List<dynamic> decoded = json.decode(cachedJson);
          _extensions = decoded.map((e) => MangaExtension.fromJson(e as Map<String, dynamic>)).toList();
          _updateInstalledState();
          notifyListeners();
        } catch (_) {}
      }

      // Query system for installed packages on Android
      await refreshInstalledPackages();

      // Fetch fresh data in the background
      fetchExtensions();
    } catch (e) {
      debugPrint('ExtensionService init error: $e');
    }
  }

  Future<void> refreshInstalledPackages() async {
    if (Platform.isAndroid) {
      try {
        final List<dynamic>? installed = await _installerChannel.invokeMethod('getInstalledExtensions');
        if (installed != null) {
          for (final pkg in installed) {
            final p = pkg.toString().toLowerCase().trim();
            if (p.isNotEmpty) _installedPackages.add(p);
          }
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList(_installedKey, _installedPackages.toList());
        }
      } catch (e) {
        debugPrint('Error getting installed extensions from device: $e');
      }
    }
    _updateInstalledState();
    notifyListeners();
  }

  List<MangaExtension> get installedExtensions {
    return _extensions.where((e) => e.isInstalled).toList();
  }

  bool isPackageInstalled(String pkgOrId) {
    final lower = pkgOrId.toLowerCase().trim();
    return _installedPackages.any((p) {
      final pl = p.toLowerCase().trim();
      return pl == lower || pl.contains(lower) || lower.contains(pl);
    });
  }

  void _updateInstalledState() {
    for (final ext in _extensions) {
      final pkgLower = ext.pkg.toLowerCase().trim();
      final nameLower = ext.name.toLowerCase().trim();
      final idLower = ext.id.toLowerCase().trim();
      ext.isInstalled = _installedPackages.any((p) {
        final pl = p.toLowerCase().trim();
        return pl == pkgLower ||
            pl == nameLower ||
            pl == idLower ||
            pkgLower.contains(pl) ||
            pl.contains(pkgLower);
      });
    }
  }

  Future<void> setRepoUrl(String newUrl) async {
    _repoUrl = newUrl.trim().isEmpty ? defaultRepoUrl : newUrl.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_repoUrlKey, _repoUrl);
    await fetchExtensions(force: true);
  }

  static List<MangaExtension> _parseJsonIndex(String jsonStr) {
    try {
      final decoded = json.decode(jsonStr);
      final list = <MangaExtension>[];
      if (decoded is Map<String, dynamic>) {
        final extListMap = decoded['extensionList'] as Map<String, dynamic>? ?? {};
        for (final entry in extListMap.entries) {
          final lang = entry.key.toUpperCase();
          final exts = entry.value as List<dynamic>? ?? [];
          for (final item in exts) {
            if (item is Map<String, dynamic>) {
              final res = item['resources'] as Map<String, dynamic>? ?? {};
              final apkUrl = res['apkUrl']?.toString() ?? '';
              final iconUrl = res['iconUrl']?.toString() ?? '';
              final rawSources = (item['sources'] as List<dynamic>?) ?? [];
              final sources = rawSources
                  .map((s) => (s as Map<String, dynamic>)['name']?.toString() ?? '')
                  .where((n) => n.isNotEmpty)
                  .toList();
              final homeUrl = rawSources.isNotEmpty
                  ? (rawSources[0] as Map<String, dynamic>)['homeUrl']?.toString() ?? ''
                  : '';
              final pkg = item['packageName']?.toString() ?? '';
              final name = item['name']?.toString() ?? '';
              final version = item['versionName']?.toString() ?? '';
              final versionCode = int.tryParse(item['versionCode']?.toString() ?? '') ?? 0;
              final isNsfw = item['contentWarning'] == 'CONTENT_WARNING_NSFW';

              if (name.isNotEmpty && pkg.isNotEmpty) {
                list.add(MangaExtension(
                  id: pkg,
                  name: name,
                  pkg: pkg,
                  version: version,
                  versionCode: versionCode,
                  apkUrl: apkUrl,
                  iconUrl: iconUrl,
                  lang: lang,
                  isNsfw: isNsfw,
                  sourceNames: sources,
                  homeUrl: homeUrl,
                ));
              }
            }
          }
        }
      }
      return list;
    } catch (e) {
      debugPrint('Error parsing index.json: $e');
      return [];
    }
  }

  Future<void> fetchExtensions({bool force = false}) async {
    if (_isLoading) return;
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final uri = Uri.parse(_repoUrl);
      final res = await http.get(uri).timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        List<MangaExtension> parsed = [];
        if (_repoUrl.contains('.json')) {
          parsed = _parseJsonIndex(res.body);
        } else {
          parsed = _parseProtobuf(res.bodyBytes);
        }

        if (parsed.isNotEmpty) {
          _extensions = parsed;
          _updateInstalledState();

          // Save to cache asynchronously
          SharedPreferences.getInstance().then((prefs) {
            final jsonStr = json.encode(_extensions.take(300).map((e) => e.toJson()).toList());
            prefs.setString(_cacheKey, jsonStr);
          }).catchError((_) {});
        }
      } else {
        _error = 'Failed to load extensions (HTTP ${res.statusCode})';
      }
    } catch (e) {
      _error = 'Failed to fetch repository: $e';
      debugPrint('Extension fetch error: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  bool get hasMangaDex => isPackageInstalled('mangadex');
  bool get hasAsura => isPackageInstalled('asura');

  Future<bool> isAppInstalled(String packageName) async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _installerChannel.invokeMethod<bool>('isAppInstalled', {'packageName': packageName});
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> launchApp(String packageName) async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _installerChannel.invokeMethod<bool>('launchPackage', {'packageName': packageName});
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  MangaExtension? getExtensionByPkg(String pkgOrId) {
    final lower = pkgOrId.toLowerCase().trim();
    try {
      return _extensions.firstWhere((e) {
        final p = e.pkg.toLowerCase().trim();
        final id = e.id.toLowerCase().trim();
        final name = e.name.toLowerCase().trim();
        return p == lower || id == lower || name == lower || p.contains(lower) || lower.contains(p);
      });
    } catch (_) {
      return null;
    }
  }

  Future<void> installExtension(MangaExtension ext) async {
    installPackageByNameOrId(ext.pkg.isNotEmpty ? ext.pkg : ext.id);
  }

  Future<void> installPackageByNameOrId(String pkgOrId) async {
    final lower = pkgOrId.toLowerCase().trim();
    _installedPackages.add(lower);
    _updateInstalledState();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_installedKey, _installedPackages.toList());
    notifyListeners();
  }

  Future<void> uninstallExtension(MangaExtension ext) async {
    uninstallPackage(ext.pkg.isNotEmpty ? ext.pkg : ext.id);
  }

  Future<void> uninstallPackage(String pkgOrId) async {
    final lower = pkgOrId.toLowerCase().trim();
    _installedPackages.remove(pkgOrId);
    _installedPackages.remove(lower);
    _installedPackages.removeWhere((p) {
      final pl = p.toLowerCase().trim();
      return pl == lower || pl.contains(lower) || lower.contains(pl);
    });

    _updateInstalledState();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_installedKey, _installedPackages.toList());
    notifyListeners();
  }

  Future<void> uninstallAll() async {
    _installedPackages.clear();
    for (final e in _extensions) {
      e.isInstalled = false;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_installedKey);
    notifyListeners();
  }

  static const MethodChannel _installerChannel = MethodChannel('com.example.manga_reader/installer');

  final Map<String, double> _downloadProgress = {};
  Map<String, double> get downloadProgress => _downloadProgress;

  final Set<String> _downloadingPackages = {};
  Set<String> get downloadingPackages => _downloadingPackages;

  bool isDownloading(String pkgOrId) {
    final lower = pkgOrId.toLowerCase().trim();
    return _downloadingPackages.contains(lower);
  }

  double getProgress(String pkgOrId) {
    final lower = pkgOrId.toLowerCase().trim();
    return _downloadProgress[lower] ?? 0.0;
  }

  Future<bool> downloadApk(MangaExtension ext) async {
    return downloadAndInstallApk(ext);
  }

  Future<bool> downloadAndInstallApk(MangaExtension ext) async {
    var url = ext.apkUrl.trim();
    if (url.isEmpty) return false;

    final key = (ext.pkg.isNotEmpty ? ext.pkg : ext.id).toLowerCase().trim();
    if (_downloadingPackages.contains(key)) return false;

    _downloadingPackages.add(key);
    _downloadProgress[key] = 0.02;
    notifyListeners();

    try {
      final uri = Uri.parse(url);
      final client = http.Client();
      final request = http.Request('GET', uri)..followRedirects = true;
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final totalBytes = response.contentLength ?? 0;
      var receivedBytes = 0;

      final dir = Directory('${Directory.systemTemp.path}/shiori_apks');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final cleanName = ext.pkg.replaceAll(RegExp(r'[^a-zA-Z0-9_\.]'), '_');
      final apkFile = File('${dir.path}/$cleanName.apk');
      final sink = apkFile.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          _downloadProgress[key] = (receivedBytes / totalBytes).clamp(0.0, 1.0);
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      client.close();

      _downloadProgress[key] = 1.0;
      notifyListeners();

      // Trigger Android native package installer prompt via FileProvider
      if (Platform.isAndroid) {
        try {
          await installPackageByNameOrId(ext.pkg);
          final res = await _installerChannel.invokeMethod('installApk', {'filePath': apkFile.path});
          return res == true;
        } catch (e) {
          debugPrint('Native installer channel error: $e');
          return false;
        }
      }
      return true;
    } catch (e) {
      debugPrint('downloadAndInstallApk error ($url): $e');
      return false;
    } finally {
      _downloadingPackages.remove(key);
      notifyListeners();
    }
  }

  static List<MangaExtension> _parseProtobuf(Uint8List rawBytes) {
    Uint8List data = rawBytes;
    if (rawBytes.length >= 2 && rawBytes[0] == 0x1f && rawBytes[1] == 0x8b) {
      data = Uint8List.fromList(gzip.decode(rawBytes));
    }

    final extensions = <MangaExtension>[];
    int pos = 0;

    while (pos < data.length) {
      final tag = data[pos++];
      final wire = tag & 0x07;
      final field = tag >> 3;

      if (wire == 2) {
        int len = 0;
        int shift = 0;
        while (true) {
          final b = data[pos++];
          len |= (b & 0x7f) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }

        if (pos + len > data.length) break;
        final sub = Uint8List.sublistView(data, pos, pos + len);
        pos += len;

        if (field == 1) {
          try {
            final ext = _parseExtensionItem(sub);
            if (ext != null && ext.name.isNotEmpty) {
              extensions.add(ext);
            }
          } catch (_) {}
        }
      } else if (wire == 0) {
        while ((data[pos++] & 0x80) != 0) {}
      } else if (wire == 5) {
        pos += 4;
      } else if (wire == 1) {
        pos += 8;
      } else {
        break;
      }
    }

    return extensions;
  }

  static MangaExtension? _parseExtensionItem(Uint8List sub) {
    int pos = 0;
    String name = '';
    String pkg = '';
    String version = '';
    int versionCode = 0;
    String apkUrl = '';
    String iconUrl = '';
    int nsfw = 0;
    String lang = 'all';
    final sourceNames = <String>[];

    while (pos < sub.length) {
      final tag = sub[pos++];
      final wire = tag & 0x07;
      final field = tag >> 3;

      if (wire == 2) {
        int len = 0;
        int shift = 0;
        while (true) {
          final b = sub[pos++];
          len |= (b & 0x7f) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (pos + len > sub.length) break;
        final chunk = Uint8List.sublistView(sub, pos, pos + len);
        pos += len;

        if (field == 1) {
          name = utf8.decode(chunk, allowMalformed: true);
        } else if (field == 2) {
          pkg = utf8.decode(chunk, allowMalformed: true);
        } else if (field == 3) {
          final assets = _parseAssets(chunk);
          apkUrl = assets.apk.isNotEmpty
              ? (assets.apk.startsWith('http')
                  ? assets.apk
                  : 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/apk/${assets.apk}')
              : '';
          iconUrl = assets.icon.isNotEmpty
              ? (assets.icon.startsWith('http')
                  ? assets.icon
                  : 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/icon/${assets.icon}')
              : '';
        } else if (field == 6) {
          version = utf8.decode(chunk, allowMalformed: true);
        } else if (field == 8) {
          final src = _parseSource(chunk);
          if (src.name.isNotEmpty) sourceNames.add(src.name);
          if (src.lang.isNotEmpty && lang == 'all') lang = src.lang;
        }
      } else if (wire == 0) {
        int val = 0;
        int shift = 0;
        while (true) {
          final b = sub[pos++];
          val |= (b & 0x7f) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (field == 5) {
          versionCode = val;
        } else if (field == 7) {
          nsfw = val;
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

    if (lang == 'all') {
      final parts = pkg.split('.');
      if (parts.length >= 5 && parts[3] != 'all') {
        lang = parts[3].toUpperCase();
      }
    }

    return MangaExtension(
      id: pkg,
      name: name.isNotEmpty ? name : (sourceNames.isNotEmpty ? sourceNames.first : pkg),
      pkg: pkg,
      version: version,
      versionCode: versionCode,
      apkUrl: apkUrl,
      iconUrl: iconUrl,
      lang: lang.toUpperCase(),
      isNsfw: nsfw >= 2,
      sourceNames: sourceNames,
    );
  }

  static ({String apk, String icon}) _parseAssets(Uint8List chunk) {
    int pos = 0;
    String apk = '';
    String icon = '';

    while (pos < chunk.length) {
      final tag = chunk[pos++];
      final wire = tag & 0x07;
      final field = tag >> 3;

      if (wire == 2) {
        int len = 0;
        int shift = 0;
        while (true) {
          final b = chunk[pos++];
          len |= (b & 0x7f) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (pos + len > chunk.length) break;
        final s = utf8.decode(Uint8List.sublistView(chunk, pos, pos + len), allowMalformed: true);
        pos += len;
        if (field == 1) apk = s;
        if (field == 2) icon = s;
      } else if (wire == 0) {
        while ((chunk[pos++] & 0x80) != 0) {}
      } else if (wire == 5) {
        pos += 4;
      } else if (wire == 1) {
        pos += 8;
      } else {
        break;
      }
    }
    return (apk: apk, icon: icon);
  }

  static ({String name, String lang, String baseUrl}) _parseSource(Uint8List chunk) {
    int pos = 0;
    String name = '';
    String lang = '';
    String baseUrl = '';

    while (pos < chunk.length) {
      final tag = chunk[pos++];
      final wire = tag & 0x07;
      final field = tag >> 3;

      if (wire == 2) {
        int len = 0;
        int shift = 0;
        while (true) {
          final b = chunk[pos++];
          len |= (b & 0x7f) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (pos + len > chunk.length) break;
        final s = utf8.decode(Uint8List.sublistView(chunk, pos, pos + len), allowMalformed: true);
        pos += len;
        if (field == 2) name = s;
        if (field == 3) lang = s;
        if (field == 4) baseUrl = s;
      } else if (wire == 0) {
        while ((chunk[pos++] & 0x80) != 0) {}
      } else if (wire == 5) {
        pos += 4;
      } else if (wire == 1) {
        pos += 8;
      } else {
        break;
      }
    }
    return (name: name, lang: lang, baseUrl: baseUrl);
  }
}
