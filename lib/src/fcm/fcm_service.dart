import 'dart:async';
import 'dart:developer' as developer;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../lifecycle/service_lifecycle.dart';
import '../notifications/notification_service.dart';

/// Data extracted from an FCM noise event message.
class NoiseEventData {
  const NoiseEventData({
    required this.remoteDeviceId,
    required this.monitorName,
    required this.timestamp,
    required this.peakLevel,
  });

  final String remoteDeviceId;
  final String monitorName;
  final int timestamp;
  final int peakLevel;

  /// Unique ID for deduplication: "{remoteDeviceId}-{timestamp}"
  String get eventId => '$remoteDeviceId-$timestamp';
}

/// Background message handler - must be top-level function.
/// This is called when the app is in background or terminated.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  developer.log(
    'Background FCM message: ${message.data}',
    name: 'fcm_service',
  );

  // Show local notification for noise events
  final data = message.data;
  final type = data['type'] as String?;
  if (type == 'NOISE_EVENT') {
    final monitorName = data['monitorName'] as String? ?? 'Monitor';
    final peakLevel = int.tryParse(data['peakLevel']?.toString() ?? '') ?? 0;

    await NotificationService.instance.showNoiseAlert(
      monitorName: monitorName,
      peakLevel: peakLevel,
    );
  }
}

/// Singleton service for handling Firebase Cloud Messaging.
class FcmService extends BaseManagedService {
  FcmService._() : super('fcm', 'FCM Service');

  static final instance = FcmService._();

  FirebaseMessaging? _messaging;
  String? _currentToken;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundMessageSubscription;
  StreamSubscription<RemoteMessage>? _messageOpenedAppSubscription;

  /// Callback for noise events received via FCM.
  /// Set this to handle incoming noise events.
  void Function(NoiseEventData event)? onNoiseEvent;

  @override
  Future<void> onStart() async {
    await Firebase.initializeApp();
    _messaging = FirebaseMessaging.instance;

    // Request permission (Android 13+ requires explicit permission)
    final settings = await _messaging!.requestPermission(
      alert: true,
      badge: false,
      sound: true,
      provisional: false,
    );
    developer.log(
      'FCM permission status: ${settings.authorizationStatus}',
      name: 'fcm_service',
    );

    // Get initial token
    _currentToken = await _messaging!.getToken();
    developer.log('FCM token: $_currentToken', name: 'fcm_service');

    // Listen for token refresh
    _tokenRefreshSubscription = _messaging!.onTokenRefresh.listen(_handleTokenRefresh);

    // Set up message handlers
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    _foregroundMessageSubscription = FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    _messageOpenedAppSubscription = FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);

    // Check for initial message (app launched from notification tap)
    final initialMessage = await _messaging!.getInitialMessage();
    if (initialMessage != null) {
      _handleMessage(initialMessage.data);
    }
  }

  @override
  Future<void> onStop() async {
    await _tokenRefreshSubscription?.cancel();
    await _foregroundMessageSubscription?.cancel();
    await _messageOpenedAppSubscription?.cancel();
    _tokenRefreshSubscription = null;
    _foregroundMessageSubscription = null;
    _messageOpenedAppSubscription = null;
    _messaging = null;
    _currentToken = null;
    developer.log('FCM service stopped', name: 'fcm_service');
  }

  /// Initialize Firebase and FCM.
  /// @deprecated Use start() instead via ServiceCoordinator.
  Future<void> initialize() async {
    if (state == ServiceLifecycleState.running) return;
    await start();
  }

  /// Current FCM token. May be null if not yet initialized or permission denied.
  String? get currentToken => _currentToken;

  /// Whether FCM has been initialized.
  bool get isInitialized => state == ServiceLifecycleState.running;

  void _handleTokenRefresh(String newToken) {
    developer.log('FCM token refreshed: $newToken', name: 'fcm_service');
    _currentToken = newToken;
    // Notify listeners of token change
    for (final callback in _onTokenRefreshCallbacks) {
      callback(newToken);
    }
  }

  final List<void Function(String)> _onTokenRefreshCallbacks = [];

  /// Register a callback for FCM token refresh events.
  void addTokenRefreshListener(void Function(String) callback) {
    _onTokenRefreshCallbacks.add(callback);
  }

  /// Unregister a token refresh callback.
  void removeTokenRefreshListener(void Function(String) callback) {
    _onTokenRefreshCallbacks.remove(callback);
  }

  void _handleForegroundMessage(RemoteMessage message) {
    developer.log(
      'Foreground FCM message: ${message.data}',
      name: 'fcm_service',
    );
    _handleMessage(message.data);
  }

  void _handleMessageOpenedApp(RemoteMessage message) {
    developer.log(
      'FCM message opened app: ${message.data}',
      name: 'fcm_service',
    );
    _handleMessage(message.data);
  }

  void _handleMessage(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    if (type == 'NOISE_EVENT') {
      final event = NoiseEventData(
        remoteDeviceId: data['remoteDeviceId'] as String? ?? '',
        monitorName: data['monitorName'] as String? ?? 'Monitor',
        timestamp: int.tryParse(data['timestamp']?.toString() ?? '') ?? 0,
        peakLevel: int.tryParse(data['peakLevel']?.toString() ?? '') ?? 0,
      );
      onNoiseEvent?.call(event);
    }
  }
}
