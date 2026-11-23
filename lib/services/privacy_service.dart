import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:manga_reader/services/platform_bridge.dart';
import 'package:manga_reader/services/secure_token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages user privacy controls: Incognito Mode, Secure Screen (`FLAG_SECURE`),
/// App Lock (Biometric + SHA-256 salted PIN fallback), and DNS-over-HTTPS preference.
class PrivacyService extends ChangeNotifier {
  PrivacyService._();
  static final PrivacyService instance = PrivacyService._();

  static const _keyIncognito = 'shiori_incognito_mode';
  static const _keySecureScreen = 'shiori_secure_screen';
  static const _keyAppLockEnabled = 'shiori_app_lock_enabled';
  static const _keyUseBiometric = 'shiori_app_lock_biometric';
  static const _keyLockTimeoutSec = 'shiori_app_lock_timeout_sec';
  static const _keyDohProvider = 'shiori_doh_provider';
  static const _keyPinHash = 'shiori_app_lock_pin_hash_v1';

  bool _incognitoMode = false;
  bool _secureScreen = false;
  bool _appLockEnabled = false;
  bool _useBiometric = true;
  int _lockTimeoutSeconds = 0; // 0 = immediately on resume
  String _dohProvider = 'none';
  bool _isLocked = false;
  bool _hasPin = false;
  DateTime? _lastBackgroundedAt;
  SharedPreferences? _prefs;

  bool get incognitoMode => _incognitoMode;
  bool get secureScreen => _secureScreen;
  bool get appLockEnabled => _appLockEnabled;
  bool get useBiometric => _useBiometric;
  int get lockTimeoutSeconds => _lockTimeoutSeconds;
  String get dohProvider => _dohProvider;
  bool get isLocked => _isLocked;
  bool get hasPin => _hasPin;

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _incognitoMode = _prefs?.getBool(_keyIncognito) ?? false;
      _secureScreen = _prefs?.getBool(_keySecureScreen) ?? false;
      _appLockEnabled = _prefs?.getBool(_keyAppLockEnabled) ?? false;
      _useBiometric = _prefs?.getBool(_keyUseBiometric) ?? true;
      _lockTimeoutSeconds = _prefs?.getInt(_keyLockTimeoutSec) ?? 0;
      _dohProvider = _prefs?.getString(_keyDohProvider) ?? 'none';

      final pinHash = await SecureTokenStore.instance.read(_keyPinHash);
      _hasPin = pinHash != null && pinHash.isNotEmpty;
      _isLocked = _appLockEnabled;

      await PlatformBridge.instance.setSecureScreen(_secureScreen);
      if (_dohProvider != 'none') {
        await PlatformBridge.instance.setDohProvider(_dohProvider);
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setIncognitoMode(bool enabled) async {
    _incognitoMode = enabled;
    notifyListeners();
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setBool(_keyIncognito, enabled);
  }

  Future<void> setSecureScreen(bool enabled) async {
    _secureScreen = enabled;
    notifyListeners();
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setBool(_keySecureScreen, enabled);
    await PlatformBridge.instance.setSecureScreen(enabled);
  }

  Future<void> setAppLockEnabled(bool enabled) async {
    _appLockEnabled = enabled;
    if (!enabled) _isLocked = false;
    notifyListeners();
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setBool(_keyAppLockEnabled, enabled);
  }

  Future<void> setUseBiometric(bool enabled) async {
    _useBiometric = enabled;
    notifyListeners();
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setBool(_keyUseBiometric, enabled);
  }

  Future<void> setLockTimeoutSeconds(int seconds) async {
    _lockTimeoutSeconds = seconds.clamp(0, 3600);
    notifyListeners();
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setInt(_keyLockTimeoutSec, _lockTimeoutSeconds);
  }

  Future<void> setDohProvider(String provider) async {
    const allowed = {'none', 'cloudflare', 'google', 'quad9', 'adguard'};
    final safe = allowed.contains(provider) ? provider : 'none';
    _dohProvider = safe;
    notifyListeners();
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setString(_keyDohProvider, safe);
    await PlatformBridge.instance.setDohProvider(safe);
  }

  static String _hashPin(String pin) {
    return sha256.convert(utf8.encode('shiori_pin_v1::$pin')).toString();
  }

  Future<void> setPin(String pin) async {
    final trimmed = pin.trim();
    if (trimmed.length < 4) return;
    await SecureTokenStore.instance.write(_keyPinHash, _hashPin(trimmed));
    _hasPin = true;
    notifyListeners();
  }

  Future<void> clearPin() async {
    await SecureTokenStore.instance.delete(_keyPinHash);
    _hasPin = false;
    notifyListeners();
  }

  Future<bool> verifyPin(String pin) async {
    final stored = await SecureTokenStore.instance.read(_keyPinHash);
    if (stored == null || stored.isEmpty) return false;
    final ok = stored == _hashPin(pin.trim());
    if (ok) {
      _isLocked = false;
      notifyListeners();
    }
    return ok;
  }

  Future<bool> unlockWithBiometric() async {
    final ok = await PlatformBridge.instance.authenticateBiometric();
    if (ok) {
      _isLocked = false;
      notifyListeners();
    }
    return ok;
  }

  void unlockForTesting() {
    _isLocked = false;
    notifyListeners();
  }

  void onAppBackgrounded() {
    _lastBackgroundedAt = DateTime.now();
  }

  void onAppResumed() {
    if (!_appLockEnabled) return;
    if (_lastBackgroundedAt == null) {
      _isLocked = true;
      notifyListeners();
      return;
    }
    final elapsed = DateTime.now().difference(_lastBackgroundedAt!).inSeconds;
    if (elapsed >= _lockTimeoutSeconds) {
      _isLocked = true;
      notifyListeners();
    }
  }
}
