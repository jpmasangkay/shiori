import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Unified native platform bridge (`com.example.manga_reader/platform`) for
/// Android/platform capabilities that avoid third-party AGP plugin fragility:
/// - Keep screen on (`FLAG_KEEP_SCREEN_ON`)
/// - Secure screen (`FLAG_SECURE` — hides recents preview & blocks screenshots)
/// - Hardware volume key interception for reader page turning
/// - Biometric / device credential authentication (`BiometricPrompt`)
/// - DNS-over-HTTPS provider selection for OkHttp extension client
/// - Storage Access Framework (SAF) file export/import & native file share
/// - Background download foreground notifications & WorkManager scheduling
class PlatformBridge {
  PlatformBridge._();
  static final PlatformBridge instance = PlatformBridge._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.manga_reader/platform',
  );

  final StreamController<String> _volumeKeyController =
      StreamController<String>.broadcast();
  bool _handlerBound = false;

  /// Emits `'up'` or `'down'` when volume key interception is active.
  Stream<String> get volumeKeyStream {
    _ensureHandlerBound();
    return _volumeKeyController.stream;
  }

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  void _ensureHandlerBound() {
    if (_handlerBound) return;
    _handlerBound = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onVolumeKey') {
        final dir = call.arguments?.toString() ?? '';
        if (dir == 'up' || dir == 'down') {
          _volumeKeyController.add(dir);
        }
      }
      return null;
    });
  }

  Future<void> setKeepScreenOn(bool enabled) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('setKeepScreenOn', {'enabled': enabled});
    } catch (_) {}
  }

  Future<void> setSecureScreen(bool enabled) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('setSecureScreen', {'enabled': enabled});
    } catch (_) {}
  }

  Future<void> setVolumeKeyIntercept(bool enabled) async {
    _ensureHandlerBound();
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('setVolumeKeyIntercept', {'enabled': enabled});
    } catch (_) {}
  }

  Future<bool> canAuthenticateBiometric() async {
    if (!_isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('canAuthenticateBiometric');
      return res == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticateBiometric({
    String title = 'Unlock Shiori',
    String subtitle = 'Authenticate to access your library',
  }) async {
    if (!_isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('authenticateBiometric', {
        'title': title,
        'subtitle': subtitle,
      });
      return res == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> setDohProvider(String provider) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('setDohProvider', {'provider': provider});
    } catch (_) {}
  }

  Future<String> getDohProvider() async {
    if (!_isAndroid) return 'none';
    try {
      final res = await _channel.invokeMethod<String>('getDohProvider');
      return res ?? 'none';
    } catch (_) {
      return 'none';
    }
  }

  /// Writes [bytes] to a user-chosen file via Android SAF (`ACTION_CREATE_DOCUMENT`).
  /// Returns the saved URI/path string, or `null` if cancelled or unsupported.
  Future<String?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String mimeType = 'application/octet-stream',
  }) async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('saveFile', {
        'fileName': fileName,
        'mimeType': mimeType,
        'bytes': bytes,
      });
    } catch (_) {
      return null;
    }
  }

  /// Lets the user pick a file via Android SAF (`ACTION_OPEN_DOCUMENT`) and returns its bytes.
  Future<({String name, Uint8List bytes})?> pickFile({
    List<String> mimeTypes = const ['*/*'],
  }) async {
    if (!_isAndroid) return null;
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('pickFile', {
        'mimeTypes': mimeTypes,
      });
      if (raw == null) return null;
      final bytes = raw['bytes'];
      if (bytes is Uint8List) {
        return (name: raw['name']?.toString() ?? 'backup', bytes: bytes);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> shareFile({
    required String filePath,
    String mimeType = '*/*',
    String? subject,
  }) async {
    if (!_isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('shareFile', {
        'filePath': filePath,
        'mimeType': mimeType,
        'subject': subject ?? 'Shiori',
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> updateDownloadNotification({
    required String title,
    required String body,
    required int progress,
    required int max,
    bool ongoing = true,
  }) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('updateDownloadNotification', {
        'title': title,
        'body': body,
        'progress': progress,
        'max': max,
        'ongoing': ongoing,
      });
    } catch (_) {}
  }

  Future<void> cancelDownloadNotification() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('cancelDownloadNotification');
    } catch (_) {}
  }

  /// Queries an Android `ConfigurableSource` extension for its preference items.
  Future<List<Map<String, dynamic>>> getExtensionPreferences(String pkg) async {
    if (!_isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'getExtensionPreferences',
        {'pkg': pkg},
      );
      if (raw == null) return const [];
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Persists an updated preference value into an Android extension's SharedPreferences.
  Future<bool> setExtensionPreference({
    required String pkg,
    required String key,
    required dynamic value,
    required String type,
  }) async {
    if (!_isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('setExtensionPreference', {
        'pkg': pkg,
        'key': key,
        'value': value,
        'type': type,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// Fetches the extension's dynamic `FilterList` schema for source filtering UI.
  Future<List<Map<String, dynamic>>> getExtensionFilters(String pkg) async {
    if (!_isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'getExtensionFilters',
        {'pkg': pkg},
      );
      if (raw == null) return const [];
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Searches an Android extension with explicit serialized filter values.
  Future<List<Map<String, dynamic>>> searchExtensionWithFilters({
    required String pkg,
    required String query,
    required int page,
    required List<Map<String, dynamic>> filters,
  }) async {
    if (!_isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'searchExtensionWithFilters',
        {
          'pkg': pkg,
          'query': query,
          'page': page,
          'filters': filters,
        },
      );
      if (raw == null) return const [];
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
