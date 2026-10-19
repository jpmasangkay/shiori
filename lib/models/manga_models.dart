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
  });

  factory MangaItem.fromJson(Map<String, dynamic> json) {
    return MangaItem(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      description: json['description'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      authors: (json['authors'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
      status: json['status'] as String? ?? '',
      type: json['type'] as String? ?? 'manga',
      tags: (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
      year: json['year']?.toString(),
      lastChapter: json['lastChapter']?.toString(),
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
      };
}

class ChapterItem {
  final String id;
  final String? number;
  final String? volume;
  final String title;
  final int pages;
  final String group;
  final String? publishAt;

  const ChapterItem({
    required this.id,
    this.number,
    this.volume,
    this.title = '',
    this.pages = 0,
    this.group = '',
    this.publishAt,
  });

  factory ChapterItem.fromJson(Map<String, dynamic> json) {
    return ChapterItem(
      id: json['id'] as String? ?? '',
      number: json['number']?.toString(),
      volume: json['volume']?.toString(),
      title: json['title'] as String? ?? '',
      pages: (json['pages'] as num?)?.toInt() ?? 0,
      group: json['group'] as String? ?? '',
      publishAt: json['publishAt'] as String?,
    );
  }

  String get displayTitle {
    final numStr = number != null ? 'Chapter $number' : 'Chapter';
    if (title.isNotEmpty) {
      return '$numStr - $title';
    }
    return numStr;
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
}
