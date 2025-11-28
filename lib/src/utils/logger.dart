/// Centralized logging utility for the application.
///
/// Provides consistent logging across all modules with proper tag management.
library;

import 'dart:developer' as developer;

import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';

/// Log a message with a specific tag/name.
///
/// This combines both `developer.log` (for DevTools) and `debugPrint`
/// (for console output) in a consistent format.
///
/// Example:
/// ```dart
/// log('Server started on port 8080', name: 'control_server');
/// // Output: [control_server] Server started on port 8080
/// ```
void log(String message, {required String name}) {
  developer.log(message, name: name);
  debugPrint('[$name] $message');
}

/// Logger instance for a specific module.
///
/// Create one per file/module for consistent logging:
/// ```dart
/// final _log = Logger('control_server');
/// _log('Server started'); // -> [control_server] Server started
/// ```
class Logger {
  const Logger(this.name);

  final String name;

  /// Log a message using this logger's name.
  void call(String message) => log(message, name: name);

  /// Log a message with additional context.
  void context(String message, Map<String, dynamic> ctx) {
    final ctxStr = ctx.entries.map((e) => '${e.key}=${e.value}').join(' ');
    call('$message $ctxStr');
  }
}
