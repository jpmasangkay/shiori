import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:manga_reader/services/app_logger.dart';

/// Secure token storage wrapping [FlutterSecureStorage] (#7, #27)
/// with transparent migration from legacy [SharedPreferences] and
/// resilient in-memory fallback for test environments without platform channels.
class SecureTokenStore {
  SecureTokenStore._();
  static final SecureTokenStore instance = SecureTokenStore._();

  FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  final Map<String, String> _memoryFallback = {};
  bool _useMemoryFallback = false;

  void setStorageForTesting(FlutterSecureStorage storage) {
    _storage = storage;
    _useMemoryFallback = false;
  }

  void enableMemoryFallbackForTesting() {
    _useMemoryFallback = true;
  }

  Future<void> write(String key, String value) async {
    if (_useMemoryFallback) {
      _memoryFallback[key] = value;
      return;
    }
    try {
      await _storage.write(key: key, value: value);
      _memoryFallback[key] = value;
    } on MissingPluginException {
      _useMemoryFallback = true;
      _memoryFallback[key] = value;
    } catch (e, st) {
      AppLogger.warn('SecureTokenStore write failed for key $key, falling back to memory', e, st);
      _useMemoryFallback = true;
      _memoryFallback[key] = value;
    }
  }

  Future<String?> read(String key) async {
    if (_useMemoryFallback) {
      return _memoryFallback[key];
    }
    try {
      final val = await _storage.read(key: key);
      if (val != null) {
        _memoryFallback[key] = val;
        return val;
      }
      return _memoryFallback[key];
    } on MissingPluginException {
      _useMemoryFallback = true;
      return _memoryFallback[key];
    } catch (e, st) {
      AppLogger.warn('SecureTokenStore read failed for key $key, falling back to memory', e, st);
      _useMemoryFallback = true;
      return _memoryFallback[key];
    }
  }

  Future<void> delete(String key) async {
    _memoryFallback.remove(key);
    if (_useMemoryFallback) return;
    try {
      await _storage.delete(key: key);
    } on MissingPluginException {
      _useMemoryFallback = true;
    } catch (e, st) {
      AppLogger.warn('SecureTokenStore delete failed for key $key', e, st);
    }
  }

  Future<void> deleteAll() async {
    _memoryFallback.clear();
    if (_useMemoryFallback) return;
    try {
      await _storage.deleteAll();
    } on MissingPluginException {
      _useMemoryFallback = true;
    } catch (e, st) {
      AppLogger.warn('SecureTokenStore deleteAll failed', e, st);
    }
  }

  /// Migrates legacy plaintext tokens from [SharedPreferences] into secure storage (#7)
  Future<void> migrateLegacyPrefs(SharedPreferences prefs) async {
    const legacyKeys = ['auth_token', 'anilist_access_token'];
    for (final key in legacyKeys) {
      final legacyVal = prefs.getString(key);
      if (legacyVal != null && legacyVal.isNotEmpty) {
        final existing = await read(key);
        if (existing == null || existing.isEmpty) {
          await write(key, legacyVal);
        }
        await prefs.remove(key);
        AppLogger.info('Migrated legacy token $key to secure storage');
      }
    }
  }
}
