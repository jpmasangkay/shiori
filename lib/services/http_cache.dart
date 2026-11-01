import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:manga_reader/services/app_logger.dart';

class _CacheEntry {
  final dynamic data;
  final DateTime expiresAt;

  _CacheEntry(this.data, this.expiresAt);

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// O(1) LRU response cache with in-flight GET deduplication (#12)
class LruHttpCache {
  final int capacity;
  final LinkedHashMap<String, _CacheEntry> _cache = LinkedHashMap<String, _CacheEntry>();
  final Map<String, Future<dynamic>> _inflight = {};

  LruHttpCache({this.capacity = 150});

  dynamic get(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    if (entry.isExpired) {
      _cache.remove(key);
      return null;
    }
    // Re-insert to mark as most recently used (MRU)
    _cache.remove(key);
    _cache[key] = entry;
    return entry.data;
  }

  void put(String key, dynamic data, {Duration ttl = const Duration(minutes: 15)}) {
    if (_cache.containsKey(key)) {
      _cache.remove(key);
    } else if (_cache.length >= capacity) {
      // Remove least recently used (first element) in O(1)
      final oldestKey = _cache.keys.first;
      _cache.remove(oldestKey);
    }
    _cache[key] = _CacheEntry(data, DateTime.now().add(ttl));
  }

  Future<T> deduplicate<T>(String key, Future<T> Function() fetcher) {
    final cached = get(key);
    if (cached != null && cached is T) {
      return Future.value(cached);
    }

    if (_inflight.containsKey(key)) {
      return _inflight[key]!.then((res) => res as T);
    }

    final future = fetcher().then((res) {
      _inflight.remove(key);
      return res;
    }).catchError((err, st) {
      _inflight.remove(key);
      throw err;
    });

    _inflight[key] = future;
    return future;
  }

  void remove(String key) {
    _cache.remove(key);
    _inflight.remove(key);
  }

  void clear() {
    _cache.clear();
    _inflight.clear();
  }

  int get length => _cache.length;
}

/// Custom Dio HttpClientAdapter that forwards calls through an underlying [http.Client] (#29)
/// ensuring full testability when MockClient is injected into ApiService.
class HttpClientToDioAdapter implements HttpClientAdapter {
  final http.Client Function() _clientProvider;

  HttpClientToDioAdapter(this._clientProvider);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final client = _clientProvider();
    final uri = options.uri;

    final request = http.Request(options.method, uri);
    options.headers.forEach((k, v) {
      if (v != null) request.headers[k] = v.toString();
    });

    if (options.data != null) {
      if (options.data is String) {
        request.body = options.data as String;
      } else if (options.data is Map || options.data is List) {
        request.body = jsonEncode(options.data);
        request.headers['content-type'] ??= 'application/json; charset=utf-8';
      } else if (options.data is List<int>) {
        request.bodyBytes = options.data as List<int>;
      }
    } else if (requestStream != null) {
      final bytes = <int>[];
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
      request.bodyBytes = bytes;
    }

    final streamedResponse = await client.send(request);
    final responseHeaders = <String, List<String>>{};
    streamedResponse.headers.forEach((k, v) {
      responseHeaders[k] = [v];
    });

    return ResponseBody(
      streamedResponse.stream.cast<Uint8List>(),
      streamedResponse.statusCode,
      headers: responseHeaders,
      statusMessage: streamedResponse.reasonPhrase,
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Central HTTP Manager combining Dio, raw http.Client, O(1) LRU caching,
/// auth header injection, and 401 JWT expiration callback (#8, #12, #29, #36).
class HttpManager {
  http.Client _rawHttpClient = http.Client();
  final LruHttpCache cache = LruHttpCache();
  late final Dio dio;

  String? Function()? tokenProvider;
  void Function()? onUnauthorized;

  HttpManager({
    this.tokenProvider,
    this.onUnauthorized,
    http.Client? initialClient,
  }) {
    if (initialClient != null) {
      _rawHttpClient = initialClient;
    }
    dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 25),
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'Shiori/1.0',
        },
      ),
    );

    dio.httpClientAdapter = HttpClientToDioAdapter(() => _rawHttpClient);

    // Auth and 401 interceptor
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final token = tokenProvider?.call();
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          return handler.next(options);
        },
        onError: (DioException err, handler) {
          if (err.response?.statusCode == 401) {
            AppLogger.warn('HTTP 401 received: triggering session expiration handler');
            onUnauthorized?.call();
          }
          return handler.next(err);
        },
      ),
    );
  }

  http.Client get client => _rawHttpClient;

  void setClient(http.Client? client) {
    _rawHttpClient = client ?? http.Client();
  }

  void clearCache() {
    cache.clear();
  }
}

