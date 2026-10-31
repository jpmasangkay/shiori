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

  String? _findApkPath(String pkg) {
    try {
      final cleanName = pkg.replaceAll(RegExp(r'[^a-zA-Z0-9_\.]'), '_');
      final f1 = File('${Directory.systemTemp.path}/shiori_extensions/$cleanName.apk');
      if (f1.existsSync() && f1.lengthSync() > 0) {
        return f1.path;
      }
      final f2 = File('${Directory.systemTemp.path}/shiori_extensions/$pkg.apk');
      if (f2.existsSync() && f2.lengthSync() > 0) {
        return f2.path;
      }
    } catch (_) {}
    return null;
  }

  Future<void> openInWebView({required String url, String? title}) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openInWebView', {
        'url': url,
        'title': title ?? '',
      });
    } catch (e) {
      debugPrint('ExtensionBridge openInWebView error: $e');
    }
  }

  Future<String?> getSourceBaseUrl({required String pkg}) async {
    final cached = _baseUrlCache[pkg];
    if (cached != null && cached.isNotEmpty) return cached;
    if (!Platform.isAndroid) return null;
    try {
      final apkPath = _findApkPath(pkg);
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

  Future<List<MangaItem>> fetchPopularManga({
    required String pkg,
    int page = 1,
    String? type,
  }) async {
    if (!Platform.isAndroid) return [];
    try {
      final apkPath = _findApkPath(pkg);
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
      return rawList.map((item) => _mapToMangaItem(pkg, item as Map, requestedType: type)).toList();
    } catch (e) {
      debugPrint('ExtensionBridge fetchPopularManga error ($pkg): $e');
      rethrow;
    }
  }

  Future<List<MangaItem>> searchManga({
    required String pkg,
    required String query,
    int page = 1,
    String? type,
  }) async {
    if (!Platform.isAndroid) return [];
    try {
      final apkPath = _findApkPath(pkg);
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
      return rawList.map((item) => _mapToMangaItem(pkg, item as Map, requestedType: type)).toList();
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
    if (!Platform.isAndroid) {
      throw UnsupportedError('Extensions are only supported on Android');
    }
    try {
      final apkPath = _findApkPath(pkg);
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

      return _mapToMangaItem(pkg, raw, fallbackUrl: url, fallbackTitle: title);
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
    if (!Platform.isAndroid) return [];
    try {
      final apkPath = _findApkPath(pkg);
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
    if (!Platform.isAndroid) return [];
    try {
      final apkPath = _findApkPath(pkg);
      final rawList = await _channel.invokeMethod<List<dynamic>>(
        'fetchPageList',
        {
          'pkg': pkg,
          'chapterUrl': chapterUrl,
          'apkPath': apkPath,
        },
      );

      if (rawList == null) return [];
      final pages = rawList
          .map((e) => _normalizeUrl(e.toString()))
          .where((u) => u.isNotEmpty)
          .toList();
      if (pages.isNotEmpty) {
        final referer = _baseUrlCache[pkg] ??
            await getSourceBaseUrl(pkg: pkg) ??
            ExtensionService.instance.getExtensionByPkg(pkg)?.homeUrl ??
            '';
        if (referer.isNotEmpty) {
          ImageReferers.registerAll(pages, referer);
        }
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
    if (u.startsWith('//')) u = 'https:$u';
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      if (baseUrl != null && baseUrl.startsWith('http')) {
        final cleanBase = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
        u = u.startsWith('/') ? '$cleanBase$u' : '$cleanBase/$u';
      }
    }
    if (u.contains(' ')) u = u.replaceAll(' ', '%20');
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
    if (cover.isNotEmpty && referer.isNotEmpty) {
      ImageReferers.register(cover, referer);
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
      id: 'ext:$pkg:${Uri.encodeComponent(url)}',
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
