import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:manga_reader/models/manga_models.dart';
import 'package:manga_reader/services/app_logger.dart';
import 'package:manga_reader/services/secure_token_store.dart';

/// Service managing user authentication, secure token storage, and session lifetime (#7, #8, #36, #38)
class AuthService extends ChangeNotifier {
  final SecureTokenStore _tokenStore;
  final http.Client Function() _clientProvider;
  final String Function() _baseUrlProvider;

  SharedPreferences? _cachedPrefs;
  String? _token;
  UserAccount? _currentUser;
  bool _sessionExpired = false;

  AuthService({
    required this._clientProvider,
    required this._baseUrlProvider,
    SecureTokenStore? tokenStore,
  })  : _tokenStore = tokenStore ?? SecureTokenStore.instance;

  http.Client get _client => _clientProvider();
  String get _baseUrl => _baseUrlProvider();

  String? get token => _token;
  UserAccount? get currentUser => _currentUser;
  bool get isLoggedIn => _token != null && _currentUser != null;
  bool get isSessionExpired => _sessionExpired;

  void clearSessionExpiredBanner() {
    if (_sessionExpired) {
      _sessionExpired = false;
      notifyListeners();
    }
  }

  void handleUnauthorized() {
    if (!_sessionExpired && isLoggedIn) {
      _sessionExpired = true;
      AppLogger.warn('Session expired or unauthorized for user ${_currentUser?.email}');
      notifyListeners();
    }
  }

  Map<String, String> headers({bool withAuth = true}) {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (withAuth && _token != null && _token!.isNotEmpty) {
      h['Authorization'] = 'Bearer $_token';
    }
    return h;
  }

  /// Initialize and load persisted auth session (#3, #7, #36)
  Future<void> init(SharedPreferences prefs) async {
    _cachedPrefs = prefs;

    // Migrate any legacy SharedPreferences plaintext tokens into SecureTokenStore (#7)
    await _tokenStore.migrateLegacyPrefs(prefs);

    _token = await _tokenStore.read('auth_token');
    _currentUser = null;

    final userJson = prefs.getString('auth_user');
    if (userJson != null) {
      try {
        final decoded = jsonDecode(userJson);
        if (decoded is Map<String, dynamic>) {
          _currentUser = UserAccount.fromJson(decoded);
        }
      } catch (e) {
        AppLogger.warn('Failed to parse cached auth_user', e);
      }
    }

    // Proactive JWT expiration check (#36)
    if (_token != null && _token!.isNotEmpty) {
      _checkJwtExpiration(_token!);
    }
  }

  void _checkJwtExpiration(String token) {
    try {
      final parts = token.split('.');
      if (parts.length >= 2) {
        final normalized = base64Url.normalize(parts[1]);
        final payloadStr = utf8.decode(base64Url.decode(normalized));
        final payload = jsonDecode(payloadStr) as Map<String, dynamic>;
        final exp = payload['exp'];
        if (exp is num) {
          final expDate = DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
          if (DateTime.now().isAfter(expDate)) {
            _sessionExpired = true;
            AppLogger.warn('Cached JWT is expired (exp: $expDate)');
          }
        }
      }
    } catch (_) {}
  }

  Future<void> register(String email, String password, {String? displayName}) async {
    final trimmedEmail = email.trim();
    if (trimmedEmail.isEmpty || password.isEmpty) {
      throw Exception('Please fill in email and password.');
    }

    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_baseUrl/auth/register'),
            headers: headers(withAuth: false),
            body: jsonEncode({
              'email': trimmedEmail,
              'password': password,
              if (displayName != null && displayName.trim().isNotEmpty)
                'displayName': displayName.trim(),
            }),
          )
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw Exception('Connection timed out. Server may be unreachable.');
    } catch (e) {
      throw Exception('Network error: Unable to reach server.');
    }

    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception(_extractAuthError(res, fallback: 'Registration failed'));
    }

    final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) throw const FormatException('Not a JSON object');
      data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      throw Exception('Invalid response from server.');
    }

    final token = data['token']?.toString() ?? '';
    final userRaw = data['user'];
    if (token.isEmpty || userRaw is! Map) {
      throw Exception('Invalid authentication payload from server.');
    }

    await saveAuthData(token, UserAccount.fromJson(Map<String, dynamic>.from(userRaw)));
  }

  Future<void> login(String email, String password) async {
    final trimmedEmail = email.trim();
    if (trimmedEmail.isEmpty || password.isEmpty) {
      throw Exception('Please fill in email and password.');
    }

    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_baseUrl/auth/login'),
            headers: headers(withAuth: false),
            body: jsonEncode({'email': trimmedEmail, 'password': password}),
          )
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw Exception('Connection timed out. Server may be unreachable.');
    } catch (e) {
      throw Exception('Network error: Unable to reach server.');
    }

    if (res.statusCode != 200) {
      throw Exception(_extractAuthError(res, fallback: 'Login failed'));
    }

    final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) throw const FormatException('Not a JSON object');
      data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      throw Exception('Invalid response from server.');
    }

    final token = data['token']?.toString() ?? '';
    final userRaw = data['user'];
    if (token.isEmpty || userRaw is! Map) {
      throw Exception('Invalid authentication payload from server.');
    }

    await saveAuthData(token, UserAccount.fromJson(Map<String, dynamic>.from(userRaw)));
  }

  /// Refreshes session token with server (#8, #36)
  Future<bool> refreshSession() async {
    if (_token == null || _token!.isEmpty) return false;
    try {
      final res = await _client.post(
        Uri.parse('$_baseUrl/auth/refresh'),
        headers: headers(withAuth: true),
      ).timeout(const Duration(seconds: 8));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final newToken = data['token']?.toString();
        final userRaw = data['user'];
        if (newToken != null && newToken.isNotEmpty) {
          final user = userRaw is Map
              ? UserAccount.fromJson(Map<String, dynamic>.from(userRaw))
              : (_currentUser ?? UserAccount(id: '', email: '', displayName: ''));
          await saveAuthData(newToken, user);
          _sessionExpired = false;
          return true;
        }
      }
    } catch (e) {
      AppLogger.warn('Refresh session call failed', e);
    }
    return false;
  }

  /// Saves auth state using SecureTokenStore for tokens and cached SharedPreferences (#3, #7)
  Future<void> saveAuthData(String token, UserAccount user) async {
    _token = token;
    _currentUser = user;
    _sessionExpired = false;

    await _tokenStore.write('auth_token', token);

    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.setString(
      'auth_user',
      jsonEncode({'id': user.id, 'email': user.email, 'displayName': user.displayName}),
    );
    notifyListeners();
  }

  /// Sign out with option to clear local library & history (#38)
  Future<void> logout({
    bool clearLocalData = false,
    Future<void> Function()? onClearLocalData,
  }) async {
    _token = null;
    _currentUser = null;
    _sessionExpired = false;

    await _tokenStore.delete('auth_token');

    final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();
    await prefs.remove('auth_user');

    if (clearLocalData && onClearLocalData != null) {
      await onClearLocalData();
    }

    notifyListeners();
  }

  static String _extractAuthError(http.Response res, {required String fallback}) {
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map) {
        final msg = (decoded['error'] ?? decoded['message'])?.toString().trim();
        if (msg != null && msg.isNotEmpty) return msg;
      }
    } catch (_) {}
    if (res.statusCode == 409) return 'Email is already registered';
    if (res.statusCode == 401) return 'Invalid email or password';
    if (res.statusCode == 429) return 'Too many attempts. Please try again later.';
    if (res.statusCode >= 500) return 'Server error (${res.statusCode}). Please try again later.';
    return fallback;
  }
}
