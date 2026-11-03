class SourceResolver {
  const SourceResolver._();

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

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
    switch (source.toLowerCase()) {
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
      case 'extension':
        return 'Extension';
      case 'unknown':
      case '':
        return 'Unknown';
      default:
        if (source.length <= 1) return source.toUpperCase();
        return source[0].toUpperCase() + source.substring(1);
    }
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
