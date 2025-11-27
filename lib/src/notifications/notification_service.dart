import 'dart:developer' as developer;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Singleton service for showing local notifications.
class NotificationService {
  NotificationService._();

  static final instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  static const _channelId = 'cribcall_alerts';
  static const _channelName = 'Noise Alerts';
  static const _channelDescription = 'Notifications for detected noise events';

  /// Initialize the notification plugin.
  /// Call this early in app startup.
  Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Create the notification channel (Android 8.0+)
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDescription,
          importance: Importance.high,
          playSound: true,
          enableVibration: true,
        ),
      );
    }

    _initialized = true;
    _log('Notification service initialized');
  }

  /// Show a noise alert notification.
  Future<void> showNoiseAlert({
    required String monitorName,
    required int peakLevel,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      category: AndroidNotificationCategory.alarm,
    );

    const details = NotificationDetails(android: androidDetails);

    // Use timestamp as notification ID to allow multiple notifications
    final notificationId = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    await _plugin.show(
      notificationId,
      'Noise Detected',
      monitorName,
      details,
    );

    _log('Showed noise alert notification for $monitorName');
  }

  void _onNotificationTapped(NotificationResponse response) {
    _log('Notification tapped: ${response.payload}');
    // App will be brought to foreground automatically
  }

  void _log(String message) {
    developer.log(message, name: 'notification_service');
  }
}
