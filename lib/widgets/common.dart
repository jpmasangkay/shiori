import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme.dart';
import 'skeleton.dart';

const String _browserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const String _imageAccept =
    'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8';

typedef NativeImageLoader = Future<Uint8List?> Function(String url);
typedef CoverLookup = Future<String?> Function(String mangaId);
typedef NativeLoaderProvider = NativeImageLoader? Function(String url, String? mangaId);
typedef RefererProvider = String? Function(String url, String? mangaId);

Future<void> evictCachedImageUrl(String url) async {
  ImageReferers.evictNativeCache(url);
  try {
    await CachedNetworkImage.evictFromCache(url);
  } catch (_) {
    try {
      await CachedNetworkImageProvider(url).evict();
    } catch (_) {}
  }
}

/// Learned image host -> referer/headers/native-loader mappings (especially for
/// Tachiyomi/Keiyoushi extensions with custom OkHttp interceptors, Cloudflare
/// cookies, or strict Referer rules), plus self-healing cover resolution.
class ImageReferers {
  ImageReferers._();

  static final Map<String, String> _hostReferers = {};
  static final Map<String, Map<String, String>> _hostHeaders = {};
  static final LinkedHashMap<String, NativeImageLoader> _urlNativeLoaders =
      LinkedHashMap();
  static final Map<String, NativeImageLoader> _hostNativeLoaders = {};
  static final LinkedHashSet<String> _preferNativeUrls = LinkedHashSet();
  static final Set<String> _preferNativeHosts = {};

  static final LinkedHashMap<String, Uint8List> _nativeBytesCache =
      LinkedHashMap();
  static final Map<String, Future<Uint8List?>> _inFlightNative = {};
  static const int _maxNativeCacheEntries = 48;
  static const int _maxTrackedUrls = 1500;

  /// Optional global resolver wired by [ApiService] to backfill missing/expired covers.
  static CoverLookup? coverLookup;

  /// Optional provider to dynamically resolve a native OkHttp image loader (e.g. from Tachiyomi extensions).
  static NativeLoaderProvider? nativeLoaderProvider;

  /// Optional provider to dynamically resolve a source's referer base URL.
  static RefererProvider? refererProvider;
  static final Map<String, String> _resolvedCovers = {};
  static final Set<String> _failedCoverIds = {};
  static final Map<String, Future<String?>> _inFlightCoverLookups = {};
  static int _activeCoverLookups = 0;
  static final Queue<Completer<void>> _coverLookupQueue =
      Queue<Completer<void>>();
  static const int _maxConcurrentCoverLookups = 4;

  /// Remembers that images served from [imageUrl]'s host must be requested
  /// with [referer] (usually the source's base URL).
  static void register(String imageUrl, String referer) {
    if (referer.isEmpty) return;
    final host = Uri.tryParse(imageUrl)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return;
    var ref = referer.trim();
    if (!ref.startsWith('http')) return;
    if (!ref.endsWith('/')) ref = '$ref/';
    _hostReferers[host] = ref;
  }

  /// Registers [referer] for every URL in [imageUrls].
  static void registerAll(Iterable<String> imageUrls, String referer) {
    for (final u in imageUrls) {
      register(u, referer);
    }
  }

  /// Registers custom headers and/or a native Kotlin OkHttp image loader for
  /// URLs belonging to a Tachiyomi extension.
  static void registerSourceConfig(
    Iterable<String> imageUrls, {
    String? referer,
    Map<String, String>? headers,
    NativeImageLoader? nativeLoader,
    bool preferNative = false,
  }) {
    final cleanedHeaders = <String, String>{};
    if (headers != null) {
      headers.forEach((k, v) {
        if (k.trim().isNotEmpty && v.trim().isNotEmpty) {
          cleanedHeaders[k.trim()] = v.trim();
        }
      });
    }

    for (final rawUrl in imageUrls) {
      final u = rawUrl.trim();
      if (u.isEmpty) continue;
      if (referer != null && referer.isNotEmpty) {
        register(u, referer);
      }
      final host = Uri.tryParse(u)?.host.toLowerCase() ?? '';
      if (host.isNotEmpty && cleanedHeaders.isNotEmpty) {
        _hostHeaders[host] = {...?_hostHeaders[host], ...cleanedHeaders};
      }
      if (nativeLoader != null) {
        if (_urlNativeLoaders.length >= _maxTrackedUrls) {
          _urlNativeLoaders.remove(_urlNativeLoaders.keys.first);
        }
        _urlNativeLoaders[u] = nativeLoader;
        if (host.isNotEmpty) {
          _hostNativeLoaders[host] = nativeLoader;
        }
        if (preferNative) {
          if (_preferNativeUrls.length >= _maxTrackedUrls) {
            _preferNativeUrls.remove(_preferNativeUrls.first);
          }
          _preferNativeUrls.add(u);
          if (host.isNotEmpty) {
            _preferNativeHosts.add(host);
          }
        }
      }
    }
  }

  static String? lookup(String host) => _hostReferers[host.toLowerCase()];

  static Map<String, String>? lookupHeaders(String host) =>
      _hostHeaders[host.toLowerCase()];

  static NativeImageLoader? lookupNativeLoader(String url, {String? mangaId}) {
    final direct = _urlNativeLoaders[url];
    if (direct != null) return direct;
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isNotEmpty) {
      final hostLoader = _hostNativeLoaders[host];
      if (hostLoader != null) return hostLoader;
    }
    if (nativeLoaderProvider != null) {
      final provided = nativeLoaderProvider!(url, mangaId);
      if (provided != null) {
        registerSourceConfig([url], nativeLoader: provided);
        return provided;
      }
    }
    return null;
  }

  static bool hasNativeLoader(String url, {String? mangaId}) =>
      lookupNativeLoader(url, mangaId: mangaId) != null;

  static bool prefersNative(String url) {
    if (_preferNativeUrls.contains(url)) return true;
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return host.isNotEmpty && _preferNativeHosts.contains(host);
  }

  static Uint8List? getCachedNativeBytes(String url) {
    final bytes = _nativeBytesCache.remove(url);
    if (bytes != null) {
      _nativeBytesCache[url] = bytes;
    }
    return bytes;
  }

  static void evictNativeCache(String url) {
    _nativeBytesCache.remove(url);
    _inFlightNative.remove(url);
  }

  static Future<Uint8List?> fetchNativeBytes(String url) {
    final cached = getCachedNativeBytes(url);
    if (cached != null) return SynchronousFuture<Uint8List?>(cached);

    final existing = _inFlightNative[url];
    if (existing != null) return existing;

    final loader = lookupNativeLoader(url);
    if (loader == null) return SynchronousFuture<Uint8List?>(null);

    late final Future<Uint8List?> fut;
    fut = () async {
      try {
        final bytes = await loader(
          url,
        ).timeout(const Duration(seconds: 15), onTimeout: () => null);
        if (bytes != null && bytes.isNotEmpty) {
          if (_nativeBytesCache.length >= _maxNativeCacheEntries) {
            _nativeBytesCache.remove(_nativeBytesCache.keys.first);
          }
          _nativeBytesCache[url] = bytes;
          return bytes;
        }
      } catch (_) {}
      return null;
    }();

    _inFlightNative[url] = fut;
    fut.whenComplete(() {
      if (identical(_inFlightNative[url], fut)) {
        _inFlightNative.remove(url);
      }
    });
    return fut;
  }

  static String? getResolvedCover(String? mangaId) {
    if (mangaId == null || mangaId.isEmpty) return null;
    return _resolvedCovers[mangaId];
  }

  static void rememberResolvedCover(String mangaId, String coverUrl) {
    if (mangaId.isEmpty || coverUrl.trim().isEmpty) return;
    _resolvedCovers[mangaId] = coverUrl.trim();
    _failedCoverIds.remove(mangaId);
  }

  static Future<String?> resolveCoverForManga(
    String mangaId, {
    bool force = false,
  }) {
    if (mangaId.isEmpty || coverLookup == null) {
      return SynchronousFuture<String?>(null);
    }
    if (!force) {
      final cached = _resolvedCovers[mangaId];
      if (cached != null && cached.isNotEmpty) {
        return SynchronousFuture<String?>(cached);
      }
      if (_failedCoverIds.contains(mangaId)) {
        return SynchronousFuture<String?>(null);
      }
    } else {
      _failedCoverIds.remove(mangaId);
    }

    final existing = _inFlightCoverLookups[mangaId];
    if (existing != null) return existing;

    final fut = () async {
      if (_activeCoverLookups >= _maxConcurrentCoverLookups) {
        final gate = Completer<void>();
        _coverLookupQueue.addLast(gate);
        await gate.future;
      }
      _activeCoverLookups++;
      try {
        final lookup = coverLookup;
        if (lookup == null) return null;
        final resolved = await lookup(
          mangaId,
        ).timeout(const Duration(seconds: 10), onTimeout: () => null);
        final trimmed = resolved?.trim() ?? '';
        if (trimmed.isNotEmpty) {
          _resolvedCovers[mangaId] = trimmed;
          return trimmed;
        }
        _failedCoverIds.add(mangaId);
        return null;
      } catch (_) {
        _failedCoverIds.add(mangaId);
        return null;
      } finally {
        _activeCoverLookups--;
        if (_coverLookupQueue.isNotEmpty) {
          _coverLookupQueue.removeFirst().complete();
        }
      }
    }();

    _inFlightCoverLookups[mangaId] = fut;
    fut.whenComplete(() => _inFlightCoverLookups.remove(mangaId));
    return fut;
  }

  @visibleForTesting
  static void resetForTesting() {
    _hostReferers.clear();
    _hostHeaders.clear();
    _urlNativeLoaders.clear();
    _hostNativeLoaders.clear();
    _preferNativeUrls.clear();
    _preferNativeHosts.clear();
    _nativeBytesCache.clear();
    _inFlightNative.clear();
    _resolvedCovers.clear();
    _failedCoverIds.clear();
    _inFlightCoverLookups.clear();
    coverLookup = null;
    nativeLoaderProvider = null;
    refererProvider = null;
  }
}

/// Standard browser headers for CDN image fetching to bypass Cloudflare and referer blocks.
Map<String, String> imageHeadersForUrl(String url, {String? mangaId}) {
  final uri = Uri.tryParse(url);
  final host = uri?.host.toLowerCase() ?? '';
  final custom = ImageReferers.lookupHeaders(host);
  final learned = ImageReferers.lookup(host);

  if (custom != null && custom.isNotEmpty) {
    return {
      'User-Agent': _browserUserAgent,
      'Referer': ?learned,
      'Accept': _imageAccept,
      ...custom,
    };
  }

  if (learned != null) {
    return {
      'User-Agent': _browserUserAgent,
      'Referer': learned,
      'Accept': _imageAccept,
    };
  }

  if (ImageReferers.refererProvider != null) {
    final provided = ImageReferers.refererProvider!(url, mangaId);
    if (provided != null && provided.isNotEmpty) {
      final ref = provided.endsWith('/') ? provided : '$provided/';
      if (host.isNotEmpty) {
        ImageReferers.register(url, ref);
      }
      return {
        'User-Agent': _browserUserAgent,
        'Referer': ref,
        'Accept': _imageAccept,
      };
    }
  }

  String referer = 'https://$host/';
  if (host.contains('comick') || host.contains('meo')) {
    referer = 'https://comick.art/';
  } else if (host.contains('mangadex')) {
    referer = 'https://mangadex.org/';
  } else if (host.contains('asurascans')) {
    referer = 'https://asurascans.com/';
  } else if (host.contains('asura')) {
    referer = 'https://asuracomic.net/';
  } else if (host.contains('flame')) {
    referer = 'https://flamecomics.xyz/';
  } else if (host.contains('weebcentral') ||
      host.contains('planeptune') ||
      host.contains('compsci88')) {
    referer = 'https://weebcentral.com/';
  } else if (host.contains('resmk') || host.contains('mangabuddy')) {
    referer = 'https://mangabuddy.com/';
  } else if (host.contains('pstatic') || host.contains('webtoon')) {
    referer = 'https://www.webtoons.com/';
  } else if (host.contains('bato') ||
      host.contains('battwo') ||
      host.contains('batotoo')) {
    referer = 'https://bato.to/';
  } else if (host.contains('mangapark')) {
    referer = 'https://mangapark.net/';
  } else if (host.contains('fanfox') || host.contains('mangafox')) {
    referer = 'https://fanfox.net/';
  } else if (host.contains('readdetectiveconan') ||
      host.contains('mangapill')) {
    referer = 'https://mangapill.com/';
  } else if (host.contains('mangakatana')) {
    referer = 'https://mangakatana.com/';
  } else if (host.contains('mangaread')) {
    referer = 'https://www.mangaread.org/';
  } else if (host.contains('manganato') || host.contains('chapmanganato')) {
    referer = 'https://chapmanganato.to/';
  } else if (host.contains('mangakakalot')) {
    referer = 'https://mangakakalot.com/';
  } else if (host.contains('mpcdn') ||
      host.contains('kakacdn') ||
      host.contains('natocdn') ||
      host.contains('manganelo')) {
    referer = 'https://manganelo.com/';
  } else if (mangaId != null && mangaId.startsWith('ext:')) {
    final pkg = mangaId.substring(4).split(':').first.toLowerCase();
    if (pkg.contains('mangabuddy')) {
      referer = 'https://mangabuddy.com/';
    } else if (pkg.contains('manganelo')) {
      referer = 'https://manganelo.com/';
    } else if (pkg.contains('manganato')) {
      referer = 'https://chapmanganato.to/';
    } else if (pkg.contains('asura')) {
      referer = 'https://asuracomic.net/';
    } else if (pkg.contains('flame')) {
      referer = 'https://flamecomics.xyz/';
    }
  }

  if (host.isNotEmpty && referer != 'https://$host/') {
    ImageReferers.register(url, referer);
  }

  return {
    'User-Agent': _browserUserAgent,
    'Referer': referer,
    'Accept': _imageAccept,
  };
}

/// Alternative header sets to try when an image fails with the default headers.
List<Map<String, String>> imageHeaderVariants(String url, {String? mangaId}) {
  final primary = imageHeadersForUrl(url, mangaId: mangaId);
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  final ua = primary['User-Agent'] ?? _browserUserAgent;
  final cookie = primary['Cookie'] ?? primary['cookie'];

  final hostRootRef = <String, String>{
    'User-Agent': ua,
    if (host.isNotEmpty) 'Referer': 'https://$host/',
    'Accept': _imageAccept,
    if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
  };
  final noRef = <String, String>{
    'User-Agent': ua,
    'Accept': _imageAccept,
    if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
  };
  final variants = <Map<String, String>>[primary, hostRootRef, noRef];
  final seen = <String>{};
  return [
    for (final v in variants)
      if (seen.add('${v['Referer'] ?? '<none>'}|${v['Cookie'] ?? ''}')) v,
  ];
}

final Map<int, ColorFilter> _saturateFilterCache = {};

/// Equivalent of the CSS `filter: saturate(x)`.
ColorFilter saturate(double s) {
  final key = (s * 100).round();
  return _saturateFilterCache.putIfAbsent(key, () {
    const r = 0.213, g = 0.715, b = 0.072;
    return ColorFilter.matrix(<double>[
      r + (1 - r) * s, g - g * s, b - b * s, 0, 0, //
      r - r * s, g + (1 - g) * s, b - b * s, 0, 0, //
      r - r * s, g - g * s, b + (1 - b) * s, 0, 0, //
      0, 0, 0, 1, 0,
    ]);
  });
}

enum _AttemptKind { http, native }

class _ImageAttempt {
  const _ImageAttempt({
    required this.kind,
    required this.url,
    this.headers = const {},
    this.variantIndex = 0,
  });

  final _AttemptKind kind;
  final String url;
  final Map<String, String> headers;
  final int variantIndex;
}

/// Network image that never hangs indefinitely on stalled sockets:
/// - enforces a per-attempt watchdog timeout so tarpitted CDNs always fall back
///   and reveal [errorBuilder]'s manual retry button,
/// - transparently supports Tachiyomi OkHttp native image interceptors & cookies,
/// - evicts corrupt disk & memory cache entries on failure.
class RetryingNetworkImage extends StatefulWidget {
  const RetryingNetworkImage({
    super.key,
    required this.url,
    this.fallbackUrls = const [],
    this.mangaId,
    this.fit,
    this.width,
    this.height,
    this.memCacheWidth,
    this.memCacheHeight,
    this.placeholder,
    this.progressBuilder,
    this.errorBuilder,
    this.fadeInDuration = const Duration(milliseconds: 280),
    this.attemptTimeout = const Duration(seconds: 10),
  });

  final String url;
  final List<String> fallbackUrls;
  final String? mangaId;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final int? memCacheWidth;
  final int? memCacheHeight;
  final WidgetBuilder? placeholder;
  final Widget Function(BuildContext context, double? progress)?
  progressBuilder;
  final Widget Function(BuildContext context, VoidCallback retry)? errorBuilder;
  final Duration fadeInDuration;
  final Duration attemptTimeout;

  /// Remembers which header variant worked per host so later images from the
  /// same CDN load on the first try.
  static final Map<String, int> _workingVariantByHost = {};

  @override
  State<RetryingNetworkImage> createState() => _RetryingNetworkImageState();
}

class _RetryingNetworkImageState extends State<RetryingNetworkImage> {
  late List<_ImageAttempt> _attempts;
  int _attempt = 0;
  int _generation = 0;
  bool _exhausted = false;
  bool _retryScheduled = false;
  bool _loadedCurrentAttempt = false;
  Uint8List? _nativeBytes;
  bool _nativeFetchInFlight = false;
  Timer? _retryTimer;
  Timer? _watchdogTimer;

  @override
  void initState() {
    super.initState();
    _initAndStart();
  }

  @override
  void didUpdateWidget(covariant RetryingNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.mangaId != widget.mangaId ||
        !listEquals(oldWidget.fallbackUrls, widget.fallbackUrls)) {
      _cancelTimers();
      _attempt = 0;
      _generation++;
      _exhausted = false;
      _retryScheduled = false;
      _loadedCurrentAttempt = false;
      _nativeBytes = null;
      _nativeFetchInFlight = false;
      _initAndStart();
    }
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  void _cancelTimers() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void _initAndStart() {
    final trimmed = widget.url.trim();
    if (trimmed.isNotEmpty) {
      final cachedNative = ImageReferers.getCachedNativeBytes(trimmed);
      if (cachedNative != null) {
        _attempts = [_ImageAttempt(kind: _AttemptKind.native, url: trimmed)];
        _nativeBytes = cachedNative;
        _loadedCurrentAttempt = true;
        return;
      }
    }
    _buildAttempts();
    if (_attempts.isEmpty) {
      _exhausted = true;
      return;
    }
    _prepareCurrentAttempt();
  }

  void _buildAttempts() {
    final urls = <String>[
      if (widget.url.trim().startsWith('http')) widget.url.trim(),
      ...widget.fallbackUrls
          .map((u) => u.trim())
          .where((u) => u.startsWith('http') && u != widget.url.trim()),
    ];
    final attempts = <_ImageAttempt>[];
    for (final u in urls) {
      final hasNative = ImageReferers.hasNativeLoader(u, mangaId: widget.mangaId);
      final preferNative = hasNative && ImageReferers.prefersNative(u);

      if (preferNative) {
        attempts.add(_ImageAttempt(kind: _AttemptKind.native, url: u));
      }

      final variants = imageHeaderVariants(u, mangaId: widget.mangaId);
      final host = Uri.tryParse(u)?.host.toLowerCase() ?? '';
      final preferred = RetryingNetworkImage._workingVariantByHost[host];
      final order = [for (var i = 0; i < variants.length; i++) i];
      if (preferred != null && preferred < variants.length) {
        order
          ..remove(preferred)
          ..insert(0, preferred);
      }
      for (final i in order) {
        attempts.add(
          _ImageAttempt(
            kind: _AttemptKind.http,
            url: u,
            headers: variants[i],
            variantIndex: i,
          ),
        );
      }

      if (hasNative && !preferNative) {
        attempts.add(_ImageAttempt(kind: _AttemptKind.native, url: u));
      }
    }
    _attempts = attempts;
  }

  void _prepareCurrentAttempt() {
    _watchdogTimer?.cancel();
    _loadedCurrentAttempt = false;
    if (_exhausted || _attempt >= _attempts.length) return;

    final current = _attempts[_attempt];
    if (current.kind == _AttemptKind.native) {
      final cached = ImageReferers.getCachedNativeBytes(current.url);
      if (cached != null) {
        _nativeBytes = cached;
        _loadedCurrentAttempt = true;
        return;
      }
      if (!_nativeFetchInFlight) {
        _nativeFetchInFlight = true;
        final expectedAttempt = _attempt;
        final expectedGen = _generation;
        ImageReferers.fetchNativeBytes(
          current.url,
        ).timeout(widget.attemptTimeout, onTimeout: () => null).then((bytes) {
          if (!mounted ||
              _generation != expectedGen ||
              _attempt != expectedAttempt) {
            return;
          }
          _nativeFetchInFlight = false;
          if (bytes != null && bytes.isNotEmpty) {
            setState(() {
              _nativeBytes = bytes;
              _loadedCurrentAttempt = true;
            });
          } else {
            _onError();
          }
        });
      }
    } else {
      final expectedAttempt = _attempt;
      final expectedGen = _generation;
      _watchdogTimer = Timer(widget.attemptTimeout, () {
        if (!mounted ||
            _generation != expectedGen ||
            _attempt != expectedAttempt) {
          return;
        }
        if (!_loadedCurrentAttempt) {
          _onError();
        }
      });
    }
  }

  void _onError() {
    if (_retryScheduled || _exhausted || _attempt >= _attempts.length) return;
    _retryScheduled = true;
    _watchdogTimer?.cancel();
    final failed = _attempts[_attempt];
    if (failed.kind == _AttemptKind.http) {
      evictCachedImageUrl(failed.url);
    } else {
      ImageReferers.evictNativeCache(failed.url);
    }

    if (_attempt + 1 >= _attempts.length) {
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _exhausted = true;
            _retryScheduled = false;
          });
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      } else if (mounted) {
        setState(() {
          _exhausted = true;
          _retryScheduled = false;
        });
      }
      return;
    }

    // Brief backoff before advancing to the next attempt.
    _retryTimer = Timer(Duration(milliseconds: 160 + 140 * _attempt), () {
      if (!mounted) return;
      setState(() {
        _attempt++;
        _retryScheduled = false;
        _nativeBytes = null;
        _nativeFetchInFlight = false;
        _prepareCurrentAttempt();
      });
    });
  }

  void _manualRetry() {
    _cancelTimers();
    final evicted = <String>{};
    for (final a in _attempts) {
      if (evicted.add(a.url)) {
        evictCachedImageUrl(a.url);
      }
    }
    setState(() {
      _attempt = 0;
      _generation++;
      _exhausted = false;
      _retryScheduled = false;
      _loadedCurrentAttempt = false;
      _nativeBytes = null;
      _nativeFetchInFlight = false;
      _buildAttempts();
      if (_attempts.isEmpty) {
        _exhausted = true;
      } else {
        _prepareCurrentAttempt();
      }
    });
  }

  Widget _placeholder(BuildContext context) =>
      widget.placeholder?.call(context) ??
      const _CoverPlaceholder(loading: true);

  @override
  Widget build(BuildContext context) {
    if (_exhausted || _attempts.isEmpty) {
      return widget.errorBuilder?.call(context, _manualRetry) ??
          const _CoverPlaceholder();
    }

    final current = _attempts[_attempt];
    final progressBuilder = widget.progressBuilder;

    if (current.kind == _AttemptKind.native) {
      final bytes = _nativeBytes;
      if (bytes != null && bytes.isNotEmpty) {
        return Image.memory(
          bytes,
          key: ValueKey('native_${current.url}#$_generation'),
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
          cacheWidth: widget.memCacheWidth,
          cacheHeight: widget.memCacheHeight,
          gaplessPlayback: true,
          errorBuilder: (ctx, _, _) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _onError();
            });
            return progressBuilder?.call(ctx, null) ?? _placeholder(ctx);
          },
        );
      }
      return progressBuilder?.call(context, null) ?? _placeholder(context);
    }

    return CachedNetworkImage(
      key: ValueKey('${current.url}#$_attempt#$_generation'),
      imageUrl: current.url,
      httpHeaders: current.headers,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      memCacheWidth: widget.memCacheWidth,
      memCacheHeight: widget.memCacheHeight,
      maxWidthDiskCache: 1200,
      maxHeightDiskCache: 1800,
      fadeInDuration: widget.fadeInDuration,
      fadeOutDuration: const Duration(milliseconds: 120),
      placeholder: progressBuilder == null
          ? (ctx, _) => _placeholder(ctx)
          : null,
      progressIndicatorBuilder: progressBuilder == null
          ? null
          : (ctx, _, p) => progressBuilder(ctx, p.progress),
      imageBuilder: (ctx, provider) {
        _loadedCurrentAttempt = true;
        _watchdogTimer?.cancel();
        final host = Uri.tryParse(current.url)?.host.toLowerCase() ?? '';
        if (host.isNotEmpty) {
          RetryingNetworkImage._workingVariantByHost[host] =
              current.variantIndex;
        }
        return Image(
          image: provider,
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
          gaplessPlayback: true,
        );
      },
      errorWidget: (ctx, _, _) {
        _onError();
        // Keep showing the loading state while the next attempt is queued.
        return progressBuilder?.call(ctx, null) ?? _placeholder(ctx);
      },
    );
  }
}

class CoverImage extends StatefulWidget {
  const CoverImage({
    super.key,
    this.imageUrl,
    this.mangaId,
    this.saturation = .7,
    this.fit,
    this.memCacheWidth = 360,
    this.memCacheHeight,
  });

  final String? imageUrl;
  final String? mangaId;
  final double saturation;
  final BoxFit? fit;
  final int? memCacheWidth;
  final int? memCacheHeight;

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  String? _resolvedUrl;
  bool _resolving = false;
  bool _triedRefreshOnError = false;
  int _retryGeneration = 0;

  @override
  void initState() {
    super.initState();
    _syncCoverState();
  }

  @override
  void didUpdateWidget(covariant CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.mangaId != widget.mangaId) {
      _resolvedUrl = null;
      _resolving = false;
      _triedRefreshOnError = false;
      _retryGeneration = 0;
      _syncCoverState();
    }
  }

  String? _normalizeUrl(String? raw) {
    if (raw == null) return null;
    var u = raw.trim();
    if (u.isEmpty) return null;
    if (u.startsWith('//')) u = 'https:$u';
    return u;
  }

  void _syncCoverState() {
    final direct = _normalizeUrl(widget.imageUrl);
    if (direct != null &&
        (direct.startsWith('http') ||
            direct.startsWith('file://') ||
            direct.startsWith('/'))) {
      if (widget.mangaId != null && widget.mangaId!.isNotEmpty) {
        ImageReferers.rememberResolvedCover(widget.mangaId!, direct);
      }
      return;
    }

    final cached = ImageReferers.getResolvedCover(widget.mangaId);
    if (cached != null && cached.isNotEmpty) {
      _resolvedUrl = _normalizeUrl(cached);
      return;
    }

    if (widget.mangaId != null && widget.mangaId!.isNotEmpty) {
      _resolveRemoteCover(force: false);
    }
  }

  void _resolveRemoteCover({required bool force}) {
    final id = widget.mangaId;
    if (id == null || id.isEmpty || _resolving) return;
    _resolving = true;
    ImageReferers.resolveCoverForManga(id, force: force).then((fresh) {
      if (!mounted) return;
      final normalized = _normalizeUrl(fresh);
      setState(() {
        _resolving = false;
        if (normalized != null &&
            normalized.isNotEmpty &&
            normalized != _resolvedUrl) {
          _resolvedUrl = normalized;
          _retryGeneration++;
          _triedRefreshOnError = false;
        }
      });
    }).catchError((_) {
      if (mounted) setState(() => _resolving = false);
    });
  }

  Widget _wrapSaturation(Widget child) {
    final filtered = (widget.saturation - 1.0).abs() < 0.01
        ? child
        : ColorFiltered(
            colorFilter: saturate(widget.saturation),
            child: child,
          );
    return RepaintBoundary(child: filtered);
  }

  @override
  Widget build(BuildContext context) {
    final effective = _normalizeUrl(_resolvedUrl ?? widget.imageUrl);

    if (effective == null) {
      return _CoverPlaceholder(loading: _resolving);
    }

    // Support offline local file covers (downloaded manga covers) seamlessly.
    if (!kIsWeb &&
        (effective.startsWith('file://') || effective.startsWith('/'))) {
      final path = effective.startsWith('file://')
          ? Uri.parse(effective).toFilePath()
          : effective;
      return _wrapSaturation(
        Image.file(
          File(path),
          fit: widget.fit ?? BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          cacheWidth: widget.memCacheWidth,
          cacheHeight: widget.memCacheHeight,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) {
            if (!_triedRefreshOnError &&
                widget.mangaId != null &&
                widget.mangaId!.isNotEmpty) {
              _triedRefreshOnError = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _resolveRemoteCover(force: true);
              });
            }
            return _CoverPlaceholder(loading: _resolving);
          },
        ),
      );
    }

    if (!effective.startsWith('http')) {
      return _CoverPlaceholder(loading: _resolving);
    }

    return _wrapSaturation(
      RetryingNetworkImage(
        key: ValueKey('${effective}_#$_retryGeneration'),
        url: effective,
        mangaId: widget.mangaId,
        fit: widget.fit ?? BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        memCacheWidth: widget.memCacheWidth,
        memCacheHeight: widget.memCacheHeight,
        errorBuilder: (_, retry) {
          if (!_triedRefreshOnError &&
              widget.mangaId != null &&
              widget.mangaId!.isNotEmpty) {
            _triedRefreshOnError = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _resolveRemoteCover(force: true);
            });
            return const _CoverPlaceholder(loading: true);
          }
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _triedRefreshOnError = false;
              _resolveRemoteCover(force: true);
              retry();
            },
            child: const _CoverPlaceholder(),
          );
        },
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({this.loading = false});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    const box = ColoredBox(
      color: AppColors.surfaceHigh,
      child: Center(
        child: Icon(
          Icons.auto_stories_outlined,
          color: AppColors.read,
          size: 24,
        ),
      ),
    );
    if (!loading) return box;
    return const ShimmerLoading(child: SizedBox.expand(child: box));
  }
}

/// Centered icon + title + message, used for empty and error states.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppColors.read),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppText.sheetTitle,
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(height: 1.5),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// The "Shiori" logo icon.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: Image.asset(
        'assets/logo.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }
}

class BarIcon extends StatelessWidget {
  const BarIcon(this.icon, {super.key, this.label, this.onTap, this.size = 22});
  final IconData icon;
  final String? label;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap ?? () {},
      tooltip: label,
      icon: Icon(icon, size: size),
      color: AppColors.text,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      padding: EdgeInsets.zero,
      splashRadius: 22,
    );
  }
}

class AppTopBar extends StatelessWidget {
  const AppTopBar({
    super.key,
    required this.title,
    this.branded = false,
    this.onBack,
    this.actions = const [],
    this.gradient = false,
    this.bottom,
  });

  final String title;
  final bool branded;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final bool gradient;
  final PreferredSizeWidget? bottom;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final bottomHeight = bottom?.preferredSize.height ?? 0;
    return Container(
      constraints: BoxConstraints(minHeight: 64 + top + bottomHeight),
      padding: EdgeInsets.fromLTRB(onBack != null ? 4 : 12, top + 8, 8, 0),
      decoration: gradient
          ? BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.bg.withValues(alpha: .7),
                  Colors.transparent,
                ],
              ),
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (onBack != null)
                BarIcon(Icons.arrow_back_rounded, label: 'Back', onTap: onBack),
              if (branded) ...[
                const BrandMark(size: 28),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.title,
                ),
              ),
              ...actions,
            ],
          ),
          ?bottom,
        ],
      ),
    );
  }
}

/// Smooth fade + micro-slide route transition used across detail, catalog, and reader screens.
Route<T> smoothRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 240),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.025),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}
