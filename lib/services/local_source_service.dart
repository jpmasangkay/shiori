import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Offline Local Source supporting Mihon-compatible directory layout:
/// `<appDocs>/shiori_local_manga/<Series Title>/` containing:
/// - optional `cover.jpg` / `cover.png` / `cover.webp`
/// - optional `details.json` (`title`, `author`, `artist`, `description`, `genre`, `status`)
/// - `.cbz` / `.zip` chapter archives or chapter image subdirectories.
class LocalSourceService {
  LocalSourceService._();
  static final LocalSourceService instance = LocalSourceService._();

  static const Set<String> _imageExts = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};
  static const int _maxExtractedPages = 1500;

  Directory? _overrideRootDir;

  @visibleForTesting
  void setRootDirForTesting(Directory? dir) {
    _overrideRootDir = dir;
  }

  Future<Directory> getRootDir() async {
    if (_overrideRootDir != null) {
      if (!await _overrideRootDir!.exists()) {
        await _overrideRootDir!.create(recursive: true);
      }
      return _overrideRootDir!;
    }
    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docDir.path, 'shiori_local_manga'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final nomedia = File(p.join(dir.path, '.nomedia'));
    if (!await nomedia.exists()) {
      try {
        await nomedia.create();
      } catch (_) {}
    }
    return dir;
  }

  /// Imports a `.cbz` or `.zip` file into the local library under [seriesTitle]
  /// (defaults to filename without extension) and returns the created [MangaItem].
  Future<MangaItem> importCbzArchive({
    required String fileName,
    required Uint8List bytes,
    String? seriesTitle,
  }) async {
    final root = await getRootDir();
    final baseName = p.basenameWithoutExtension(fileName).trim();
    final safeSeries = (seriesTitle != null && seriesTitle.trim().isNotEmpty
            ? seriesTitle.trim()
            : baseName.isNotEmpty
                ? baseName
                : 'Imported Comic')
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

    final seriesDir = Directory(p.join(root.path, safeSeries));
    if (!await seriesDir.exists()) {
      await seriesDir.create(recursive: true);
    }

    final cleanFile = fileName.toLowerCase().endsWith('.cbz') ||
            fileName.toLowerCase().endsWith('.zip')
        ? p.basename(fileName)
        : '$safeSeries.cbz';
    final destFile = File(p.join(seriesDir.path, cleanFile));
    await destFile.writeAsBytes(bytes, flush: true);

    // Extract first image as cover.jpg if no cover exists yet
    final existingCover = await _findCoverFile(seriesDir);
    if (existingCover == null) {
      try {
        final archive = ZipDecoder().decodeBytes(bytes);
        final imgEntries = archive.files
            .where((f) => f.isFile && _isImageName(f.name))
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        if (imgEntries.isNotEmpty) {
          final first = imgEntries.first;
          final ext = p.extension(first.name).toLowerCase();
          final coverFile = File(p.join(seriesDir.path, 'cover${ext.isEmpty ? '.jpg' : ext}'));
          await coverFile.writeAsBytes(first.content as List<int>, flush: true);
        }
      } catch (e) {
        AppLogger.warn('LocalSourceService cover extraction warning', e);
      }
    }

    return _buildMangaItem(seriesDir);
  }

  Future<List<MangaItem>> listSeries({String? query}) async {
    if (kIsWeb) return const [];
    final root = await getRootDir();
    final q = query?.trim().toLowerCase() ?? '';
    final items = <MangaItem>[];

    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      final item = await _buildMangaItem(entity);
      if (q.isEmpty ||
          item.title.toLowerCase().contains(q) ||
          item.tags.any((t) => t.toLowerCase().contains(q))) {
        items.add(item);
      }
    }

    items.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return items;
  }

  Future<MangaItem?> getSeries(String localMangaId) async {
    final slug = _stripLocalPrefix(localMangaId);
    final root = await getRootDir();
    final dir = Directory(p.join(root.path, slug));
    if (!await dir.exists()) return null;
    return _buildMangaItem(dir);
  }

  Future<List<ChapterItem>> getChapters(String localMangaId) async {
    final slug = _stripLocalPrefix(localMangaId);
    final root = await getRootDir();
    final dir = Directory(p.join(root.path, slug));
    if (!await dir.exists()) return const [];

    final chapters = <ChapterItem>[];
    await for (final entity in dir.list()) {
      final base = p.basename(entity.path);
      if (base.startsWith('.')) continue;

      if (entity is File) {
        final ext = p.extension(base).toLowerCase();
        if (ext == '.cbz' || ext == '.zip') {
          final chName = p.basenameWithoutExtension(base);
          final chNum = _extractChapterNumber(chName);
          final stat = await entity.stat();
          chapters.add(
            ChapterItem(
              id: 'local:$slug::${Uri.encodeComponent(base)}',
              number: chNum,
              title: chName,
              publishAt: stat.modified.toIso8601String(),
              group: 'Local Archive',
              source: 'local',
            ),
          );
        }
      } else if (entity is Directory) {
        final chNum = _extractChapterNumber(base);
        final stat = await entity.stat();
        chapters.add(
          ChapterItem(
            id: 'local:$slug::${Uri.encodeComponent(base)}',
            number: chNum,
            title: base,
            publishAt: stat.modified.toIso8601String(),
            group: 'Local Folder',
            source: 'local',
          ),
        );
      }
    }

    chapters.sort((a, b) {
      final na = double.tryParse(a.number ?? '');
      final nb = double.tryParse(b.number ?? '');
      if (na != null && nb != null) return nb.compareTo(na);
      return b.title.compareTo(a.title);
    });
    return chapters;
  }

  Future<ChapterPages> getChapterPages(String localChapterId) async {
    final raw = _stripLocalPrefix(localChapterId);
    final sepIdx = raw.indexOf('::');
    if (sepIdx <= 0) {
      return ChapterPages(chapterId: localChapterId, pages: const []);
    }
    final seriesSlug = raw.substring(0, sepIdx);
    final entryName = Uri.decodeComponent(raw.substring(sepIdx + 2));

    // Reject path traversal
    if (seriesSlug.contains('..') || entryName.contains('..')) {
      throw SecurityException('Invalid local path');
    }

    final root = await getRootDir();
    final targetPath = p.join(root.path, seriesSlug, entryName);

    final targetDir = Directory(targetPath);
    if (await targetDir.exists()) {
      final imgs = <File>[];
      await for (final f in targetDir.list()) {
        if (f is File && _isImageName(f.path)) {
          imgs.add(f);
        }
      }
      imgs.sort((a, b) => a.path.compareTo(b.path));
      return ChapterPages(
        chapterId: localChapterId,
        pages: imgs.take(_maxExtractedPages).map((f) => 'file://${f.path}').toList(),
      );
    }

    final targetFile = File(targetPath);
    if (await targetFile.exists()) {
      final cacheBase = _overrideRootDir ?? await getTemporaryDirectory();
      final extractDir = Directory(
        p.join(cacheBase.path, '.cbz_cache', '${seriesSlug}_${entryName.hashCode.abs()}'),
      );
      if (!await extractDir.exists()) {
        await extractDir.create(recursive: true);
        final bytes = await targetFile.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        final imgEntries = archive.files
            .where((f) => f.isFile && _isImageName(f.name) && !f.name.contains('__MACOSX'))
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));

        var count = 0;
        for (final entry in imgEntries) {
          if (count >= _maxExtractedPages) break;
          final ext = p.extension(entry.name).toLowerCase();
          final outName = '${count.toString().padLeft(4, '0')}${ext.isEmpty ? '.jpg' : ext}';
          final outFile = File(p.join(extractDir.path, outName));
          await outFile.writeAsBytes(entry.content as List<int>, flush: true);
          count++;
        }
      }

      final extracted = <File>[];
      await for (final f in extractDir.list()) {
        if (f is File && _isImageName(f.path)) extracted.add(f);
      }
      extracted.sort((a, b) => a.path.compareTo(b.path));
      return ChapterPages(
        chapterId: localChapterId,
        pages: extracted.map((f) => 'file://${f.path}').toList(),
      );
    }

    return ChapterPages(chapterId: localChapterId, pages: const []);
  }

  Future<MangaItem> _buildMangaItem(Directory seriesDir) async {
    final slug = p.basename(seriesDir.path);
    var title = slug;
    var description = 'Local comic folder / CBZ archive';
    var authors = const <String>[];
    var tags = const <String>['Local'];
    var status = 'Unknown';

    final detailsFile = File(p.join(seriesDir.path, 'details.json'));
    if (await detailsFile.exists()) {
      try {
        final raw = jsonDecode(await detailsFile.readAsString()) as Map<String, dynamic>;
        if (raw['title'] is String && (raw['title'] as String).trim().isNotEmpty) {
          title = (raw['title'] as String).trim();
        }
        if (raw['description'] is String) description = raw['description'] as String;
        if (raw['author'] is String && (raw['author'] as String).isNotEmpty) {
          authors = [raw['author'] as String];
        }
        if (raw['genre'] is List) {
          tags = (raw['genre'] as List).map((e) => e.toString()).toList();
        }
        if (raw['status'] is String) status = raw['status'] as String;
      } catch (_) {}
    }

    final coverFile = await _findCoverFile(seriesDir);
    return MangaItem(
      id: 'local:$slug',
      title: title,
      description: description,
      cover: coverFile != null ? 'file://${coverFile.path}' : '',
      authors: authors,
      tags: tags,
      status: status,
      type: 'manga',
      source: 'local',
    );
  }

  Future<File?> _findCoverFile(Directory dir) async {
    for (final name in const ['cover.jpg', 'cover.jpeg', 'cover.png', 'cover.webp']) {
      final f = File(p.join(dir.path, name));
      if (await f.exists()) return f;
    }
    return null;
  }

  bool _isImageName(String pathStr) {
    return _imageExts.contains(p.extension(pathStr).toLowerCase());
  }

  String _stripLocalPrefix(String id) {
    return id.startsWith('local:') ? id.substring(6) : id;
  }

  String? _extractChapterNumber(String name) {
    final match = RegExp(r'(?:ch(?:apter)?\.?\s*|#)?(\d+(?:\.\d+)?)', caseSensitive: false)
        .firstMatch(name);
    return match?.group(1);
  }
}

class SecurityException implements Exception {
  final String message;
  SecurityException(this.message);
  @override
  String toString() => 'SecurityException: $message';
}
