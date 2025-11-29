import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../lifecycle/service_lifecycle.dart';

/// Callback type for notification responses.
typedef NotificationResponseCallback = void Function(NotificationResponse);

/// Singleton service for showing local notifications.
class NotificationService extends BaseManagedService {
  NotificationService._() : super('notifications', 'Notification Service');

  static final instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Callback for handling notification responses (taps and actions).
  /// Set this to handle navigation and pairing actions from notifications.
  NotificationResponseCallback? onNotificationResponse;

  // Noise alerts channel
  static const _channelId = 'cribcall_alerts';
  static const _channelName = 'Noise Alerts';
  static const _channelDescription = 'Notifications for detected noise events';

  // Pairing requests channel
  static const _pairingChannelId = 'cribcall_pairing';
  static const _pairingChannelName = 'Pairing Requests';
  static const _pairingChannelDescription =
      'Notifications for incoming pairing requests';
  static const _linuxDefaultActionName = 'Open notification';

  // Notification action IDs
  static const actionAccept = 'accept_pairing';
  static const actionDeny = 'deny_pairing';

  // Notification IDs
  static const pairingNotificationId = 1001;

  @override
  Future<void> onStart() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const linuxSettings = LinuxInitializationSettings(
      defaultActionName: _linuxDefaultActionName,
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      linux: linuxSettings,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Create the notification channels (Android 8.0+)
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      // Noise alerts channel
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

      // Pairing requests channel
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _pairingChannelId,
          _pairingChannelName,
          description: _pairingChannelDescription,
          importance: Importance.high,
          playSound: true,
          enableVibration: true,
        ),
      );
    }

    _log('Notification service initialized');
  }

  @override
  Future<void> onStop() async {
    // Cancel all notifications on shutdown
    await _plugin.cancelAll();
    _log('Notification service stopped');
  }

  /// Initialize the notification plugin.
  /// @deprecated Use start() instead via ServiceCoordinator.
  Future<void> initialize() async {
    if (state == ServiceLifecycleState.running) return;
    await start();
  }

  /// Show a noise alert notification.
  Future<void> showNoiseAlert({
    required String monitorName,
    required int peakLevel,
  }) async {
    if (state != ServiceLifecycleState.running) {
      await start();
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

    const linuxDetails = LinuxNotificationDetails(
      defaultActionName: _linuxDefaultActionName,
      urgency: LinuxNotificationUrgency.critical,
      category: LinuxNotificationCategory.device,
    );

    const details = NotificationDetails(
      android: androidDetails,
      linux: linuxDetails,
    );

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

  /// Show a pairing request notification.
  /// [listenerName] is the name of the device requesting to pair.
  /// [comparisonCode] is the 6-digit code to verify.
  /// [sessionId] is used to identify the pairing session for actions.
  Future<void> showPairingRequest({
    required String listenerName,
    required String comparisonCode,
    required String sessionId,
  }) async {
    if (state != ServiceLifecycleState.running) {
      await start();
    }

    // Encode session info in payload for action handling
    final payload = jsonEncode({
      'type': 'pairing',
      'sessionId': sessionId,
      'listenerName': listenerName,
    });

    const androidDetails = AndroidNotificationDetails(
      _pairingChannelId,
      _pairingChannelName,
      channelDescription: _pairingChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      category: AndroidNotificationCategory.social,
      // Use ongoing to make it sticky until user responds
      ongoing: true,
      autoCancel: false,
      // Add action buttons
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          actionAccept,
          'Accept',
          showsUserInterface: true,
        ),
        AndroidNotificationAction(
          actionDeny,
          'Deny',
          cancelNotification: true,
        ),
      ],
    );

    const linuxDetails = LinuxNotificationDetails(
      defaultActionName: _linuxDefaultActionName,
      category: LinuxNotificationCategory.network,
      timeout: LinuxNotificationTimeout.expiresNever(),
      resident: true,
      urgency: LinuxNotificationUrgency.normal,
    );

    const details = NotificationDetails(
      android: androidDetails,
      linux: linuxDetails,
    );

    await _plugin.show(
      pairingNotificationId,
      'Pairing Request',
      '$listenerName wants to pair. Code: $comparisonCode',
      details,
      payload: payload,
    );

    _log('Showed pairing request notification for $listenerName');
  }

  /// Cancel the pairing request notification.
  Future<void> cancelPairingRequest() async {
    await _plugin.cancel(pairingNotificationId);
    _log('Cancelled pairing request notification');
  }

  void _onNotificationTapped(NotificationResponse response) {
    _log(
      'Notification response: actionId=${response.actionId}, '
      'payload=${response.payload}',
    );
    // Forward to the registered callback
    onNotificationResponse?.call(response);
  }

  void _log(String message) {
    developer.log(message, name: 'notification_service');
  }
}
