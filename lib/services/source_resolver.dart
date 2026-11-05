class SourceResolver {
  const SourceResolver._();

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static String? Function(String pkg)? extensionNameLookup;

  /// Resolves the canonical source identifier from an item's [id] and optional [explicit] source.
  /// Preserves full compatibility with MangaDex UUIDs, direct scrapers, extensions,
  /// and custom extension package prefixes.
  static String resolve(String id, [String? explicit]) {
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (id.startsWith('asura:')) return 'asura';
    if (id.startsWith('flame:')) return 'flamecomics';
    if (id.startsWith('weeb:')) return 'weebcentral';
    if (id.startsWith('pill:')) return 'mangapill';
    if (id.startsWith('katana:')) return 'mangakatana';
    if (id.startsWith('mread:')) return 'mangaread';
    if (id.startsWith('nato:')) return 'manganato';
    if (id.startsWith('fox:')) return 'mangafox';
    if (id.startsWith('demon:')) return 'mangademon';
    if (id.startsWith('mangadex:')) return 'mangadex';
    if (id.startsWith('ext:')) {
      final parts = id.split(':');
      if (parts.length > 1 && parts[1].isNotEmpty) return parts[1];
      return 'extension';
    }
    if (id.contains(':')) {
      final prefix = id.substring(0, id.indexOf(':'));
      if (prefix.isNotEmpty) return prefix;
    }
    if (_uuidPattern.hasMatch(id)) {
      return 'mangadex';
    }
    return id.isNotEmpty ? id : 'unknown';
  }

  /// Returns a clean human-readable name for a source identifier.
  static String displayName(String source) {
    var raw = source.trim();
    if (raw.startsWith('ext:')) {
      final parts = raw.split(':');
      if (parts.length > 1 && parts[1].isNotEmpty) {
        raw = parts[1];
      }
    }

    final lower = raw.toLowerCase();
    switch (lower) {
      case 'mangadex':
        return 'MangaDex';
      case 'asura':
        return 'Asura Scans';
      case 'flamecomics':
      case 'flame':
        return 'Flame Comics';
      case 'weebcentral':
      case 'weeb':
        return 'WeebCentral';
      case 'mangapill':
      case 'pill':
        return 'MangaPill';
      case 'mangakatana':
      case 'katana':
        return 'MangaKatana';
      case 'mangaread':
      case 'mread':
        return 'MangaRead';
      case 'manganato':
      case 'nato':
      case 'manganelo':
        return 'MangaNato';
      case 'mangafox':
      case 'fox':
        return 'MangaFox';
      case 'mangademon':
      case 'demon':
        return 'MangaDemon';
      case 'extension':
        return 'Extension';
      case 'unknown':
      case '':
        return 'Unknown';
    }

    // Try registered extension lookup
    final basePkg = raw.contains('@') ? raw.split('@').first : raw;
    final lookup = extensionNameLookup?.call(basePkg) ?? extensionNameLookup?.call(raw);
    if (lookup != null && lookup.isNotEmpty && lookup != raw) {
      if (raw.contains('@')) {
        final selector = raw.split('@').last.trim();
        if (selector.isNotEmpty &&
            selector.toLowerCase() != lookup.toLowerCase() &&
            int.tryParse(selector) == null) {
          return '$lookup (${selector.toUpperCase()})';
        }
      }
      return lookup;
    }

    // Tachiyomi extension package parser: e.g. eu.kanade.tachiyomi.extension.en.mangabuddy
    if (raw.contains('.extension.') || raw.startsWith('eu.kanade.') || raw.contains('.')) {
      final selector = raw.contains('@') ? raw.split('@').last.trim() : '';
      final pkgOnly = raw.contains('@') ? raw.split('@').first.trim() : raw;

      String slug = pkgOnly;
      if (slug.contains('.extension.')) {
        slug = slug.substring(slug.indexOf('.extension.') + '.extension.'.length);
      } else if (slug.contains('.')) {
        slug = slug.split('.').last;
      }

      final parts = slug.split('.');
      // Remove language tag if present (e.g. "en", "all", "es", "ja")
      if (parts.length > 1 && parts.first.length <= 4) {
        slug = parts.sublist(1).join('.');
      } else if (parts.isNotEmpty) {
        slug = parts.last;
      }

      final cleanName = _cleanExtensionSlug(slug);
      if (cleanName.isNotEmpty) {
        if (selector.isNotEmpty &&
            selector.toLowerCase() != cleanName.toLowerCase() &&
            int.tryParse(selector) == null) {
          return '$cleanName (${selector.toUpperCase()})';
        }
        return cleanName;
      }
    }

    if (raw.length <= 1) return raw.toUpperCase();
    return raw[0].toUpperCase() + raw.substring(1);
  }

  static String _cleanExtensionSlug(String slug) {
    final lower = slug.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (lower == 'mangabuddy') return 'MangaBuddy';
    if (lower == 'comicklive' || lower == 'comick') return 'Comick';
    if (lower == 'mangadex') return 'MangaDex';
    if (lower == 'asura' || lower == 'asurascans') return 'Asura Scans';
    if (lower == 'flamecomics' || lower == 'flame') return 'Flame Comics';
    if (lower == 'weebcentral') return 'WeebCentral';
    if (lower == 'mangapill') return 'MangaPill';
    if (lower == 'mangakatana') return 'MangaKatana';
    if (lower == 'mangaread') return 'MangaRead';
    if (lower == 'manganato' || lower == 'manganelo') return 'MangaNato';
    if (lower == 'mangafox' || lower == 'fanfox') return 'MangaFox';
    if (lower == 'mangademon') return 'MangaDemon';
    if (lower == 'webtoons') return 'Webtoons';
    if (lower == 'reaperscans') return 'Reaper Scans';
    if (lower == 'voidscans' || lower == 'hivetoons') return 'Hive Scans';
    if (lower == 'manhwaclan') return 'ManhwaClan';

    // Break by common words or camelCase
    var spaced = slug
        .replaceAllMapped(RegExp(r'(manga|scans|scan|comics|comic|live|clan|box|raw)'), (m) => ' ${m[1]} ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (spaced.isEmpty) spaced = slug;
    return spaced.split(' ').map((w) {
      if (w.isEmpty) return '';
      return w[0].toUpperCase() + w.substring(1).toLowerCase();
    }).join(' ');
  }

  static bool isBuiltIn(String source) {
    final s = source.toLowerCase();
    return s == 'mangadex' ||
        s == 'asura' ||
        s == 'flamecomics' ||
        s == 'flame' ||
        s == 'weebcentral' ||
        s == 'weeb' ||
        s == 'mangapill' ||
        s == 'pill' ||
        s == 'mangakatana' ||
        s == 'katana' ||
        s == 'mangaread' ||
        s == 'mread';
  }

  static String resolveSource(String id, [String? explicit]) =>
      resolve(id, explicit);

  static String prefix(String source, String id) {
    if (id.startsWith('$source:')) return id;
    return '$source:$id';
  }

  static String stripPrefix(String id) {
    final idx = id.indexOf(':');
    return idx != -1 ? id.substring(idx + 1) : id;
  }
}
