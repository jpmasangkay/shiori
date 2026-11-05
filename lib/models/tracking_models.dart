/// Represents a tracking record for a specific manga linked to an external tracker
class MangaTrackingRecord {
  final String trackerId; // 'mangabaka', 'myanimelist', 'anilist', 'kitsu', 'mangaupdates', 'shikimori', 'bangumi', 'hikka'
  final String mangaId;
  final String remoteId;
  final String remoteTitle;
  final String? coverUrl;
  final String status; // 'Reading', 'Completed', 'On Hold', 'Dropped', 'Plan to Read', 'Rereading'
  final int lastChapterRead;
  final int? totalChapters;
  final double score; // 0.0 - 10.0
  final String? trackingUrl;
  final DateTime updatedAt;

  const MangaTrackingRecord({
    required this.trackerId,
    required this.mangaId,
    required this.remoteId,
    required this.remoteTitle,
    this.coverUrl,
    this.status = 'Reading',
    this.lastChapterRead = 0,
    this.totalChapters,
    this.score = 0.0,
    this.trackingUrl,
    required this.updatedAt,
  });

  MangaTrackingRecord copyWith({
    String? trackerId,
    String? mangaId,
    String? remoteId,
    String? remoteTitle,
    String? coverUrl,
    String? status,
    int? lastChapterRead,
    int? totalChapters,
    double? score,
    String? trackingUrl,
    DateTime? updatedAt,
  }) {
    return MangaTrackingRecord(
      trackerId: trackerId ?? this.trackerId,
      mangaId: mangaId ?? this.mangaId,
      remoteId: remoteId ?? this.remoteId,
      remoteTitle: remoteTitle ?? this.remoteTitle,
      coverUrl: coverUrl ?? this.coverUrl,
      status: status ?? this.status,
      lastChapterRead: lastChapterRead ?? this.lastChapterRead,
      totalChapters: totalChapters ?? this.totalChapters,
      score: score ?? this.score,
      trackingUrl: trackingUrl ?? this.trackingUrl,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'trackerId': trackerId,
        'mangaId': mangaId,
        'remoteId': remoteId,
        'remoteTitle': remoteTitle,
        'coverUrl': coverUrl,
        'status': status,
        'lastChapterRead': lastChapterRead,
        'totalChapters': totalChapters,
        'score': score,
        'trackingUrl': trackingUrl,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory MangaTrackingRecord.fromJson(Map<String, dynamic> json) {
    return MangaTrackingRecord(
      trackerId: json['trackerId'] as String? ?? 'anilist',
      mangaId: json['mangaId'] as String? ?? '',
      remoteId: json['remoteId']?.toString() ?? '',
      remoteTitle: json['remoteTitle'] as String? ?? '',
      coverUrl: json['coverUrl'] as String?,
      status: json['status'] as String? ?? 'Reading',
      lastChapterRead: (json['lastChapterRead'] as num?)?.toInt() ?? 0,
      totalChapters: (json['totalChapters'] as num?)?.toInt(),
      score: (json['score'] as num?)?.toDouble() ?? 0.0,
      trackingUrl: json['trackingUrl'] as String?,
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

/// Search result from an external tracker
class TrackerSearchResult {
  final String trackerId;
  final String remoteId;
  final String title;
  final String? coverUrl;
  final int? totalChapters;
  final String? status;
  final double? score;
  final String? url;

  const TrackerSearchResult({
    required this.trackerId,
    required this.remoteId,
    required this.title,
    this.coverUrl,
    this.totalChapters,
    this.status,
    this.score,
    this.url,
  });
}

/// Metadata and definition for an available tracker service
class TrackerServiceMeta {
  final String id;
  final String name;
  final String defaultUrl;
  final bool requiresAuth;

  const TrackerServiceMeta({
    required this.id,
    required this.name,
    required this.defaultUrl,
    this.requiresAuth = true,
  });

  static const List<TrackerServiceMeta> all = [
    TrackerServiceMeta(
      id: 'mangabaka',
      name: 'MangaBaka',
      defaultUrl: 'https://mangabaka.com',
      requiresAuth: false,
    ),
    TrackerServiceMeta(
      id: 'myanimelist',
      name: 'MyAnimeList',
      defaultUrl: 'https://myanimelist.net',
      requiresAuth: false,
    ),
    TrackerServiceMeta(
      id: 'anilist',
      name: 'AniList',
      defaultUrl: 'https://anilist.co',
      requiresAuth: true,
    ),
    TrackerServiceMeta(
      id: 'kitsu',
      name: 'Kitsu',
      defaultUrl: 'https://kitsu.io',
      requiresAuth: false,
    ),
    TrackerServiceMeta(
      id: 'mangaupdates',
      name: 'MangaUpdates',
      defaultUrl: 'https://www.mangaupdates.com',
      requiresAuth: false,
    ),
    TrackerServiceMeta(
      id: 'shikimori',
      name: 'Shikimori',
      defaultUrl: 'https://shikimori.one',
      requiresAuth: false,
    ),
    TrackerServiceMeta(
      id: 'bangumi',
      name: 'Bangumi',
      defaultUrl: 'https://bgm.tv',
      requiresAuth: false,
    ),
    TrackerServiceMeta(
      id: 'hikka',
      name: 'Hikka',
      defaultUrl: 'https://hikka.io',
      requiresAuth: false,
    ),
  ];

  static TrackerServiceMeta? find(String id) {
    try {
      return all.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }
}
