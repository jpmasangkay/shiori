import 'package:manga_reader/services/source_resolver.dart';

class MangaItem {
  final String id;
  final String title;
  final String description;
  final String cover;
  final List<String> authors;
  final String status;
  final String type; // 'manga', 'manhwa', 'manhua'
  final List<String> tags;
  final String? year;
  final String? lastChapter;
  final String source; // 'mangadex', 'asura', etc.

  const MangaItem({
    required this.id,
    required this.title,
    this.description = '',
    this.cover = '',
    this.authors = const [],
    this.status = '',
    this.type = 'manga',
    this.tags = const [],
    this.year,
    this.lastChapter,
    this.source = 'mangadex',
  });

  factory MangaItem.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    return MangaItem(
      id: id,
      title: json['title'] as String? ?? 'Untitled',
      description: json['description'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      authors: (json['authors'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
      status: json['status'] as String? ?? '',
      type: json['type'] as String? ?? 'manga',
      tags: (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
      year: json['year']?.toString(),
      lastChapter: json['lastChapter']?.toString(),
      source: SourceResolver.resolve(id, json['source'] as String?),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'cover': cover,
        'authors': authors,
        'status': status,
        'type': type,
        'tags': tags,
        'year': year,
        'lastChapter': lastChapter,
        'source': source,
      };

  MangaItem copyWith({
    String? id,
    String? title,
    String? description,
    String? cover,
    List<String>? authors,
    String? status,
    String? type,
    List<String>? tags,
    String? year,
    String? lastChapter,
    String? source,
  }) {
    return MangaItem(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      cover: cover ?? this.cover,
      authors: authors ?? this.authors,
      status: status ?? this.status,
      type: type ?? this.type,
      tags: tags ?? this.tags,
      year: year ?? this.year,
      lastChapter: lastChapter ?? this.lastChapter,
      source: source ?? this.source,
    );
  }
}

class ChapterItem {
  final String id;
  final String? number;
  final String? volume;
  final String title;
  final int pages;
  final String group;
  final String? publishAt;
  final String source;

  const ChapterItem({
    required this.id,
    this.number,
    this.volume,
    this.title = '',
    this.pages = 0,
    this.group = '',
    this.publishAt,
    this.source = 'mangadex',
  });

  factory ChapterItem.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    return ChapterItem(
      id: id,
      number: json['number']?.toString(),
      volume: json['volume']?.toString(),
      title: json['title'] as String? ?? '',
      pages: (json['pages'] as num?)?.toInt() ?? 0,
      group: json['group'] as String? ?? '',
      publishAt: json['publishAt'] as String?,
      source: SourceResolver.resolve(id, json['source'] as String?),
    );
  }

  String get displayTitle {
    final numStr = number != null ? 'Chapter $number' : 'Chapter';
    if (title.isNotEmpty) {
      return '$numStr - $title';
    }
    return numStr;
  }

  ChapterItem copyWith({
    String? id,
    String? number,
    String? volume,
    String? title,
    int? pages,
    String? group,
    String? publishAt,
    String? source,
  }) {
    return ChapterItem(
      id: id ?? this.id,
      number: number ?? this.number,
      volume: volume ?? this.volume,
      title: title ?? this.title,
      pages: pages ?? this.pages,
      group: group ?? this.group,
      publishAt: publishAt ?? this.publishAt,
      source: source ?? this.source,
    );
  }
}

class ChapterPages {
  final String chapterId;
  final List<String> pages;
  final List<String> dataSaver;

  const ChapterPages({
    required this.chapterId,
    this.pages = const [],
    this.dataSaver = const [],
  });

  factory ChapterPages.fromJson(Map<String, dynamic> json) {
    return ChapterPages(
      chapterId: json['chapterId'] as String? ?? '',
      pages: (json['pages'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
      dataSaver: (json['dataSaver'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
    );
  }

  ChapterPages copyWith({
    String? chapterId,
    List<String>? pages,
    List<String>? dataSaver,
  }) {
    return ChapterPages(
      chapterId: chapterId ?? this.chapterId,
      pages: pages ?? this.pages,
      dataSaver: dataSaver ?? this.dataSaver,
    );
  }
}

class UserAccount {
  final String id;
  final String email;
  final String displayName;

  const UserAccount({
    required this.id,
    required this.email,
    required this.displayName,
  });

  factory UserAccount.fromJson(Map<String, dynamic> json) {
    return UserAccount(
      id: json['id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'displayName': displayName,
      };

  UserAccount copyWith({
    String? id,
    String? email,
    String? displayName,
  }) {
    return UserAccount(
      id: id ?? this.id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
    );
  }
}

class CategoryItem {
  final String id;
  final String name;
  final int order;

  const CategoryItem({
    required this.id,
    required this.name,
    this.order = 0,
  });

  factory CategoryItem.fromJson(Map<String, dynamic> json) {
    return CategoryItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      order: (json['order'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'order': order,
      };

  CategoryItem copyWith({
    String? id,
    String? name,
    int? order,
  }) {
    return CategoryItem(
      id: id ?? this.id,
      name: name ?? this.name,
      order: order ?? this.order,
    );
  }
}

/// Typed model representing reading position and completion status in a chapter (#6)
class ReadProgress {
  final String mangaId;
  final String chapterId;
  final String mangaTitle;
  final String cover;
  final String source;
  final String chapterNumber;
  final String chapterTitle;
  final int page;
  final int totalPages;
  final bool completed;
  final DateTime? updatedAt;

  const ReadProgress({
    required this.mangaId,
    required this.chapterId,
    this.mangaTitle = '',
    this.cover = '',
    this.source = 'mangadex',
    this.chapterNumber = '',
    this.chapterTitle = '',
    this.page = 1,
    this.totalPages = 0,
    this.completed = false,
    this.updatedAt,
  });

  factory ReadProgress.fromMap(Map<String, dynamic> map) {
    final mangaId = map['mangaId']?.toString() ?? '';
    final chapterId = map['chapterId']?.toString() ?? '';
    DateTime? dt;
    final rawDate = map['updatedAt'] ?? map['date'] ?? map['timestamp'];
    if (rawDate is DateTime) {
      dt = rawDate;
    } else if (rawDate != null) {
      dt = DateTime.tryParse(rawDate.toString());
    }

    return ReadProgress(
      mangaId: mangaId,
      chapterId: chapterId,
      mangaTitle: map['mangaTitle']?.toString() ?? map['title']?.toString() ?? '',
      cover: map['cover']?.toString() ?? '',
      source: SourceResolver.resolve(mangaId, map['source']?.toString()),
      chapterNumber: map['chapterNumber']?.toString() ?? map['chapter']?.toString() ?? '',
      chapterTitle: map['chapterTitle']?.toString() ?? '',
      page: (map['page'] as num?)?.toInt() ?? 1,
      totalPages: (map['totalPages'] as num?)?.toInt() ?? 0,
      completed: map['completed'] == true,
      updatedAt: dt,
    );
  }

  factory ReadProgress.fromJson(Map<String, dynamic> json) => ReadProgress.fromMap(json);

  Map<String, dynamic> toMap() => {
        'mangaId': mangaId,
        'chapterId': chapterId,
        'mangaTitle': mangaTitle,
        'cover': cover,
        'source': source,
        'chapterNumber': chapterNumber,
        'chapterTitle': chapterTitle,
        'page': page,
        'totalPages': totalPages,
        'completed': completed,
        'updatedAt': (updatedAt ?? DateTime.now()).toIso8601String(),
      };

  Map<String, dynamic> toJson() => toMap();

  ReadProgress copyWith({
    String? mangaId,
    String? chapterId,
    String? mangaTitle,
    String? cover,
    String? source,
    String? chapterNumber,
    String? chapterTitle,
    int? page,
    int? totalPages,
    bool? completed,
    DateTime? updatedAt,
  }) {
    return ReadProgress(
      mangaId: mangaId ?? this.mangaId,
      chapterId: chapterId ?? this.chapterId,
      mangaTitle: mangaTitle ?? this.mangaTitle,
      cover: cover ?? this.cover,
      source: source ?? this.source,
      chapterNumber: chapterNumber ?? this.chapterNumber,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      page: page ?? this.page,
      totalPages: totalPages ?? this.totalPages,
      completed: completed ?? this.completed,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Typed model for an entry in the reading history screen (#6)
class ReadHistoryEntry {
  final String mangaId;
  final String chapterId;
  final String mangaTitle;
  final String cover;
  final String source;
  final String chapterNumber;
  final String chapterTitle;
  final int page;
  final int totalPages;
  final bool completed;
  final DateTime? updatedAt;

  const ReadHistoryEntry({
    required this.mangaId,
    required this.chapterId,
    this.mangaTitle = '',
    this.cover = '',
    this.source = 'mangadex',
    this.chapterNumber = '',
    this.chapterTitle = '',
    this.page = 1,
    this.totalPages = 0,
    this.completed = false,
    this.updatedAt,
  });

  DateTime get date => updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  factory ReadHistoryEntry.fromMap(Map<String, dynamic> map) {
    final mangaId = map['mangaId']?.toString() ?? '';
    final chapterId = map['chapterId']?.toString() ?? '';
    DateTime? dt;
    final rawDate = map['updatedAt'] ?? map['date'] ?? map['timestamp'];
    if (rawDate is DateTime) {
      dt = rawDate;
    } else if (rawDate != null) {
      dt = DateTime.tryParse(rawDate.toString());
    }

    return ReadHistoryEntry(
      mangaId: mangaId,
      chapterId: chapterId,
      mangaTitle: map['mangaTitle']?.toString() ?? map['title']?.toString() ?? '',
      cover: map['cover']?.toString() ?? '',
      source: SourceResolver.resolve(mangaId, map['source']?.toString()),
      chapterNumber: map['chapterNumber']?.toString() ?? map['chapter']?.toString() ?? '',
      chapterTitle: map['chapterTitle']?.toString() ?? '',
      page: (map['page'] as num?)?.toInt() ?? 1,
      totalPages: (map['totalPages'] as num?)?.toInt() ?? 0,
      completed: map['completed'] == true,
      updatedAt: dt,
    );
  }

  factory ReadHistoryEntry.fromJson(Map<String, dynamic> json) => ReadHistoryEntry.fromMap(json);

  Map<String, dynamic> toMap() => {
        'mangaId': mangaId,
        'chapterId': chapterId,
        'mangaTitle': mangaTitle,
        'cover': cover,
        'source': source,
        'chapterNumber': chapterNumber,
        'chapterTitle': chapterTitle,
        'page': page,
        'totalPages': totalPages,
        'completed': completed,
        'updatedAt': (updatedAt ?? DateTime.now()).toIso8601String(),
        'date': (updatedAt ?? DateTime.now()).toIso8601String(),
      };

  Map<String, dynamic> toJson() => toMap();

  ReadHistoryEntry copyWith({
    String? mangaId,
    String? chapterId,
    String? mangaTitle,
    String? cover,
    String? source,
    String? chapterNumber,
    String? chapterTitle,
    int? page,
    int? totalPages,
    bool? completed,
    DateTime? updatedAt,
  }) {
    return ReadHistoryEntry(
      mangaId: mangaId ?? this.mangaId,
      chapterId: chapterId ?? this.chapterId,
      mangaTitle: mangaTitle ?? this.mangaTitle,
      cover: cover ?? this.cover,
      source: source ?? this.source,
      chapterNumber: chapterNumber ?? this.chapterNumber,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      page: page ?? this.page,
      totalPages: totalPages ?? this.totalPages,
      completed: completed ?? this.completed,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Detects duplicate manga/manhwa/manhua titles across different sources in the library
class DuplicateDetector {
  const DuplicateDetector._();

  static String normalize(String title) {
    var s = title.toLowerCase().trim();
    // Strip common bracketed/parenthesized tags like (Official), [Webtoon], (Colored), (Re-upload)
    s = s.replaceAll(RegExp(r'\s*[\(\[\{][^\)\]\}]*[\)\]\}]'), ' ');
    // Strip common punctuation and symbols
    s = s.replaceAll(RegExp(r'[^\w\s]'), ' ');
    // Collapse multiple spaces
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static bool isPossibleDuplicate(String titleA, String titleB) {
    final normA = normalize(titleA);
    final normB = normalize(titleB);
    if (normA.isEmpty || normB.isEmpty) return false;
    if (normA == normB) return true;

    // Substring / prefix check if significant portion matches
    if (normA.length >= 4 && normB.length >= 4) {
      if (normA.startsWith(normB) || normB.startsWith(normA)) return true;
      if (normA.contains(normB) && (normB.length / normA.length) >= 0.7) return true;
      if (normB.contains(normA) && (normA.length / normB.length) >= 0.7) return true;
    }
    return false;
  }

  static List<MangaItem> findDuplicatesInLibrary(
    MangaItem target,
    Iterable<MangaItem> library,
  ) {
    return library.where((m) {
      if (m.id == target.id) return false;
      return isPossibleDuplicate(m.title, target.title);
    }).toList();
  }
}
