import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';

/// Platform-specific background service management for continuous audio monitoring.
/// On Android, this uses a foreground service with notification.
/// On iOS, this would use background audio modes (not yet implemented).
abstract class BackgroundServiceManager {
  Future<void> startForegroundMonitoring();
  Future<void> stopForegroundMonitoring();
  Future<bool> isRunning();
}

/// No-op fallback for unsupported platforms.
class NoopBackgroundServiceManager implements BackgroundServiceManager {
  @override
  Future<void> startForegroundMonitoring() async {
    developer.log(
      'Background monitoring not available on this platform',
      name: 'background_service',
    );
  }

  @override
  Future<void> stopForegroundMonitoring() async {}

  @override
  Future<bool> isRunning() async => false;
}

/// Android implementation using foreground service via platform channel.
/// The actual service is implemented in AudioCaptureService.kt.
class AndroidBackgroundServiceManager implements BackgroundServiceManager {
  AndroidBackgroundServiceManager({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('cribcall/audio');

  final MethodChannel _channel;

  @override
  Future<void> startForegroundMonitoring() async {
    developer.log('Starting Android foreground service', name: 'background_service');
    try {
      await _channel.invokeMethod<void>('start');
      developer.log('Foreground service started', name: 'background_service');
    } on PlatformException catch (e) {
      developer.log(
        'Failed to start foreground service: ${e.message}',
        name: 'background_service',
      );
      rethrow;
    }
  }

  @override
  Future<void> stopForegroundMonitoring() async {
    developer.log('Stopping Android foreground service', name: 'background_service');
    try {
      await _channel.invokeMethod<void>('stop');
      developer.log('Foreground service stopped', name: 'background_service');
    } on PlatformException catch (e) {
      developer.log(
        'Failed to stop foreground service: ${e.message}',
        name: 'background_service',
      );
    }
  }

  @override
  Future<bool> isRunning() async {
    try {
      final running = await _channel.invokeMethod<bool>('isRunning');
      return running ?? false;
    } catch (e) {
      return false;
    }
  }
}

/// Factory to create the appropriate background service manager for the platform.
BackgroundServiceManager createBackgroundServiceManager() {
  if (Platform.isAndroid) {
    return AndroidBackgroundServiceManager();
  }
  // iOS and other platforms not yet implemented
  return NoopBackgroundServiceManager();
}

// ---------------------------------------------------------------------------
// Listener foreground service (keeps WebSocket connection alive)
// ---------------------------------------------------------------------------

/// Manager for the Listener foreground service.
/// This keeps the app alive to maintain WebSocket connection with the Monitor.
abstract class ListenerServiceManager {
  Future<void> startListening({required String monitorName});
  Future<void> stopListening();
}

/// No-op fallback for unsupported platforms.
class NoopListenerServiceManager implements ListenerServiceManager {
  @override
  Future<void> startListening({required String monitorName}) async {
    developer.log(
      'Listener service not available on this platform',
      name: 'listener_service',
    );
  }

  @override
  Future<void> stopListening() async {}
}

/// Android implementation using foreground service via platform channel.
class AndroidListenerServiceManager implements ListenerServiceManager {
  AndroidListenerServiceManager({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('cribcall/listener');

  final MethodChannel _channel;

  @override
  Future<void> startListening({required String monitorName}) async {
    developer.log(
      'Starting Android listener service for: $monitorName',
      name: 'listener_service',
    );
    try {
      await _channel.invokeMethod<void>('start', {'monitorName': monitorName});
      developer.log('Listener service started', name: 'listener_service');
    } on PlatformException catch (e) {
      developer.log(
        'Failed to start listener service: ${e.message}',
        name: 'listener_service',
      );
      // Don't rethrow - we can still work without foreground service
    }
  }

  @override
  Future<void> stopListening() async {
    developer.log('Stopping Android listener service', name: 'listener_service');
    try {
      await _channel.invokeMethod<void>('stop');
      developer.log('Listener service stopped', name: 'listener_service');
    } on PlatformException catch (e) {
      developer.log(
        'Failed to stop listener service: ${e.message}',
        name: 'listener_service',
      );
    }
  }
}

/// Factory to create the appropriate listener service manager for the platform.
ListenerServiceManager createListenerServiceManager() {
  if (Platform.isAndroid) {
    return AndroidListenerServiceManager();
  }
  // iOS and other platforms not yet implemented
  return NoopListenerServiceManager();
}
