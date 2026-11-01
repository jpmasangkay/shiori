import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga_models.dart';
import '../widgets/common.dart';
import 'api_service.dart';
import 'extension_bridge.dart';

enum DownloadStatus {
  notDownloaded,
  queued,
  downloading,
  downloaded,
  failed,
}

class DownloadTask {
  final MangaItem manga;
  final ChapterItem chapter;
  DownloadStatus status;
  double progress;
  int downloadedPages;
  int totalPages;
  String? error;

  DownloadTask({
    required this.manga,
    required this.chapter,
    this.status = DownloadStatus.queued,
    this.progress = 0.0,
    this.downloadedPages = 0,
    this.totalPages = 0,
    this.error,
  });
}

class DownloadedChapterInfo {
  final String chapterId;
  final String mangaId;
  final String mangaTitle;
  final String mangaCover;
  final String chapterTitle;
  final String? chapterNumber;
  final int pageCount;
  final int totalBytes;
  final DateTime downloadedAt;
  final String directoryPath;

  const DownloadedChapterInfo({
    required this.chapterId,
    required this.mangaId,
    required this.mangaTitle,
    required this.mangaCover,
    required this.chapterTitle,
    this.chapterNumber,
    required this.pageCount,
    required this.totalBytes,
    required this.downloadedAt,
    required this.directoryPath,
  });

  Map<String, dynamic> toJson() => {
        'chapterId': chapterId,
        'mangaId': mangaId,
        'mangaTitle': mangaTitle,
        'mangaCover': mangaCover,
        'chapterTitle': chapterTitle,
        'chapterNumber': chapterNumber,
        'pageCount': pageCount,
        'totalBytes': totalBytes,
        'downloadedAt': downloadedAt.toIso8601String(),
        'directoryPath': directoryPath,
      };

  factory DownloadedChapterInfo.fromJson(Map<String, dynamic> json) =>
      DownloadedChapterInfo(
        chapterId: json['chapterId'] as String? ?? '',
        mangaId: json['mangaId'] as String? ?? '',
        mangaTitle: json['mangaTitle'] as String? ?? 'Untitled',
        mangaCover: json['mangaCover'] as String? ?? '',
        chapterTitle: json['chapterTitle'] as String? ?? '',
        chapterNumber: json['chapterNumber']?.toString(),
        pageCount: (json['pageCount'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
        downloadedAt: json['downloadedAt'] != null
            ? DateTime.tryParse(json['downloadedAt'] as String) ?? DateTime.now()
            : DateTime.now(),
        directoryPath: json['directoryPath'] as String? ?? '',
      );
}

class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  static const String _manifestKey = 'shiori_downloads_manifest_v1';
  final Map<String, DownloadedChapterInfo> _downloadedManifest = {};
  final Map<String, DownloadTask> _activeTasks = {};
  final List<String> _queue = [];
  bool _isProcessing = false;
  Directory? _baseDownloadDir;

  Map<String, DownloadedChapterInfo> get downloadedChapters =>
      Map.unmodifiable(_downloadedManifest);

  List<DownloadTask> get activeTasks => _activeTasks.values.toList();

  Future<void> init() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      _baseDownloadDir = Directory('${docDir.path}/shiori_downloads');
      if (!await _baseDownloadDir!.exists()) {
        await _baseDownloadDir!.create(recursive: true);
      }

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_manifestKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          if (entry.value is Map<String, dynamic>) {
            _downloadedManifest[entry.key] =
                DownloadedChapterInfo.fromJson(entry.value as Map<String, dynamic>);
          }
        }
      }
      notifyListeners();
    } catch (e) {
      debugPrint('DownloadService init error: $e');
    }
  }

  Future<void> _persistManifest() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = <String, dynamic>{};
      for (final entry in _downloadedManifest.entries) {
        map[entry.key] = entry.value.toJson();
      }
      await prefs.setString(_manifestKey, jsonEncode(map));
    } catch (e) {
      debugPrint('DownloadService _persistManifest error: $e');
    }
  }

  String _sanitize(String text) {
    return text.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
  }

  bool isChapterDownloaded(String chapterId) {
    return _downloadedManifest.containsKey(chapterId);
  }

  DownloadStatus getStatus(String chapterId) {
    if (_downloadedManifest.containsKey(chapterId)) {
      return DownloadStatus.downloaded;
    }
    final task = _activeTasks[chapterId];
    if (task != null) {
      return task.status;
    }
    return DownloadStatus.notDownloaded;
  }

  double getProgress(String chapterId) {
    return _activeTasks[chapterId]?.progress ?? 0.0;
  }

  Future<List<File>> getDownloadedPages(String chapterId) async {
    final info = _downloadedManifest[chapterId];
    if (info == null) return const [];

    final dir = Directory(info.directoryPath);
    if (!await dir.exists()) return const [];

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jpg') || f.path.endsWith('.png') || f.path.endsWith('.webp'))
        .toList();

    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  Future<void> downloadChapter(MangaItem manga, ChapterItem chapter) async {
    if (isChapterDownloaded(chapter.id)) return;
    if (_activeTasks.containsKey(chapter.id)) return;

    final task = DownloadTask(manga: manga, chapter: chapter);
    _activeTasks[chapter.id] = task;
    _queue.add(chapter.id);
    notifyListeners();

    _processQueue();
  }

  Future<void> downloadChapters(MangaItem manga, List<ChapterItem> chapters) async {
    for (final chapter in chapters) {
      if (!isChapterDownloaded(chapter.id) && !_activeTasks.containsKey(chapter.id)) {
        final task = DownloadTask(manga: manga, chapter: chapter);
        _activeTasks[chapter.id] = task;
        _queue.add(chapter.id);
      }
    }
    notifyListeners();
    _processQueue();
  }

  void cancelDownload(String chapterId) {
    _queue.remove(chapterId);
    final task = _activeTasks.remove(chapterId);
    if (task != null) {
      task.status = DownloadStatus.failed;
      task.error = 'Cancelled by user';
    }
    notifyListeners();
  }

  Future<void> deleteDownloadedChapter(String chapterId) async {
    final info = _downloadedManifest.remove(chapterId);
    await _persistManifest();
    notifyListeners();

    if (info != null) {
      try {
        final dir = Directory(info.directoryPath);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (e) {
        debugPrint('Delete downloaded chapter error: $e');
      }
    }
  }

  Future<void> deleteMangaDownloads(String mangaId) async {
    final toRemove = _downloadedManifest.values
        .where((info) => info.mangaId == mangaId)
        .map((info) => info.chapterId)
        .toList();

    for (final chId in toRemove) {
      await deleteDownloadedChapter(chId);
    }
  }

  Future<void> deleteAllDownloads() async {
    _downloadedManifest.clear();
    await _persistManifest();
    notifyListeners();

    if (_baseDownloadDir != null && await _baseDownloadDir!.exists()) {
      try {
        await _baseDownloadDir!.delete(recursive: true);
        await _baseDownloadDir!.create(recursive: true);
      } catch (e) {
        debugPrint('Delete all downloads error: $e');
      }
    }
  }

  int getTotalDownloadSizeBytes() {
    var sum = 0;
    for (final info in _downloadedManifest.values) {
      sum += info.totalBytes;
    }
    return sum;
  }

  String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;

    while (_queue.isNotEmpty) {
      final chapterId = _queue.removeAt(0);
      final task = _activeTasks[chapterId];
      if (task == null) continue;

      task.status = DownloadStatus.downloading;
      notifyListeners();

      try {
        await _executeDownloadTask(task);
        task.status = DownloadStatus.downloaded;
      } catch (e) {
        debugPrint('Error downloading chapter ${task.chapter.id}: $e');
        task.status = DownloadStatus.failed;
        task.error = e.toString();
      }

      _activeTasks.remove(chapterId);
      notifyListeners();
    }

    _isProcessing = false;
  }

  Future<(Uint8List?, int?)> _downloadImageBytes(
    String candidate, {
    String? extPkg,
    String? chapterPageUrl,
  }) async {
    int? lastStatus;

    Future<Uint8List?> tryNative() async {
      final viaReferers = await ImageReferers.fetchNativeBytes(candidate);
      if (viaReferers != null && viaReferers.isNotEmpty) return viaReferers;
      if (extPkg != null && extPkg.isNotEmpty) {
        return ExtensionBridge.instance.fetchImageBytes(
          pkg: extPkg,
          url: candidate,
          pageUrl: chapterPageUrl,
        );
      }
      return null;
    }

    final preferNative = ImageReferers.prefersNative(candidate);
    if (preferNative) {
      final nativeBytes = await tryNative();
      if (nativeBytes != null && nativeBytes.isNotEmpty) {
        return (nativeBytes, 200);
      }
    }

    final variants = imageHeaderVariants(candidate);
    for (final headers in variants) {
      try {
        final response = await http
            .get(Uri.parse(candidate), headers: headers)
            .timeout(const Duration(seconds: 20));
        lastStatus = response.statusCode;
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          return (response.bodyBytes, 200);
        }
      } catch (_) {}
    }

    if (!preferNative && (ImageReferers.hasNativeLoader(candidate) || (extPkg != null && extPkg.isNotEmpty))) {
      final nativeBytes = await tryNative();
      if (nativeBytes != null && nativeBytes.isNotEmpty) {
        return (nativeBytes, 200);
      }
    }

    return (null, lastStatus);
  }

  Future<void> _executeDownloadTask(DownloadTask task) async {
    if (_baseDownloadDir == null) {
      final docDir = await getApplicationDocumentsDirectory();
      _baseDownloadDir = Directory('${docDir.path}/shiori_downloads');
    }

    final safeMangaId = _sanitize(task.manga.id);
    final safeChapterId = _sanitize(task.chapter.id);
    final mangaDir = Directory('${_baseDownloadDir!.path}/$safeMangaId');
    final chapterDir = Directory('${mangaDir.path}/$safeChapterId');
    if (!await chapterDir.exists()) {
      await chapterDir.create(recursive: true);
    }

    String? extPkg;
    String? rawChapterUrl;
    if (task.chapter.id.startsWith('ext:')) {
      final parts = task.chapter.id.split(':');
      if (parts.length >= 3) {
        extPkg = parts[1];
        rawChapterUrl = Uri.decodeComponent(parts.sublist(2).join(':'));
      }
    } else if (task.manga.id.startsWith('ext:')) {
      final parts = task.manga.id.split(':');
      if (parts.length >= 2) {
        extPkg = parts[1];
      }
    }

    // Ensure offline cover is resolved and persisted locally into `cover.jpg`
    String effectiveCover = task.manga.cover.trim();
    if (effectiveCover.isEmpty) {
      try {
        final details = await ApiService.instance.getManga(task.manga.id);
        if (details.cover.trim().isNotEmpty) {
          effectiveCover = details.cover.trim();
        }
      } catch (_) {}
    }
    final localCoverFile = File('${mangaDir.path}/cover.jpg');
    if (await localCoverFile.exists() && await localCoverFile.length() > 0) {
      effectiveCover = 'file://${localCoverFile.path}';
    } else if (effectiveCover.startsWith('http')) {
      try {
        final (coverBytes, _) = await _downloadImageBytes(effectiveCover, extPkg: extPkg);
        if (coverBytes != null && coverBytes.isNotEmpty) {
          await localCoverFile.writeAsBytes(coverBytes);
          effectiveCover = 'file://${localCoverFile.path}';
        }
      } catch (_) {}
    }

    // 1. Fetch pages list
    final pagesRes = await ApiService.instance.getChapterPages(task.chapter.id, forceRefresh: true);
    final pageUrls = pagesRes.pages;
    if (pageUrls.isEmpty) {
      throw Exception('No pages available for download');
    }

    task.totalPages = pageUrls.length;
    task.downloadedPages = 0;
    task.progress = 0.0;
    notifyListeners();

    var totalBytes = 0;

    // 2. Download each page sequentially with header, native OkHttp & fallback-URL retries
    for (var i = 0; i < pageUrls.length; i++) {
      final url = pageUrls[i];
      final fallbackUrl = (i < pagesRes.dataSaver.length && pagesRes.dataSaver[i] != url)
          ? pagesRes.dataSaver[i]
          : null;
      final candidateUrls = <String>[
        url,
        if (fallbackUrl != null && fallbackUrl.isNotEmpty) fallbackUrl,
      ];

      final ext = _extractExtension(url);
      final pageFileName = 'page_${(i + 1).toString().padLeft(4, '0')}.$ext';
      final pageFile = File('${chapterDir.path}/$pageFileName');

      if (!await pageFile.exists() || await pageFile.length() == 0) {
        Uint8List? downloadedBytes;
        int? lastStatus;

        for (final candidate in candidateUrls) {
          final (bytes, status) = await _downloadImageBytes(
            candidate,
            extPkg: extPkg,
            chapterPageUrl: rawChapterUrl,
          );
          if (status != null) lastStatus = status;
          if (bytes != null && bytes.isNotEmpty) {
            downloadedBytes = bytes;
            break;
          }
        }

        if (downloadedBytes == null) {
          throw Exception(
            'Failed to download page ${i + 1}${lastStatus != null ? ' (HTTP $lastStatus)' : ''}',
          );
        }

        await pageFile.writeAsBytes(downloadedBytes);
        totalBytes += downloadedBytes.length;
      } else {
        totalBytes += await pageFile.length();
      }

      task.downloadedPages = i + 1;
      task.progress = (i + 1) / pageUrls.length;
      notifyListeners();
    }

    // 3. Register into manifest
    final info = DownloadedChapterInfo(
      chapterId: task.chapter.id,
      mangaId: task.manga.id,
      mangaTitle: task.manga.title,
      mangaCover: effectiveCover,
      chapterTitle: task.chapter.displayTitle,
      chapterNumber: task.chapter.number,
      pageCount: pageUrls.length,
      totalBytes: totalBytes,
      downloadedAt: DateTime.now(),
      directoryPath: chapterDir.path,
    );

    _downloadedManifest[task.chapter.id] = info;
    await _persistManifest();
  }

  String _extractExtension(String url) {
    try {
      final uri = Uri.parse(url);
      final lastSegment = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
      if (lastSegment.contains('.')) {
        final ext = lastSegment.split('.').last.toLowerCase();
        if (['jpg', 'jpeg', 'png', 'webp', 'gif'].contains(ext)) {
          return ext;
        }
      }
    } catch (_) {}
    return 'jpg';
  }
}
