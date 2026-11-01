import 'package:flutter/foundation.dart';

typedef ErrorReporter = void Function(String message, Object? error, StackTrace? stackTrace);

/// Application logger replacing silent catch blocks and ad-hoc print calls (#9)
class AppLogger {
  const AppLogger._();

  static ErrorReporter? customReporter;

  static void debug(String message, [Object? error, StackTrace? stackTrace]) {
    if (kDebugMode) {
      debugPrint('[DEBUG] $message${error != null ? ' - $error' : ''}');
      if (stackTrace != null) {
        debugPrint(stackTrace.toString());
      }
    }
  }

  static void info(String message) {
    if (kDebugMode) {
      debugPrint('[INFO] $message');
    }
  }

  static void warn(String message, [Object? error, StackTrace? stackTrace]) {
    debugPrint('[WARN] $message${error != null ? ' - $error' : ''}');
    if (stackTrace != null && kDebugMode) {
      debugPrint(stackTrace.toString());
    }
    customReporter?.call(message, error, stackTrace);
  }

  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    debugPrint('[ERROR] $message${error != null ? ' - $error' : ''}');
    if (stackTrace != null) {
      debugPrint(stackTrace.toString());
    }
    customReporter?.call(message, error, stackTrace);
  }
}

