import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/manga_models.dart';
import '../widgets/common.dart';
import 'extension_service.dart';

class ExtensionBridge {
  static final ExtensionBridge instance = ExtensionBridge._();
  ExtensionBridge._();

  static const MethodChannel _channel = MethodChannel('com.example.manga_reader/extensions');
  final Map<String, String> _baseUrlCache = {};
  final Map<String, Map<String, String>> _sourceHeadersCache = {};
  final Map<String, bool> _preferNativeImagesCache = {};

  /// Test hook allowing unit tests on desktop CI/macOS to exercise MethodChannel logic.
  @visibleForTesting
  bool? forceAndroidForTesting;

  bool get _isAndroidSupported => forceAndroidForTesting ?? (!kIsWeb && Platform.isAndroid);

  void evictSourceCache(String pkg) {
    final basePkg = pkg.split('@').first.trim();
    _baseUrlCache.removeWhere((k, _) => k == pkg || k.startsWith('$basePkg@') || k == basePkg);
    _sourceHeadersCache.removeWhere((k, _) => k == pkg || k.startsWith('$basePkg@') || k == basePkg);
    _preferNativeImagesCache.removeWhere((k, _) => k == pkg || k.startsWith('$basePkg@') || k == basePkg);
  }

  @visibleForTesting
  void clearCachesForTesting() {
    _baseUrlCache.clear();
    _sourceHeadersCache.clear();
    _preferNativeImagesCache.clear();
  }

  String? _findApkPath(String pkg) {
    final basePkg = pkg.split('@').first.trim();
    if (basePkg.isEmpty) return null;
    try {
      final cleanName = basePkg.replaceAll(RegExp(r'[^a-zA-Z0-9_\.]'), '_');
      final f1 = File('${Directory.systemTemp.path}/shiori_extensions/$cleanName.apk');
      if (f1.existsSync() && f1.lengthSync() > 1024) {
        return f1.path;
      }
      final f2 = File('${Directory.systemTemp.path}/shiori_extensions/$basePkg.apk');
      if (f2.existsSync() && f2.lengthSync() > 1024) {
        return f2.path;
      }
    } catch (_) {}
    return null;
  }

  /// Ensures the extension's APK is available locally on-demand even if the user
  /// hasn't manually installed it yet or if OS temp storage was cleared.
  Future<String?> _ensureApkPath(String pkg) async {
    final basePkg = pkg.split('@').first.trim();
    if (basePkg.isEmpty) return null;
    final lowerBase = basePkg.toLowerCase();

    // When installed on the Android device, let native TachiyomiExtensionManager
    // load directly from PackageManager (/data/app/...) rather than downloading
    // repo update APKs into temp/private storage during normal browse/search.
    if (ExtensionService.instance.deviceExtensionsMap.containsKey(lowerBase)) {
      return null;
    }

    final existing = _findApkPath(pkg);
    if (existing != null) return existing;
    if (!_isAndroidSupported) return null;

    var ext = ExtensionService.instance.getExtensionByPkg(basePkg);
    if (ext == null && ExtensionService.instance.extensions.isEmpty) {
      await ExtensionService.instance.fetchExtensions();
      ext = ExtensionService.instance.getExtensionByPkg(basePkg);
    }
    if (ext != null && ext.apkUrl.trim().isNotEmpty) {
      final downloaded = await ExtensionService.instance.ensureApkDownloaded(ext, notify: false);
      if (downloaded != null && downloaded.isNotEmpty) {
        return downloaded;
      }
    }
    return _findApkPath(pkg);
  }

  Future<void> openInWebView({required String url, String? title}) async {
    if (!_isAndroidSupported) return;
    try {
      await _channel.invokeMethod('openInWebView', {
        'url': url,
        'title': title ?? '',
      });
      // Clear cached headers so newly acquired Cloudflare cookies apply immediately.
      _sourceHeadersCache.clear();
      _preferNativeImagesCache.clear();
    } catch (e) {
      debugPrint('ExtensionBridge openInWebView error: $e');
    }
  }

  Future<String?> getSourceBaseUrl({required String pkg}) async {
    final cached = _baseUrlCache[pkg];
    if (cached != null && cached.isNotEmpty) return cached;
    if (!_isAndroidSupported) return null;
    try {
      final apkPath = await _ensureApkPath(pkg);
      final base = await _channel.invokeMethod<String>('getSourceBaseUrl', {
        'pkg': pkg,
        'apkPath': apkPath,
      });
      if (base != null && base.isNotEmpty) {
        _baseUrlCache[pkg] = base;
      }
      return base;
    } catch (e) {
      debugPrint('ExtensionBridge getSourceBaseUrl error: $e');
      return null;
    }
  }

  Future<Map<String, String>> getSourceHeaders({
    required String pkg,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _sourceHeadersCache.containsKey(pkg)) {
      return _sourceHeadersCache[pkg]!;
    }
    if (!_isAndroidSupported) return const {};
    try {
      final apkPath = await _ensureApkPath(pkg);
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('getSourceHeaders', {
        'pkg': pkg,
        'apkPath': apkPath,
      });
      if (raw == null) return const {};

      final headers = <String, String>{};
      final rawHeaders = raw['headers'];
      if (rawHeaders is Map) {
        rawHeaders.forEach((k, v) {
          final key = k?.toString().trim() ?? '';
          final val = v?.toString().trim() ?? '';
          if (key.isNotEmpty && val.isNotEmpty) {
            headers[key] = val;
          }
        });
      }
      final baseUrl = raw['baseUrl']?.toString().trim() ?? '';
      if (baseUrl.isNotEmpty) {
        _baseUrlCache[pkg] = baseUrl;
      }
      final nativeImages = raw['nativeImages'] == true;
      _preferNativeImagesCache[pkg] = nativeImages;
      _sourceHeadersCache[pkg] = headers;
      return headers;
    } catch (e) {
      debugPrint('ExtensionBridge getSourceHeaders error ($pkg): $e');
      return const {};
    }
  }

  Future<Uint8List?> fetchImageBytes({
    required String pkg,
    required String url,
    String? pageUrl,
  }) async {
    if (!_isAndroidSupported || url.trim().isEmpty) return null;
    try {
      final apkPath = await _ensureApkPath(pkg);
      final bytes = await _channel.invokeMethod<Uint8List>('fetchImageBytes', {
        'pkg': pkg,
        'url': url,
        'imageUrl': url,
        'pageUrl': pageUrl,
        'apkPath': apkPath,
      });
      if (bytes != null && bytes.isNotEmpty) return bytes;
    } catch (e) {
      debugPrint('ExtensionBridge fetchImageBytes error ($pkg, $url): $e');
    }
    return null;
  }

  Future<void> _registerImagesForPkg(
    String pkg,
    Iterable<String> urls, {
    String? refererHint,
    String? pageUrl,
  }) async {
    final nonEmpty = urls.where((u) => u.startsWith('http')).toList();
    if (nonEmpty.isEmpty) return;

    final headers = await getSourceHeaders(pkg: pkg);
    final referer = (refererHint != null && refererHint.isNotEmpty)
        ? refererHint
        : (_baseUrlCache[pkg] ??
            headers['Referer'] ??
            ExtensionService.instance.getExtensionByPkg(pkg)?.homeUrl ??
            '');
    final preferNative = _preferNativeImagesCache[pkg] ?? false;

    ImageReferers.registerSourceConfig(
      nonEmpty,
      referer: referer,
      headers: headers,
      nativeLoader: _isAndroidSupported
          ? (u) => fetchImageBytes(pkg: pkg, url: u, pageUrl: pageUrl)
          : null,
      preferNative: preferNative,
    );
  }

  Future<List<MangaItem>> fetchPopularManga({
    required String pkg,
    int page = 1,
    String? type,
  }) async {
    if (!_isAndroidSupported) return [];
    try {
      final apkPath = await _ensureApkPath(pkg);
      final rawList = await _channel.invokeMethod<List<dynamic>>(
        'fetchPopularManga',
        {
          'pkg': pkg,
          'page': page,
          'type': type,
          'apkPath': apkPath,
        },
      );

      if (rawList == null) return [];
      final items = rawList.map((item) => _mapToMangaItem(pkg, item as Map, requestedType: type)).toList();
      await _registerImagesForPkg(pkg, items.map((m) => m.cover), refererHint: _baseUrlCache[pkg]);
      return items;
    } catch (e) {
      debugPrint('ExtensionBridge fetchPopularManga error ($pkg): $e');
      rethrow;
    }
  }

  Future<List<MangaItem>> fetchLatestUpdates({
    required String pkg,
    int page = 1,
    String? type,
  }) async {
    if (!_isAndroidSupported) return [];
    try {
      final apkPath = await _ensureApkPath(pkg);
      final rawList = await _channel.invokeMethod<List<dynamic>>(
        'fetchLatestUpdates',
        {
          'pkg': pkg,
          'page': page,
          'type': type,
          'apkPath': apkPath,
        },
      );

      if (rawList == null) return [];
      final items = rawList.map((item) => _mapToMangaItem(pkg, item as Map, requestedType: type)).toList();
      await _registerImagesForPkg(pkg, items.map((m) => m.cover), refererHint: _baseUrlCache[pkg]);
      return items;
    } catch (e) {
      debugPrint('ExtensionBridge fetchLatestUpdates error ($pkg): $e');
      rethrow;
    }
  }

  Future<List<MangaItem>> searchManga({
    required String pkg,
    required String query,
    int page = 1,
    String? type,
  }) async {
    if (!_isAndroidSupported) return [];
    try {
      final apkPath = await _ensureApkPath(pkg);
      final rawList = await _channel.invokeMethod<List<dynamic>>(
        'searchManga',
        {
          'pkg': pkg,
          'query': query,
          'page': page,
          'type': type,
          'apkPath': apkPath,
        },
      );

      if (rawList == null) return [];
      final items = rawList.map((item) => _mapToMangaItem(pkg, item as Map, requestedType: type)).toList();
      await _registerImagesForPkg(pkg, items.map((m) => m.cover), refererHint: _baseUrlCache[pkg]);
      return items;
    } catch (e) {
      debugPrint('ExtensionBridge searchManga error ($pkg): $e');
      rethrow;
    }
  }

  Future<MangaItem> fetchMangaDetails({
    required String pkg,
    required String url,
    String? title,
  }) async {
    if (!_isAndroidSupported) {
      throw UnsupportedError('Extensions are only supported on Android');
    }
    try {
      final apkPath = await _ensureApkPath(pkg);
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'fetchMangaDetails',
        {
          'pkg': pkg,
          'url': url,
          'title': title,
          'apkPath': apkPath,
        },
      );

      if (raw == null) {
        throw Exception('Extension returned null details for $url');
      }

      final item = _mapToMangaItem(pkg, raw, fallbackUrl: url, fallbackTitle: title);
      if (item.cover.isNotEmpty) {
        await _registerImagesForPkg(pkg, [item.cover], refererHint: _baseUrlCache[pkg]);
      }
      return item;
    } catch (e) {
      debugPrint('ExtensionBridge fetchMangaDetails error ($pkg, $url): $e');
      rethrow;
    }
  }

  Future<List<ChapterItem>> fetchChapterList({
    required String pkg,
    required String url,
    String? title,
  }) async {
    if (!_isAndroidSupported) return [];
    try {
      final apkPath = await _ensureApkPath(pkg);
      final rawList = await _channel.invokeMethod<List<dynamic>>(
        'fetchChapterList',
        {
          'pkg': pkg,
          'url': url,
          'title': title,
          'apkPath': apkPath,
        },
      );

      if (rawList == null) return [];
      return rawList.map((item) => _mapToChapterItem(pkg, item as Map)).toList();
    } catch (e) {
      debugPrint('ExtensionBridge fetchChapterList error ($pkg, $url): $e');
      rethrow;
    }
  }

  Future<List<String>> fetchPageList({
    required String pkg,
    required String chapterUrl,
  }) async {
    if (!_isAndroidSupported) return [];
    try {
      final apkPath = await _ensureApkPath(pkg);
      final rawList = await _channel.invokeMethod<List<dynamic>>(
        'fetchPageList',
        {
          'pkg': pkg,
          'chapterUrl': chapterUrl,
          'apkPath': apkPath,
        },
      );

      if (rawList == null) return [];
      final referer = _baseUrlCache[pkg] ??
          await getSourceBaseUrl(pkg: pkg) ??
          ExtensionService.instance.getExtensionByPkg(pkg)?.homeUrl ??
          '';
      final pages = rawList
          .map((e) => _normalizeUrl(e.toString(), baseUrl: referer))
          .where((u) => u.isNotEmpty)
          .toList();
      if (pages.isNotEmpty) {
        await _registerImagesForPkg(
          pkg,
          pages,
          refererHint: referer,
          pageUrl: chapterUrl,
        );
      }
      return pages;
    } catch (e) {
      debugPrint('ExtensionBridge fetchPageList error ($pkg, $chapterUrl): $e');
      rethrow;
    }
  }

  static String _normalizeUrl(String raw, {String? baseUrl}) {
    var u = raw.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('data:')) return '';
    if (u.startsWith('//')) u = 'https:$u';
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      if (baseUrl != null && baseUrl.startsWith('http')) {
        try {
          final baseUri = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/');
          u = baseUri.resolve(u).toString();
        } catch (_) {
          final cleanBase = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
          u = u.startsWith('/') ? '$cleanBase$u' : '$cleanBase/$u';
        }
      }
    }
    if (u.contains(' ')) u = u.replaceAll(' ', '%20');
    if (u.contains('uploads.mangadex.org/covers/') && !u.contains('.512.jpg') && !u.contains('.256.jpg')) {
      u = '$u.512.jpg';
    }
    return u;
  }

  MangaItem _mapToMangaItem(
    String pkg,
    Map raw, {
    String? fallbackUrl,
    String? fallbackTitle,
    String? requestedType,
  }) {
    final url = raw['url']?.toString() ?? fallbackUrl ?? '';
    final title = raw['title']?.toString() ?? fallbackTitle ?? 'Untitled';
    final referer = (raw['referer']?.toString() ?? '').trim().isNotEmpty
        ? raw['referer']!.toString().trim()
        : (_baseUrlCache[pkg] ?? ExtensionService.instance.getExtensionByPkg(pkg)?.homeUrl ?? '');
    if (referer.isNotEmpty) {
      _baseUrlCache[pkg] = referer;
    }
    final cover = _normalizeUrl(raw['thumbnail_url']?.toString() ?? '', baseUrl: referer);
    final mangaId = 'ext:$pkg:${Uri.encodeComponent(url)}';
    if (cover.isNotEmpty) {
      ImageReferers.rememberResolvedCover(mangaId, cover);
      if (referer.isNotEmpty) {
        ImageReferers.registerSourceConfig(
          [cover],
          referer: referer,
          headers: _sourceHeadersCache[pkg],
          nativeLoader: _isAndroidSupported ? (u) => fetchImageBytes(pkg: pkg, url: u) : null,
          preferNative: _preferNativeImagesCache[pkg] ?? false,
        );
      }
    }
    final author = raw['author']?.toString() ?? '';
    final artist = raw['artist']?.toString() ?? '';
    final desc = raw['description']?.toString() ?? '';
    final genre = raw['genre']?.toString() ?? '';
    final statusInt = raw['status'] is int ? raw['status'] as int : 0;

    final authors = <String>[];
    if (author.isNotEmpty) authors.add(author);
    if (artist.isNotEmpty && artist != author) authors.add(artist);

    final tags = genre.isNotEmpty
        ? genre.split(',').map((g) => g.trim()).where((g) => g.isNotEmpty).toList()
        : const <String>[];

    String statusStr = 'ongoing';
    if (statusInt == 1) statusStr = 'ongoing';
    if (statusInt == 2) statusStr = 'completed';
    if (statusInt == 3) statusStr = 'licensed';
    if (statusInt == 5) statusStr = 'cancelled';
    if (statusInt == 6) statusStr = 'on_hiatus';

    // Intelligently infer comic type so Manhwa / Manhua are not mislabeled as Manga
    final combinedMeta = '$genre $url $title ${tags.join(' ')}'.toLowerCase();
    String detectedType = 'manga';
    if (combinedMeta.contains('manhwa') || combinedMeta.contains('webtoon') || combinedMeta.contains('korean')) {
      detectedType = 'manhwa';
    } else if (combinedMeta.contains('manhua') || combinedMeta.contains('chinese')) {
      detectedType = 'manhua';
    } else if (requestedType != null && requestedType != 'all') {
      detectedType = requestedType;
    }

    return MangaItem(
      id: mangaId,
      title: title,
      cover: cover,
      description: desc,
      authors: authors,
      tags: tags,
      status: statusStr,
      type: detectedType,
      source: pkg,
    );
  }

  ChapterItem _mapToChapterItem(String pkg, Map raw) {
    final url = raw['url']?.toString() ?? '';
    final name = raw['name']?.toString() ?? 'Chapter';
    final chapterNumVal = raw['chapter_number'];
    final double? chapterNum = chapterNumVal is num ? chapterNumVal.toDouble() : null;
    final dateUpload = raw['date_upload'] is num ? (raw['date_upload'] as num).toInt() : 0;
    final scanlator = raw['scanlator']?.toString() ?? '';

    String? numStr;
    if (chapterNum != null && chapterNum >= 0) {
      numStr = chapterNum % 1 == 0 ? chapterNum.toInt().toString() : chapterNum.toString();
    } else {
      final match = RegExp(r'(?:chapter|ch\.?|ep\.?|episode)\s*(\d+(?:\.\d+)?)', caseSensitive: false).firstMatch(name);
      if (match != null) {
        numStr = match.group(1);
      } else {
        final matchNum = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(name);
        if (matchNum != null) {
          numStr = matchNum.group(1);
        }
      }
    }

    String? publishAt;
    if (dateUpload > 0) {
      publishAt = DateTime.fromMillisecondsSinceEpoch(dateUpload).toIso8601String();
    }

    return ChapterItem(
      id: 'ext:$pkg:${Uri.encodeComponent(url)}',
      title: name,
      number: numStr,
      group: scanlator,
      publishAt: publishAt,
      source: pkg,
    );
  }
}
