import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:manga_reader/services/app_logger.dart';

/// Service monitoring network connectivity and notifying UI (#28)
class ConnectivityService extends ChangeNotifier {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  bool _isOffline = false;
  bool get isOffline => _isOffline;

  bool _initialized = false;
  bool _mockMode = false;

  Future<void> init() async {
    if (_initialized || _mockMode) return;
    _initialized = true;

    try {
      final results = await _connectivity.checkConnectivity();
      _updateStatus(results);
    } on MissingPluginException {
      _mockMode = true;
      _isOffline = false;
    } catch (e, st) {
      AppLogger.warn('Connectivity initial check failed', e, st);
      _isOffline = false;
    }

    try {
      _subscription = _connectivity.onConnectivityChanged.listen(
        _updateStatus,
        onError: (err) {
          AppLogger.warn('Connectivity stream error: $err');
        },
      );
    } catch (_) {
      // Ignored in headless tests
    }
  }

  void _updateStatus(List<ConnectivityResult> results) {
    if (_mockMode) return;
    final offline = results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (_isOffline != offline) {
      _isOffline = offline;
      notifyListeners();
    }
  }

  Future<void> recheck() async {
    if (_mockMode) return;
    try {
      final results = await _connectivity.checkConnectivity();
      _updateStatus(results);
    } catch (e) {
      AppLogger.warn('Connectivity recheck failed: $e');
    }
  }

  void setOfflineForTesting(bool offline) {
    _mockMode = true;
    _isOffline = offline;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

