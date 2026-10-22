String _resolveSource(String id, String? explicit) {
  if (explicit != null && explicit.isNotEmpty) return explicit;
  if (id.startsWith('asura:')) return 'asura';
  if (id.startsWith('flame:')) return 'flamecomics';
  if (id.startsWith('weeb:')) return 'weebcentral';
  if (id.startsWith('pill:')) return 'mangapill';
  if (id.startsWith('ext:')) {
    final parts = id.split(':');
    if (parts.length > 1 && parts[1].isNotEmpty) return parts[1];
  }
  if (id.contains(':')) {
    final prefix = id.substring(0, id.indexOf(':'));
    if (prefix.isNotEmpty) return prefix;
  }
  final isUuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(id);
  if (isUuid) return 'mangadex';
  return id.isNotEmpty ? id : 'unknown';
}

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
      source: _resolveSource(id, json['source'] as String?),
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
      source: _resolveSource(id, json['source'] as String?),
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
}

