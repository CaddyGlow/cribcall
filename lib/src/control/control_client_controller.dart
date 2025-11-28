/// Control Client Controller for Listener side.
///
/// Manages WebSocket connection to monitor, handles noise events,
/// and coordinates WebRTC streaming.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../background/background_service.dart';
import '../domain/models.dart';
import '../domain/noise_subscription.dart';
import '../fcm/fcm_service.dart';
import '../identity/device_identity.dart';
import '../state/app_state.dart';
import '../state/per_monitor_settings.dart';
import '../util/format_utils.dart';
import '../utils/logger.dart';
import 'control_client.dart' as client;
import 'control_connection.dart';
import 'control_messages.dart';

const _log = Logger('client_ctrl');

// -----------------------------------------------------------------------------
// State Types
// -----------------------------------------------------------------------------

enum ControlClientStatus { idle, connecting, connected, error }

class ControlClientState {
  const ControlClientState._({
    required this.status,
    this.remoteDeviceId,
    this.monitorName,
    this.connectionId,
    this.peerFingerprint,
    this.error,
  });

  const ControlClientState.idle() : this._(status: ControlClientStatus.idle);

  const ControlClientState.connecting({
    required String remoteDeviceId,
    required String monitorName,
    required String peerFingerprint,
  }) : this._(
         status: ControlClientStatus.connecting,
         remoteDeviceId: remoteDeviceId,
         monitorName: monitorName,
         peerFingerprint: peerFingerprint,
       );

  const ControlClientState.connected({
    required String remoteDeviceId,
    required String monitorName,
    required String connectionId,
    required String peerFingerprint,
  }) : this._(
         status: ControlClientStatus.connected,
         remoteDeviceId: remoteDeviceId,
         monitorName: monitorName,
         connectionId: connectionId,
         peerFingerprint: peerFingerprint,
       );

  const ControlClientState.error({
    required String remoteDeviceId,
    required String monitorName,
    required String error,
  }) : this._(
         status: ControlClientStatus.error,
         remoteDeviceId: remoteDeviceId,
         monitorName: monitorName,
         error: error,
       );

  final ControlClientStatus status;
  final String? remoteDeviceId;
  final String? monitorName;
  final String? connectionId;
  final String? peerFingerprint;
  final String? error;
}

// -----------------------------------------------------------------------------
// Controller
// -----------------------------------------------------------------------------

class ControlClientController extends Notifier<ControlClientState> {
  client.ControlClient? _client;
  ControlConnection? _connection;
  StreamSubscription<ControlMessage>? _messageSub;
  ListenerServiceManager? _listenerService;
  final _uuid = const Uuid();
  bool _disposed = false;
  String? _currentHost;
  int? _currentPort;
  String? _expectedFingerprint;
  String? _activeSubscriptionId;
  DateTime? _activeSubscriptionExpiry;
  String? _lastSubscribedToken;
  Timer? _leaseRenewTimer;
  String? _listenerDeviceId;

  /// Stream controller for noise events - UI can subscribe to receive alerts.
  final _noiseEventController = StreamController<NoiseEventData>.broadcast();

  /// Stream of noise events for UI to listen to.
  Stream<NoiseEventData> get noiseEvents => _noiseEventController.stream;

  /// Stream controller for WebRTC signaling messages.
  final _webrtcSignalingController =
      StreamController<ControlMessage>.broadcast();

  /// Stream of WebRTC signaling messages for UI/WebRTC layer.
  Stream<ControlMessage> get webrtcSignaling =>
      _webrtcSignalingController.stream;

  @override
  ControlClientState build() {
    _disposed = false;
    ref.onDispose(_shutdown);

    // Wire up FCM noise events to be processed through our handler
    FcmService.instance.onNoiseEvent = _handleFcmNoiseEvent;
    FcmService.instance.addTokenRefreshListener(_onTokenRefresh);

    return const ControlClientState.idle();
  }

  /// Connect to a monitor's control server.
  Future<String?> connectToMonitor({
    required MdnsAdvertisement advertisement,
    required TrustedMonitor monitor,
    required DeviceIdentity identity,
  }) async {
    await disconnect();
    _disposed = false; // Reset after disconnect cleanup
    _clearLeaseState();
    _listenerDeviceId = identity.deviceId;

    final ip = advertisement.ip;
    if (ip == null) {
      const error = 'Monitor is offline or missing IP address';
      state = ControlClientState.error(
        remoteDeviceId: monitor.remoteDeviceId,
        monitorName: monitor.monitorName,
        error: error,
      );
      return error;
    }

    _currentHost = ip;
    _currentPort = advertisement.controlPort;
    _expectedFingerprint = monitor.certFingerprint;

    state = ControlClientState.connecting(
      remoteDeviceId: monitor.remoteDeviceId,
      monitorName: monitor.monitorName,
      peerFingerprint: monitor.certFingerprint,
    );

    _log(
      'Connecting to monitor=${monitor.remoteDeviceId} '
      'name=${monitor.monitorName} '
      'ip=$ip port=${advertisement.controlPort} '
      'expectedFp=${shortFingerprint(monitor.certFingerprint)}',
    );

    try {
      _client ??= client.ControlClient(identity: identity);

      _connection = await _client!.connect(
        host: ip,
        port: advertisement.controlPort,
        expectedFingerprint: monitor.certFingerprint,
      );

      _log(
        'Connected to monitor: connectionId=${_connection!.connectionId} '
        'peer=${shortFingerprint(_connection!.peerFingerprint)}',
      );

      // Listen for messages
      _messageSub = _connection!.messages.listen(
        _handleMessage,
        onError: (e) {
          _log('Connection error: $e');
          state = ControlClientState.error(
            remoteDeviceId: monitor.remoteDeviceId,
            monitorName: monitor.monitorName,
            error: '$e',
          );
        },
        onDone: () {
          _log('Connection closed');
          state = const ControlClientState.idle();
        },
      );

      state = ControlClientState.connected(
        remoteDeviceId: monitor.remoteDeviceId,
        monitorName: monitor.monitorName,
        connectionId: _connection!.connectionId,
        peerFingerprint: _connection!.peerFingerprint,
      );

      // Persist connection for session restore
      ref
          .read(appSessionProvider.notifier)
          .setLastConnectedRemoteDeviceId(monitor.remoteDeviceId);

      // Start foreground service to keep connection alive
      _listenerService ??= createListenerServiceManager();
      await _listenerService!.startListening(monitorName: monitor.monitorName);

      // Send FCM token to monitor (if available)
      await _sendFcmTokenToMonitor(identity.deviceId);
      await _subscribeNoiseLease();

      return null; // Success
    } catch (e) {
      _log('Connection failed: $e');
      final error = '$e';
      state = ControlClientState.error(
        remoteDeviceId: monitor.remoteDeviceId,
        monitorName: monitor.monitorName,
        error: error,
      );
      return error;
    }
  }

  void _handleMessage(ControlMessage message) {
    _log('Received ${message.type.name}');

    switch (message) {
      case NoiseEventMessage(
        :final deviceId,
        :final timestamp,
        :final peakLevel,
      ):
        _handleNoiseEvent(deviceId, timestamp, peakLevel);

      // WebRTC signaling messages - forward to UI/WebRTC layer
      case StartStreamResponseMessage():
      case WebRtcOfferMessage():
      case WebRtcAnswerMessage():
      case WebRtcIceMessage():
      case EndStreamMessage():
        _webrtcSignalingController.add(message);

      case PingMessage(:final timestamp):
        // Respond to ping with pong
        send(PongMessage(timestamp: timestamp));

      default:
        // Other message types handled as needed
        break;
    }
  }

  /// Handle incoming noise event with deduplication.
  void _handleNoiseEvent(String remoteDeviceId, int timestamp, int peakLevel) {
    _log(
      'Noise event: remoteDeviceId=$remoteDeviceId peakLevel=$peakLevel timestamp=$timestamp',
    );

    // Create event data for deduplication
    final event = NoiseEventData(
      remoteDeviceId: remoteDeviceId,
      monitorName: state.monitorName ?? 'Monitor',
      timestamp: timestamp,
      peakLevel: peakLevel,
    );

    // Check if already received via FCM
    _log('Checking dedup for event: ${event.eventId}');
    final dedup = ref.read(noiseEventDeduplicationProvider.notifier);
    final isNew = dedup.processEvent(event);
    _log('Dedup result: isNew=$isNew');
    if (!isNew) {
      _log('Duplicate noise event ignored (already received via FCM)');
      return;
    }

    _processNewNoiseEvent(event);
  }

  /// Handle noise event received via FCM (background/foreground).
  void _handleFcmNoiseEvent(NoiseEventData event) {
    _log(
      'FCM noise event: remoteDeviceId=${event.remoteDeviceId} peakLevel=${event.peakLevel}',
    );

    // Check if already received via WebSocket
    final dedup = ref.read(noiseEventDeduplicationProvider.notifier);
    if (!dedup.processEvent(event)) {
      _log(
        'Duplicate noise event ignored (already received via WebSocket)',
      );
      return;
    }

    _processNewNoiseEvent(event);
  }

  /// Process a new (non-duplicate) noise event.
  void _processNewNoiseEvent(NoiseEventData event) {
    _log('Processing noise event: ${event.eventId} disposed=$_disposed');

    if (_disposed) {
      _log('Noise event ignored: controller disposed');
      return;
    }

    // Record the noise event for this monitor
    ref
        .read(trustedMonitorsProvider.notifier)
        .recordNoiseEvent(
          remoteDeviceId: event.remoteDeviceId,
          timestampMs: event.timestamp,
        );

    // Emit to stream for UI listeners (guard against closed controller)
    _log('Emitting noise event to stream');
    _noiseEventController.add(event);

    // Check listener settings to determine action
    final listenerSettings = ref.read(listenerSettingsProvider).asData?.value;
    final defaultAction =
        listenerSettings?.defaultAction ?? ListenerDefaultAction.notify;

    _log('Noise event action: $defaultAction');

    if (defaultAction == ListenerDefaultAction.autoOpenStream) {
      // Auto-request WebRTC stream from monitor
      _autoRequestStream(event.remoteDeviceId);
    }
  }

  void _onTokenRefresh(String token) {
    if (_disposed) return;
    _log('FCM token refreshed, renewing noise subscription');
    unawaited(_subscribeNoiseLease(force: true));
  }

  Future<void> _subscribeNoiseLease({bool force = false}) async {
    if (_currentHost == null ||
        _currentPort == null ||
        _expectedFingerprint == null) {
      _log('Noise subscribe skipped: missing monitor address');
      return;
    }
    final token = _resolveNoiseToken();
    if (token == null || token.isEmpty) {
      _log('Noise subscribe skipped: no push token');
      return;
    }
    final usingWebsocketOnly = isWebsocketOnlyNoiseToken(token);
    if (_client == null) {
      _log('Noise subscribe skipped: client not initialized');
      return;
    }
    final now = DateTime.now().toUtc();
    if (!force &&
        _activeSubscriptionExpiry != null &&
        _activeSubscriptionExpiry!.isAfter(
          now.add(const Duration(minutes: 5)),
        ) &&
        _lastSubscribedToken == token) {
      _log('Noise subscription still valid, skipping renew');
      return;
    }

    try {
      final platform = _platformLabel();

      // Get listener's noise preferences
      final listenerSettings = await ref.read(listenerSettingsProvider.future);
      final globalPrefs = listenerSettings.noisePreferences;

      // Get per-monitor overrides if connected
      final connectedDeviceId = state.remoteDeviceId;
      int effectiveThreshold = globalPrefs.threshold;
      int effectiveCooldown = globalPrefs.cooldownSeconds;
      AutoStreamType effectiveAutoStreamType = globalPrefs.autoStreamType;
      int effectiveAutoStreamDuration = globalPrefs.autoStreamDurationSec;

      if (connectedDeviceId != null) {
        final perMonitorData = await ref.read(
          perMonitorSettingsProvider.future,
        );
        final perMonitor = perMonitorData.getOrDefault(connectedDeviceId);
        effectiveThreshold = perMonitor.thresholdOverride ?? effectiveThreshold;
        effectiveCooldown =
            perMonitor.cooldownSecondsOverride ?? effectiveCooldown;
        effectiveAutoStreamType =
            perMonitor.autoStreamTypeOverride ?? effectiveAutoStreamType;
        effectiveAutoStreamDuration =
            perMonitor.autoStreamDurationSecOverride ??
            effectiveAutoStreamDuration;
      }

      final response = await _client!.subscribeNoise(
        host: _currentHost!,
        port: _currentPort!,
        expectedFingerprint: _expectedFingerprint!,
        fcmToken: token,
        platform: platform,
        leaseSeconds: null,
        threshold: effectiveThreshold,
        cooldownSeconds: effectiveCooldown,
        autoStreamType: effectiveAutoStreamType.name,
        autoStreamDurationSec: effectiveAutoStreamDuration,
      );
      _activeSubscriptionId = response.subscriptionId;
      _activeSubscriptionExpiry = response.expiresAt;
      _lastSubscribedToken = token;
      _scheduleLeaseRenewal(response.expiresAt);
      _log(
        'Noise subscription updated: subId=${response.subscriptionId} '
        'expiresAt=${response.expiresAt.toIso8601String()} '
        'lease=${response.acceptedLeaseSeconds}s '
        'threshold=$effectiveThreshold cooldown=$effectiveCooldown '
        'autoStream=${effectiveAutoStreamType.name} '
        'delivery=${usingWebsocketOnly ? 'ws-only' : 'fcm'}',
      );
    } catch (e) {
      _log('Noise subscribe failed: $e');
    }
  }

  Future<void> _unsubscribeNoiseLease() async {
    if (_currentHost == null ||
        _currentPort == null ||
        _expectedFingerprint == null) {
      return;
    }
    if (_client == null) return;
    final subId = _activeSubscriptionId;
    final token = _lastSubscribedToken;
    if (subId == null && token == null) return;
    try {
      await _client!.unsubscribeNoise(
        host: _currentHost!,
        port: _currentPort!,
        expectedFingerprint: _expectedFingerprint!,
        fcmToken: subId == null ? token : null,
        subscriptionId: subId,
      );
      _log('Noise subscription cleared');
    } catch (e) {
      _log('Noise unsubscribe failed (ignored): $e');
    }
  }

  void _scheduleLeaseRenewal(DateTime expiresAt) {
    _leaseRenewTimer?.cancel();
    final now = DateTime.now().toUtc();
    final remaining = expiresAt.difference(now);
    var renewSeconds = remaining.inSeconds ~/ 2;
    if (renewSeconds < 1) renewSeconds = 1;
    if (renewSeconds > 86400) renewSeconds = 86400;
    final renewAfter = Duration(seconds: renewSeconds);
    _leaseRenewTimer = Timer(renewAfter, () {
      _log('Noise lease renewal timer fired');
      unawaited(_subscribeNoiseLease(force: true));
    });
  }

  void _clearLeaseState() {
    _activeSubscriptionExpiry = null;
    _activeSubscriptionId = null;
    _lastSubscribedToken = null;
    _leaseRenewTimer?.cancel();
    _leaseRenewTimer = null;
  }

  String? _resolveNoiseToken() {
    final fcmToken = FcmService.instance.currentToken;
    if (fcmToken != null && fcmToken.isNotEmpty) {
      return fcmToken;
    }

    if (Platform.isLinux) {
      final deviceId =
          _listenerDeviceId ??
          ref.read(identityProvider).asData?.value?.deviceId;
      if (deviceId != null && deviceId.isNotEmpty) {
        return websocketOnlyNoiseToken(deviceId);
      }
    }

    return null;
  }

  String _platformLabel() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// Automatically request WebRTC stream when noise event received.
  Future<void> _autoRequestStream(String remoteDeviceId) async {
    if (state.status != ControlClientStatus.connected) {
      _log('Cannot auto-request stream: not connected');
      return;
    }

    // Check if already streaming (avoid duplicate requests)
    // For now, we send the request and let the monitor handle duplicates

    _log('Auto-requesting audio stream for noise event');

    try {
      await requestStream(mediaType: 'audio');
    } catch (e) {
      _log('Auto-stream request failed: $e');
    }
  }

  /// Request a WebRTC stream from the connected monitor.
  /// [mediaType] can be "audio" or "audio_video".
  Future<String> requestStream({String mediaType = 'audio'}) async {
    if (state.status != ControlClientStatus.connected) {
      throw StateError('Not connected to monitor');
    }

    final sessionId = _uuid.v4();
    final message = StartStreamRequestMessage(
      sessionId: sessionId,
      mediaType: mediaType,
    );

    _log('Requesting stream: sessionId=$sessionId mediaType=$mediaType');
    await send(message);

    return sessionId;
  }

  /// End an active WebRTC stream session.
  Future<void> endStream(String sessionId) async {
    if (state.status != ControlClientStatus.connected) {
      _log('Cannot end stream: not connected');
      return;
    }

    final message = EndStreamMessage(sessionId: sessionId);
    _log('Ending stream: sessionId=$sessionId');
    await send(message);
  }

  /// Send WebRTC answer SDP to the monitor.
  Future<void> sendWebRtcAnswer({
    required String sessionId,
    required String sdp,
  }) async {
    if (state.status != ControlClientStatus.connected) {
      throw StateError('Not connected to monitor');
    }

    final message = WebRtcAnswerMessage(sessionId: sessionId, sdp: sdp);
    _log('Sending WebRTC answer: sessionId=$sessionId');
    await send(message);
  }

  /// Send WebRTC ICE candidate to the monitor.
  Future<void> sendWebRtcIce({
    required String sessionId,
    required Map<String, dynamic> candidate,
  }) async {
    if (state.status != ControlClientStatus.connected) {
      throw StateError('Not connected to monitor');
    }

    final message = WebRtcIceMessage(
      sessionId: sessionId,
      candidate: candidate,
    );
    _log('Sending WebRTC ICE: sessionId=$sessionId');
    await send(message);
  }

  /// Pin the current stream to prevent auto-timeout.
  Future<void> pinStream(String sessionId) async {
    if (state.status != ControlClientStatus.connected) {
      _log('Cannot pin stream: not connected');
      return;
    }

    final message = PinStreamMessage(sessionId: sessionId);
    _log('Pinning stream: sessionId=$sessionId');
    await send(message);
  }

  /// Send FCM token to the connected monitor.
  Future<void> _sendFcmTokenToMonitor(String deviceId) async {
    final fcmService = FcmService.instance;
    final fcmToken = fcmService.currentToken;

    if (fcmToken == null || fcmToken.isEmpty) {
      _log('No FCM token available, skipping token sync');
      return;
    }

    try {
      final message = FcmTokenUpdateMessage(
        fcmToken: fcmToken,
        deviceId: deviceId,
      );
      await send(message);
      _log('Sent FCM token to monitor');
    } catch (e) {
      _log('Failed to send FCM token: $e');
    }
  }

  /// Update FCM token with the connected monitor (call when token refreshes).
  Future<void> updateFcmToken(String deviceId, String newToken) async {
    if (state.status != ControlClientStatus.connected) {
      _log('Not connected, cannot update FCM token');
      return;
    }

    try {
      final message = FcmTokenUpdateMessage(
        fcmToken: newToken,
        deviceId: deviceId,
      );
      await send(message);
      _log('Sent updated FCM token to monitor');
    } catch (e) {
      _log('Failed to send updated FCM token: $e');
    }
  }

  /// Send a message to the connected monitor.
  Future<void> send(ControlMessage message) async {
    final conn = _connection;
    if (conn == null) {
      throw StateError('Not connected to monitor');
    }
    await conn.send(message);
  }

  Future<void> disconnect() => _shutdown();

  /// Refresh the noise subscription with current preferences.
  /// Call this when listener or per-monitor settings change.
  Future<void> refreshNoiseSubscription() async {
    if (state.status != ControlClientStatus.connected) {
      _log('refreshNoiseSubscription skipped: not connected');
      return;
    }
    await _subscribeNoiseLease(force: true);
  }

  /// Disconnect and clear persisted session (explicit user disconnect).
  Future<void> disconnectAndClearSession() async {
    await _shutdown();
    // Clear persisted connection so we don't auto-reconnect on next launch
    ref.read(appSessionProvider.notifier).setLastConnectedRemoteDeviceId(null);
  }

  Future<void> _shutdown() async {
    _disposed = true;
    _log('Disconnecting');
    _messageSub?.cancel();
    _messageSub = null;

    // Clear FCM callback to avoid handling events when not connected
    FcmService.instance.onNoiseEvent = null;
    FcmService.instance.removeTokenRefreshListener(_onTokenRefresh);

    // Stop foreground service
    try {
      await _listenerService?.stopListening();
    } catch (_) {}

    try {
      await _connection?.close();
    } catch (_) {}
    _connection = null;
    _client = null;
    await _unsubscribeNoiseLease();
    _clearLeaseState();

    // Note: Don't close broadcast stream controllers - they can't be reused after close,
    // and they don't hold resources that need cleanup. The _disposed flag guards against
    // adding events after shutdown.

    if (state.status != ControlClientStatus.idle) {
      state = const ControlClientState.idle();
    }
  }
}
