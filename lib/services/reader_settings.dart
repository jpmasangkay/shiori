import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ReaderSettings extends ChangeNotifier {
  ReaderSettings._();
  static final ReaderSettings instance = ReaderSettings._();

  static const _keyDefaultDirection = 'reader_default_direction';
  static const _keyFitMode = 'reader_fit_mode';
  static const _keyEnableTapZones = 'reader_enable_tap_zones';
  static const _keyInvertTapZones = 'reader_invert_tap_zones';
  static const _keyBrightness = 'reader_brightness';
  static const _keyTint = 'reader_tint';

  String defaultDirection = 'automatic';
  BoxFit fitMode = BoxFit.fitWidth;
  bool enableTapZones = true;
  bool invertTapZones = false;
  double brightness = 1.0;
  double tint = 0.0;

  SharedPreferences? _prefs;

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      defaultDirection = _prefs?.getString(_keyDefaultDirection) ?? 'automatic';
      final fitStr = _prefs?.getString(_keyFitMode);
      if (fitStr == 'contain') {
        fitMode = BoxFit.contain;
      } else {
        fitMode = BoxFit.fitWidth;
      }
      enableTapZones = _prefs?.getBool(_keyEnableTapZones) ?? true;
      invertTapZones = _prefs?.getBool(_keyInvertTapZones) ?? false;
      brightness = _prefs?.getDouble(_keyBrightness) ?? 1.0;
      tint = _prefs?.getDouble(_keyTint) ?? 0.0;
      notifyListeners();
    } catch (_) {}
  }

  String getReadingDirectionForManga(String mangaId) {
    if (mangaId.isNotEmpty) {
      final perManga = _prefs?.getString('reader_direction_$mangaId');
      if (perManga != null && perManga.isNotEmpty) return perManga;
    }
    return defaultDirection;
  }

  Future<void> setReadingDirection(String mangaId, String direction) async {
    defaultDirection = direction;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setString(_keyDefaultDirection, direction);
      if (mangaId.isNotEmpty) {
        await _prefs?.setString('reader_direction_$mangaId', direction);
      }
    } catch (_) {}
  }

  Future<void> setFitMode(BoxFit mode) async {
    fitMode = mode;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setString(_keyFitMode, mode == BoxFit.contain ? 'contain' : 'fitWidth');
    } catch (_) {}
  }

  Future<void> setEnableTapZones(bool val) async {
    enableTapZones = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyEnableTapZones, val);
    } catch (_) {}
  }

  Future<void> setInvertTapZones(bool val) async {
    invertTapZones = val;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool(_keyInvertTapZones, val);
    } catch (_) {}
  }

  Future<void> setBrightness(double val) async {
    brightness = val.clamp(0.2, 1.0);
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setDouble(_keyBrightness, brightness);
    } catch (_) {}
  }

  Future<void> setTint(double val) async {
    tint = val.clamp(0.0, 1.0);
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setDouble(_keyTint, tint);
    } catch (_) {}
  }
}

