import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:manga_reader/models/manga_models.dart';

class TachibkBackupData {
  final List<MangaItem> library;
  final List<CategoryItem> categories;
  final Map<String, List<String>> mangaCategories;
  final Map<String, List<String>> readChapters;
  final List<String> chapterBookmarks;

  const TachibkBackupData({
    required this.library,
    required this.categories,
    required this.mangaCategories,
    required this.readChapters,
    required this.chapterBookmarks,
  });
}

/// Zero-dependency Protobuf wire codec for Mihon / Tachiyomi `.tachibk` backups
/// (`application/x-protobuf+gzip`) plus gzipped Shiori JSON backup support.
class TachibkBackupService {
  const TachibkBackupService._();

  static const int _maxPayloadBytes = 64 * 1024 * 1024; // 64 MB guard

  static bool isGzipped(Uint8List bytes) =>
      bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B;

  /// Encodes Shiori library + categories + read states into a Mihon-compatible
  /// gzipped `.tachibk` protobuf payload.
  static Uint8List encodeTachibk({
    required List<MangaItem> library,
    required List<CategoryItem> categories,
    required Map<String, List<String>> mangaCategories,
    required Map<String, Set<String>> readChapters,
    required Set<String> chapterBookmarks,
  }) {
    final catIndexById = <String, int>{};
    for (var i = 0; i < categories.length; i++) {
      catIndexById[categories[i].id] = i;
    }

    final root = _ProtoWriter();

    // Field 1: repeated BackupManga
    for (final m in library) {
      final mw = _ProtoWriter();
      mw.writeVarintField(1, _hashSourceId(m.source));
      mw.writeStringField(2, m.id);
      mw.writeStringField(3, m.title);
      if (m.authors.isNotEmpty) mw.writeStringField(5, m.authors.join(', '));
      if (m.description.isNotEmpty) mw.writeStringField(6, m.description);
      for (final g in m.tags) {
        mw.writeStringField(7, g);
      }
      mw.writeVarintField(8, _statusToInt(m.status));
      if (m.cover.isNotEmpty) mw.writeStringField(9, m.cover);

      // Field 16: repeated BackupChapter (read/bookmarked chapters)
      final readIds = readChapters[m.id] ?? const <String>{};
      for (final chId in readIds) {
        final cw = _ProtoWriter();
        cw.writeStringField(1, chId);
        cw.writeStringField(2, chId);
        cw.writeBoolField(4, true);
        if (chapterBookmarks.contains(chId)) {
          cw.writeBoolField(5, true);
        }
        mw.writeBytesField(16, cw.toBytes());
      }

      // Field 17: repeated int64 categories (order index)
      final assigned = mangaCategories[m.id] ?? const <String>[];
      for (final cid in assigned) {
        final idx = catIndexById[cid];
        if (idx != null) {
          mw.writeVarintField(17, idx);
        }
      }

      root.writeBytesField(1, mw.toBytes());
    }

    // Field 2: repeated BackupCategory
    for (var i = 0; i < categories.length; i++) {
      final cat = categories[i];
      final cw = _ProtoWriter();
      cw.writeStringField(1, cat.name);
      cw.writeVarintField(2, i);
      root.writeBytesField(2, cw.toBytes());
    }

    return Uint8List.fromList(gzip.encode(root.toBytes()));
  }

  /// Decodes a Mihon / Tachiyomi `.tachibk` (or raw uncompressed protobuf) payload.
  static TachibkBackupData decodeTachibk(Uint8List rawBytes) {
    final bytes = isGzipped(rawBytes)
        ? Uint8List.fromList(gzip.decode(rawBytes))
        : rawBytes;
    if (bytes.length > _maxPayloadBytes) {
      throw const FormatException('Backup file exceeds 64 MB safety limit');
    }

    final categories = <CategoryItem>[];
    final rawMangas = <_ParsedTachibkManga>[];

    final reader = _ProtoReader(bytes);
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      if (tag == null) break;
      final (fieldNum, wireType) = tag;
      if (fieldNum == 1 && wireType == 2) {
        final sub = reader.readBytes();
        final parsed = _parseBackupManga(sub);
        if (parsed != null) rawMangas.add(parsed);
      } else if (fieldNum == 2 && wireType == 2) {
        final sub = reader.readBytes();
        final cat = _parseBackupCategory(sub, categories.length);
        if (cat != null) categories.add(cat);
      } else {
        reader.skipField(wireType);
      }
    }

    final catByOrder = <int, CategoryItem>{
      for (var i = 0; i < categories.length; i++) categories[i].order: categories[i],
    };

    final library = <MangaItem>[];
    final mangaCategories = <String, List<String>>{};
    final readChapters = <String, List<String>>{};
    final chapterBookmarks = <String>[];

    for (final pm in rawMangas) {
      library.add(pm.manga);
      if (pm.categoryOrders.isNotEmpty) {
        final ids = <String>[];
        for (final ord in pm.categoryOrders) {
          final match = catByOrder[ord] ??
              (ord >= 0 && ord < categories.length ? categories[ord] : null);
          if (match != null) ids.add(match.id);
        }
        if (ids.isNotEmpty) mangaCategories[pm.manga.id] = ids;
      }
      if (pm.readChapterIds.isNotEmpty) {
        readChapters[pm.manga.id] = pm.readChapterIds;
      }
      chapterBookmarks.addAll(pm.bookmarkedChapterIds);
    }

    return TachibkBackupData(
      library: library,
      categories: categories,
      mangaCategories: mangaCategories,
      readChapters: readChapters,
      chapterBookmarks: chapterBookmarks,
    );
  }

  static CategoryItem? _parseBackupCategory(Uint8List bytes, int index) {
    final r = _ProtoReader(bytes);
    var name = '';
    var order = index;
    while (!r.isAtEnd) {
      final tag = r.readTag();
      if (tag == null) break;
      final (fieldNum, wireType) = tag;
      if (fieldNum == 1 && wireType == 2) {
        name = r.readString();
      } else if (fieldNum == 2 && wireType == 0) {
        order = r.readVarint();
      } else {
        r.skipField(wireType);
      }
    }
    if (name.trim().isEmpty) return null;
    final cleanSlug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    return CategoryItem(id: 'tachibk_${cleanSlug}_$order', name: name.trim(), order: order);
  }

  static _ParsedTachibkManga? _parseBackupManga(Uint8List bytes) {
    final r = _ProtoReader(bytes);
    var sourceId = 0;
    var url = '';
    var title = '';
    var author = '';
    var artist = '';
    var description = '';
    final genres = <String>[];
    var statusInt = 0;
    var cover = '';
    final catOrders = <int>[];
    final readChapterIds = <String>[];
    final bookmarkedChapterIds = <String>[];

    while (!r.isAtEnd) {
      final tag = r.readTag();
      if (tag == null) break;
      final (fieldNum, wireType) = tag;
      switch (fieldNum) {
        case 1 when wireType == 0:
          sourceId = r.readVarint();
        case 2 when wireType == 2:
          url = r.readString();
        case 3 when wireType == 2:
          title = r.readString();
        case 4 when wireType == 2:
          artist = r.readString();
        case 5 when wireType == 2:
          author = r.readString();
        case 6 when wireType == 2:
          description = r.readString();
        case 7 when wireType == 2:
          final g = r.readString().trim();
          if (g.isNotEmpty) genres.add(g);
        case 8 when wireType == 0:
          statusInt = r.readVarint();
        case 9 when wireType == 2:
          cover = r.readString();
        case 16 when wireType == 2:
          final ch = _parseBackupChapter(r.readBytes());
          if (ch != null) {
            if (ch.read) readChapterIds.add(ch.url);
            if (ch.bookmark) bookmarkedChapterIds.add(ch.url);
          }
        case 17 when wireType == 0:
          catOrders.add(r.readVarint());
        case 17 when wireType == 2:
          // Packed repeated int64 categories
          final packed = _ProtoReader(r.readBytes());
          while (!packed.isAtEnd) {
            catOrders.add(packed.readVarint());
          }
        default:
          r.skipField(wireType);
      }
    }

    if (title.trim().isEmpty && url.trim().isEmpty) return null;

    // Preserve Shiori IDs verbatim if already prefixed; otherwise build stable tachibk ID
    final mangaId = (url.contains(':') && !url.startsWith('http'))
        ? url
        : 'tachibk:$sourceId:${Uri.encodeComponent(url.isNotEmpty ? url : title)}';

    final authors = <String>[
      if (author.trim().isNotEmpty) author.trim(),
      if (artist.trim().isNotEmpty && artist.trim() != author.trim()) artist.trim(),
    ];

    final lowerGenres = genres.map((g) => g.toLowerCase()).toSet();
    final type = lowerGenres.contains('manhwa') || lowerGenres.contains('webtoon')
        ? 'manhwa'
        : (lowerGenres.contains('manhua') ? 'manhua' : 'manga');

    final manga = MangaItem(
      id: mangaId,
      title: title.trim().isNotEmpty ? title.trim() : url,
      description: description,
      cover: cover,
      authors: authors,
      tags: genres,
      status: _intToStatus(statusInt),
      type: type,
      source: url.startsWith('ext:') ? url.split(':')[1] : 'tachibk_$sourceId',
    );

    return _ParsedTachibkManga(
      manga: manga,
      categoryOrders: catOrders,
      readChapterIds: readChapterIds,
      bookmarkedChapterIds: bookmarkedChapterIds,
    );
  }

  static ({String url, bool read, bool bookmark})? _parseBackupChapter(Uint8List bytes) {
    final r = _ProtoReader(bytes);
    var url = '';
    var read = false;
    var bookmark = false;
    while (!r.isAtEnd) {
      final tag = r.readTag();
      if (tag == null) break;
      final (fieldNum, wireType) = tag;
      if (fieldNum == 1 && wireType == 2) {
        url = r.readString();
      } else if (fieldNum == 4 && wireType == 0) {
        read = r.readVarint() != 0;
      } else if (fieldNum == 5 && wireType == 0) {
        bookmark = r.readVarint() != 0;
      } else {
        r.skipField(wireType);
      }
    }
    if (url.isEmpty) return null;
    return (url: url, read: read, bookmark: bookmark);
  }

  static int _hashSourceId(String source) {
    var h = 1125899906842597;
    for (final unit in source.codeUnits) {
      h = (h * 31 + unit) & 0x7FFFFFFFFFFFFFFF;
    }
    return h;
  }

  static int _statusToInt(String status) {
    final s = status.toLowerCase();
    if (s.contains('ongoing')) return 1;
    if (s.contains('completed')) return 2;
    if (s.contains('licensed')) return 3;
    if (s.contains('cancel')) return 5;
    if (s.contains('hiatus')) return 6;
    return 0;
  }

  static String _intToStatus(int s) => switch (s) {
    1 => 'Ongoing',
    2 => 'Completed',
    3 => 'Licensed',
    4 => 'Publishing Finished',
    5 => 'Cancelled',
    6 => 'On Hiatus',
    _ => '',
  };
}

class _ParsedTachibkManga {
  final MangaItem manga;
  final List<int> categoryOrders;
  final List<String> readChapterIds;
  final List<String> bookmarkedChapterIds;

  _ParsedTachibkManga({
    required this.manga,
    required this.categoryOrders,
    required this.readChapterIds,
    required this.bookmarkedChapterIds,
  });
}

class _ProtoWriter {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  void _writeVarint(int value) {
    var v = value;
    for (var i = 0; i < 10; i++) {
      final byte = v & 0x7F;
      v = v >>> 7;
      if (v == 0) {
        _buf.addByte(byte);
        return;
      }
      _buf.addByte(byte | 0x80);
    }
  }

  void writeVarintField(int fieldNum, int value) {
    if (value == 0) return;
    _writeVarint((fieldNum << 3) | 0);
    _writeVarint(value);
  }

  void writeBoolField(int fieldNum, bool value) {
    if (!value) return;
    _writeVarint((fieldNum << 3) | 0);
    _buf.addByte(1);
  }

  void writeBytesField(int fieldNum, Uint8List bytes) {
    if (bytes.isEmpty) return;
    _writeVarint((fieldNum << 3) | 2);
    _writeVarint(bytes.length);
    _buf.add(bytes);
  }

  void writeStringField(int fieldNum, String value) {
    if (value.isEmpty) return;
    final encoded = Uint8List.fromList(utf8.encode(value));
    writeBytesField(fieldNum, encoded);
  }

  Uint8List toBytes() => _buf.toBytes();
}

class _ProtoReader {
  final Uint8List _bytes;
  int _pos = 0;

  _ProtoReader(this._bytes);

  bool get isAtEnd => _pos >= _bytes.length;

  (int, int)? readTag() {
    if (isAtEnd) return null;
    final key = readVarint();
    return (key >>> 3, key & 0x07);
  }

  int readVarint() {
    var result = 0;
    var shift = 0;
    for (var i = 0; i < 10 && _pos < _bytes.length; i++) {
      final b = _bytes[_pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
    }
    return result;
  }

  Uint8List readBytes() {
    final len = readVarint();
    if (len <= 0 || _pos + len > _bytes.length) {
      _pos = _bytes.length;
      return Uint8List(0);
    }
    final slice = Uint8List.sublistView(_bytes, _pos, _pos + len);
    _pos += len;
    return slice;
  }

  String readString() {
    return utf8.decode(readBytes(), allowMalformed: true);
  }

  void skipField(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
      case 1:
        _pos = (_pos + 8).clamp(0, _bytes.length);
      case 2:
        final len = readVarint();
        _pos = (_pos + len).clamp(0, _bytes.length);
      case 5:
        _pos = (_pos + 4).clamp(0, _bytes.length);
      default:
        _pos = _bytes.length;
    }
  }
}
