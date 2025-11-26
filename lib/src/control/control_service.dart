import 'dart:async';
import 'dart:developer' as developer;

import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/build_flags.dart';
import '../domain/models.dart';
import '../identity/device_identity.dart';
import '../state/app_state.dart';
import 'control_connection.dart';
import 'control_messages.dart';
import 'control_server.dart' as server;
import 'pairing_server.dart';
import 'control_client.dart' as client;
import '../fcm/fcm_sender.dart';
import '../fcm/fcm_service.dart';
import '../background/background_service.dart';
import 'package:uuid/uuid.dart';

// -----------------------------------------------------------------------------
// Pairing Server Controller (Monitor side - TLS only)
// -----------------------------------------------------------------------------

enum PairingServerStatus { stopped, starting, running, error }

/// Info about an active pairing session awaiting confirmation.
class ActivePairingSession {
  const ActivePairingSession({
    required this.sessionId,
    required this.comparisonCode,
    required this.expiresAt,
  });

  final String sessionId;
  /// 6-digit comparison code to display to the user
  final String comparisonCode;
  final DateTime expiresAt;

  bool get expired => DateTime.now().isAfter(expiresAt);
}

class PairingServerState {
  const PairingServerState._({
    required this.status,
    this.port,
    this.fingerprint,
    this.error,
    this.activeSession,
  });

  const PairingServerState.stopped()
    : this._(status: PairingServerStatus.stopped);

  const PairingServerState.starting({required int port, required String fingerprint})
    : this._(status: PairingServerStatus.starting, port: port, fingerprint: fingerprint);

  const PairingServerState.running({required int port, required String fingerprint, ActivePairingSession? activeSession})
    : this._(status: PairingServerStatus.running, port: port, fingerprint: fingerprint, activeSession: activeSession);

  const PairingServerState.error({required String error, int? port, String? fingerprint})
    : this._(status: PairingServerStatus.error, port: port, fingerprint: fingerprint, error: error);

  final PairingServerStatus status;
  final int? port;
  final String? fingerprint;
  final String? error;
  /// Active pairing session awaiting user confirmation (if any)
  final ActivePairingSession? activeSession;

  /// Creates a copy with updated active session
  PairingServerState copyWithSession(ActivePairingSession? session) {
    return PairingServerState._(
      status: status,
      port: port,
      fingerprint: fingerprint,
      error: error,
      activeSession: session,
    );
  }
}

class PairingServerController extends Notifier<PairingServerState> {
  PairingServer? _server;
  bool _starting = false;

  @override
  PairingServerState build() {
    ref.onDispose(_shutdown);
    return const PairingServerState.stopped();
  }

  Future<void> start({
    required DeviceIdentity identity,
    required int port,
    required String monitorName,
  }) async {
    if (_starting) return;
    _starting = true;

    _logPairing(
      'Starting pairing server port=$port '
      'fingerprint=${_shortFingerprint(identity.certFingerprint)}',
    );

    state = PairingServerState.starting(
      port: port,
      fingerprint: identity.certFingerprint,
    );

    try {
      _server ??= PairingServer(
        onPairingComplete: _onPairingComplete,
        onSessionCreated: _onSessionCreated,
      );

      await _server!.start(
        port: port,
        identity: identity,
        monitorName: monitorName,
      );

      final actualPort = _server!.boundPort ?? port;
      _logPairing(
        'Pairing server running on port $actualPort '
        'fingerprint=${_shortFingerprint(identity.certFingerprint)}',
      );

      state = PairingServerState.running(
        port: actualPort,
        fingerprint: identity.certFingerprint,
      );
    } catch (e) {
      _logPairing('Pairing server start failed: $e');
      state = PairingServerState.error(
        error: '$e',
        port: port,
        fingerprint: identity.certFingerprint,
      );
    } finally {
      _starting = false;
    }
  }

  void _onSessionCreated(String sessionId, String comparisonCode, DateTime expiresAt) {
    _logPairing(
      'Pairing session created: sessionId=$sessionId '
      'comparisonCode=$comparisonCode expiresAt=$expiresAt',
    );
    // Update state with active session
    state = state.copyWithSession(ActivePairingSession(
      sessionId: sessionId,
      comparisonCode: comparisonCode,
      expiresAt: expiresAt,
    ));
  }

  void _onPairingComplete(TrustedPeer peer) {
    _logPairing(
      'Pairing complete: deviceId=${peer.deviceId} '
      'name=${peer.name} '
      'fingerprint=${_shortFingerprint(peer.certFingerprint)}',
    );
    // Clear active session and persist trusted listener
    state = state.copyWithSession(null);
    ref.read(trustedListenersProvider.notifier).addListener(peer);
  }

  /// Clears the active pairing session (e.g., if user cancels or session expires)
  void clearSession() {
    state = state.copyWithSession(null);
  }

  Future<void> stop() => _shutdown();

  Future<void> _shutdown() async {
    _logPairing('Stopping pairing server');
    try {
      await _server?.stop();
    } catch (_) {}
    _server = null;
    if (state.status != PairingServerStatus.stopped) {
      state = const PairingServerState.stopped();
    }
  }
}

// -----------------------------------------------------------------------------
// Control Server Controller (Monitor side - mTLS WebSocket)
// -----------------------------------------------------------------------------

enum ControlServerStatus { stopped, starting, running, error }

class ControlServerState {
  const ControlServerState._({
    required this.status,
    this.port,
    this.trustedFingerprints = const [],
    this.fingerprint,
    this.error,
  });

  const ControlServerState.stopped()
    : this._(status: ControlServerStatus.stopped);

  const ControlServerState.starting({
    required int port,
    required List<String> trustedFingerprints,
    required String fingerprint,
  }) : this._(
         status: ControlServerStatus.starting,
         port: port,
         trustedFingerprints: trustedFingerprints,
         fingerprint: fingerprint,
       );

  const ControlServerState.running({
    required int port,
    required List<String> trustedFingerprints,
    required String fingerprint,
  }) : this._(
         status: ControlServerStatus.running,
         port: port,
         trustedFingerprints: trustedFingerprints,
         fingerprint: fingerprint,
       );

  const ControlServerState.error({
    required String error,
    int? port,
    List<String> trustedFingerprints = const [],
    String? fingerprint,
  }) : this._(
         status: ControlServerStatus.error,
         port: port,
         trustedFingerprints: trustedFingerprints,
         fingerprint: fingerprint,
         error: error,
       );

  final ControlServerStatus status;
  final int? port;
  final List<String> trustedFingerprints;
  final String? fingerprint;
  final String? error;
}

class ControlServerController extends Notifier<ControlServerState> {
  server.ControlServer? _server;
  bool _starting = false;
  final Map<String, ControlConnection> _connections = {};
  StreamSubscription<server.ControlServerEvent>? _eventSub;
  FcmSender? _fcmSender;

  @override
  ControlServerState build() {
    ref.onDispose(_shutdown);
    return const ControlServerState.stopped();
  }

  Future<void> start({
    required DeviceIdentity identity,
    required int port,
    required List<TrustedPeer> trustedPeers,
  }) async {
    if (_starting) return;
    _starting = true;

    final trustedFingerprints = trustedPeers.map((p) => p.certFingerprint).toList();

    _logControl(
      'Starting control server port=$port '
      'trusted=${trustedFingerprints.length} '
      'fingerprint=${_shortFingerprint(identity.certFingerprint)}',
    );

    state = ControlServerState.starting(
      port: port,
      trustedFingerprints: trustedFingerprints,
      fingerprint: identity.certFingerprint,
    );

    try {
      _server ??= server.ControlServer();

      await _server!.start(
        port: port,
        identity: identity,
        trustedPeers: trustedPeers,
      );

      // Listen for server events (new connections, etc.)
      _eventSub?.cancel();
      _eventSub = _server!.events.listen(_handleServerEvent);

      final actualPort = _server!.boundPort ?? port;
      _logControl(
        'Control server running on port $actualPort '
        'trusted=${trustedFingerprints.length} '
        'fingerprint=${_shortFingerprint(identity.certFingerprint)}',
      );

      state = ControlServerState.running(
        port: actualPort,
        trustedFingerprints: trustedFingerprints,
        fingerprint: identity.certFingerprint,
      );
    } catch (e) {
      _logControl('Control server start failed: $e');
      state = ControlServerState.error(
        error: '$e',
        port: port,
        trustedFingerprints: trustedFingerprints,
        fingerprint: identity.certFingerprint,
      );
    } finally {
      _starting = false;
    }
  }

  void _handleServerEvent(server.ControlServerEvent event) {
    switch (event) {
      case server.ClientConnected(:final connection):
        _logControl(
          'Client connected: ${connection.connectionId} '
          'peer=${_shortFingerprint(connection.peerFingerprint)}',
        );
        _connections[connection.connectionId] = connection;
        _listenToConnection(connection);
      case server.ClientDisconnected(:final connectionId, :final reason):
        _logControl('Client disconnected: $connectionId reason=$reason');
        _connections.remove(connectionId);
    }
  }

  void _listenToConnection(ControlConnection connection) {
    connection.messages.listen(
      (message) => _handleMessage(connection, message),
      onError: (e) => _logControl('Connection error ${connection.connectionId}: $e'),
      onDone: () => _connections.remove(connection.connectionId),
    );
  }

  void _handleMessage(ControlConnection connection, ControlMessage message) {
    _logControl(
      'Received ${message.type.name} from ${connection.connectionId}',
    );
    // Handle control messages
    switch (message) {
      case FcmTokenUpdateMessage(:final fcmToken, :final listenerId):
        _handleFcmTokenUpdate(listenerId, fcmToken);
      default:
        // Other message types handled as needed
        break;
    }
  }

  /// Handle FCM token update from a listener.
  Future<void> _handleFcmTokenUpdate(String listenerId, String fcmToken) async {
    _logControl('FCM token update from listener=$listenerId');
    await ref.read(trustedListenersProvider.notifier).updateFcmToken(
      listenerId,
      fcmToken,
    );
  }

  /// Add a newly paired peer to the trusted list.
  /// Uses hot reload to update the server without restart.
  Future<void> addTrustedPeer(TrustedPeer peer) async {
    final srv = _server;
    if (srv == null) return;

    _logControl(
      'Adding trusted peer: ${peer.deviceId} '
      'fingerprint=${_shortFingerprint(peer.certFingerprint)}',
    );
    await srv.addTrustedPeer(peer);

    // Update state with new trusted list
    final newFingerprints = [...state.trustedFingerprints, peer.certFingerprint];
    state = ControlServerState.running(
      port: state.port ?? kControlDefaultPort,
      trustedFingerprints: newFingerprints,
      fingerprint: state.fingerprint ?? '',
    );
  }

  /// Remove a peer from the trusted list.
  Future<void> removeTrustedPeer(String fingerprint) async {
    final srv = _server;
    if (srv == null) return;

    _logControl('Removing trusted peer: fingerprint=${_shortFingerprint(fingerprint)}');
    await srv.removeTrustedPeer(fingerprint);

    // Update state
    final newFingerprints = state.trustedFingerprints
        .where((fp) => fp != fingerprint)
        .toList();
    state = ControlServerState.running(
      port: state.port ?? kControlDefaultPort,
      trustedFingerprints: newFingerprints,
      fingerprint: state.fingerprint ?? '',
    );
  }

  /// Broadcast a message to all connected clients.
  Future<void> broadcast(ControlMessage message) async {
    _logControl('Broadcasting ${message.type.name} to ${_connections.length} clients');
    for (final conn in _connections.values) {
      try {
        await conn.send(message);
      } catch (e) {
        _logControl('Broadcast to ${conn.connectionId} failed: $e');
      }
    }
  }

  /// Send a message to a specific connection.
  Future<void> sendTo(String connectionId, ControlMessage message) async {
    final conn = _connections[connectionId];
    if (conn == null) {
      _logControl('Cannot send to $connectionId - not connected');
      return;
    }
    await conn.send(message);
  }

  /// Broadcast a noise event to all connected listeners via WebSocket AND FCM.
  Future<void> broadcastNoiseEvent({
    required int timestampMs,
    required int peakLevel,
  }) async {
    final monitorId = state.fingerprint ?? '';
    final message = NoiseEventMessage(
      monitorId: monitorId,
      timestamp: timestampMs,
      peakLevel: peakLevel,
    );

    // Path 1: WebSocket broadcast to connected clients
    await broadcast(message);

    // Path 2: FCM push to all trusted listeners (even if not currently connected)
    await _sendNoiseEventViaFcm(
      monitorId: monitorId,
      timestamp: timestampMs,
      peakLevel: peakLevel,
    );
  }

  /// Send noise event via FCM Cloud Function.
  Future<void> _sendNoiseEventViaFcm({
    required String monitorId,
    required int timestamp,
    required int peakLevel,
  }) async {
    // Get all trusted listeners with FCM tokens
    final trustedListeners =
        ref.read(trustedListenersProvider).asData?.value ?? [];
    final fcmTokens = trustedListeners
        .where((p) => p.fcmToken != null && p.fcmToken!.isNotEmpty)
        .map((p) => p.fcmToken!)
        .toList();

    if (fcmTokens.isEmpty) {
      _logControl('No FCM tokens available, skipping push');
      return;
    }

    // Get monitor name for notification
    final monitorSettings = ref.read(monitorSettingsProvider).asData?.value;
    final monitorName = monitorSettings?.name ?? 'Monitor';

    try {
      _fcmSender ??= FcmSender();

      if (!_fcmSender!.isEnabled) {
        _logControl('FCM not configured, skipping push');
        return;
      }

      final result = await _fcmSender!.sendNoiseEvent(
        monitorId: monitorId,
        monitorName: monitorName,
        timestamp: timestamp,
        peakLevel: peakLevel,
        fcmTokens: fcmTokens,
      );

      _logControl(
        'FCM sent: success=${result.success} failure=${result.failure}',
      );

      // Clean up invalid tokens
      if (result.invalidTokens.isNotEmpty) {
        for (final token in result.invalidTokens) {
          await ref
              .read(trustedListenersProvider.notifier)
              .clearFcmTokenByToken(token);
        }
      }
    } catch (e) {
      _logControl('FCM send error: $e');
      // Don't throw - WebSocket delivery is primary path
    }
  }

  Future<void> stop() => _shutdown();

  Future<void> _shutdown() async {
    _logControl('Stopping control server');
    _eventSub?.cancel();
    _eventSub = null;
    _connections.clear();
    _fcmSender?.dispose();
    _fcmSender = null;
    try {
      await _server?.stop();
    } catch (_) {}
    _server = null;
    if (state.status != ControlServerStatus.stopped) {
      state = const ControlServerState.stopped();
    }
  }
}

// -----------------------------------------------------------------------------
// Control Client Controller (Listener side - connects to monitor)
// -----------------------------------------------------------------------------

enum ControlClientStatus { idle, connecting, connected, error }

class ControlClientState {
  const ControlClientState._({
    required this.status,
    this.monitorId,
    this.monitorName,
    this.connectionId,
    this.peerFingerprint,
    this.error,
  });

  const ControlClientState.idle() : this._(status: ControlClientStatus.idle);

  const ControlClientState.connecting({
    required String monitorId,
    required String monitorName,
    required String peerFingerprint,
  }) : this._(
         status: ControlClientStatus.connecting,
         monitorId: monitorId,
         monitorName: monitorName,
         peerFingerprint: peerFingerprint,
       );

  const ControlClientState.connected({
    required String monitorId,
    required String monitorName,
    required String connectionId,
    required String peerFingerprint,
  }) : this._(
         status: ControlClientStatus.connected,
         monitorId: monitorId,
         monitorName: monitorName,
         connectionId: connectionId,
         peerFingerprint: peerFingerprint,
       );

  const ControlClientState.error({
    required String monitorId,
    required String monitorName,
    required String error,
  }) : this._(
         status: ControlClientStatus.error,
         monitorId: monitorId,
         monitorName: monitorName,
         error: error,
       );

  final ControlClientStatus status;
  final String? monitorId;
  final String? monitorName;
  final String? connectionId;
  final String? peerFingerprint;
  final String? error;
}

class ControlClientController extends Notifier<ControlClientState> {
  client.ControlClient? _client;
  ControlConnection? _connection;
  StreamSubscription<ControlMessage>? _messageSub;
  ListenerServiceManager? _listenerService;
  final _uuid = const Uuid();

  /// Stream controller for noise events - UI can subscribe to receive alerts.
  final _noiseEventController = StreamController<NoiseEventData>.broadcast();

  /// Stream of noise events for UI to listen to.
  Stream<NoiseEventData> get noiseEvents => _noiseEventController.stream;

  /// Stream controller for WebRTC signaling messages.
  final _webrtcSignalingController = StreamController<ControlMessage>.broadcast();

  /// Stream of WebRTC signaling messages for UI/WebRTC layer.
  Stream<ControlMessage> get webrtcSignaling => _webrtcSignalingController.stream;

  @override
  ControlClientState build() {
    ref.onDispose(_shutdown);

    // Wire up FCM noise events to be processed through our handler
    FcmService.instance.onNoiseEvent = _handleFcmNoiseEvent;

    return const ControlClientState.idle();
  }

  /// Connect to a monitor's control server.
  Future<String?> connectToMonitor({
    required MdnsAdvertisement advertisement,
    required TrustedMonitor monitor,
    required DeviceIdentity identity,
  }) async {
    await disconnect();

    final ip = advertisement.ip;
    if (ip == null) {
      const error = 'Monitor is offline or missing IP address';
      state = ControlClientState.error(
        monitorId: monitor.monitorId,
        monitorName: monitor.monitorName,
        error: error,
      );
      return error;
    }

    state = ControlClientState.connecting(
      monitorId: monitor.monitorId,
      monitorName: monitor.monitorName,
      peerFingerprint: monitor.certFingerprint,
    );

    _logClient(
      'Connecting to monitor=${monitor.monitorId} '
      'name=${monitor.monitorName} '
      'ip=$ip port=${advertisement.controlPort} '
      'expectedFp=${_shortFingerprint(monitor.certFingerprint)}',
    );

    try {
      _client ??= client.ControlClient(identity: identity);

      _connection = await _client!.connect(
        host: ip,
        port: advertisement.controlPort,
        expectedFingerprint: monitor.certFingerprint,
      );

      _logClient(
        'Connected to monitor: connectionId=${_connection!.connectionId} '
        'peer=${_shortFingerprint(_connection!.peerFingerprint)}',
      );

      // Listen for messages
      _messageSub = _connection!.messages.listen(
        _handleMessage,
        onError: (e) {
          _logClient('Connection error: $e');
          state = ControlClientState.error(
            monitorId: monitor.monitorId,
            monitorName: monitor.monitorName,
            error: '$e',
          );
        },
        onDone: () {
          _logClient('Connection closed');
          state = const ControlClientState.idle();
        },
      );

      state = ControlClientState.connected(
        monitorId: monitor.monitorId,
        monitorName: monitor.monitorName,
        connectionId: _connection!.connectionId,
        peerFingerprint: _connection!.peerFingerprint,
      );

      // Start foreground service to keep connection alive
      _listenerService ??= createListenerServiceManager();
      await _listenerService!.startListening(monitorName: monitor.monitorName);

      // Send FCM token to monitor (if available)
      await _sendFcmTokenToMonitor(identity.deviceId);

      return null; // Success
    } catch (e) {
      _logClient('Connection failed: $e');
      final error = '$e';
      state = ControlClientState.error(
        monitorId: monitor.monitorId,
        monitorName: monitor.monitorName,
        error: error,
      );
      return error;
    }
  }

  void _handleMessage(ControlMessage message) {
    _logClient('Received ${message.type.name}');

    switch (message) {
      case NoiseEventMessage(:final monitorId, :final timestamp, :final peakLevel):
        _handleNoiseEvent(monitorId, timestamp, peakLevel);

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
  void _handleNoiseEvent(String monitorId, int timestamp, int peakLevel) {
    _logClient('Noise event: monitorId=$monitorId peakLevel=$peakLevel timestamp=$timestamp');

    // Create event data for deduplication
    final event = NoiseEventData(
      monitorId: monitorId,
      monitorName: state.monitorName ?? 'Monitor',
      timestamp: timestamp,
      peakLevel: peakLevel,
    );

    // Check if already received via FCM
    final dedup = ref.read(noiseEventDeduplicationProvider.notifier);
    if (!dedup.processEvent(event)) {
      _logClient('Duplicate noise event ignored (already received via FCM)');
      return;
    }

    _processNewNoiseEvent(event);
  }

  /// Handle noise event received via FCM (background/foreground).
  void _handleFcmNoiseEvent(NoiseEventData event) {
    _logClient('FCM noise event: monitorId=${event.monitorId} peakLevel=${event.peakLevel}');

    // Check if already received via WebSocket
    final dedup = ref.read(noiseEventDeduplicationProvider.notifier);
    if (!dedup.processEvent(event)) {
      _logClient('Duplicate noise event ignored (already received via WebSocket)');
      return;
    }

    _processNewNoiseEvent(event);
  }

  /// Process a new (non-duplicate) noise event.
  void _processNewNoiseEvent(NoiseEventData event) {
    // Record the noise event for this monitor
    ref.read(trustedMonitorsProvider.notifier).recordNoiseEvent(
      monitorId: event.monitorId,
      timestampMs: event.timestamp,
    );

    // Emit to stream for UI listeners
    _noiseEventController.add(event);

    // Check listener settings to determine action
    final listenerSettings = ref.read(listenerSettingsProvider).asData?.value;
    final defaultAction = listenerSettings?.defaultAction ?? ListenerDefaultAction.notify;

    _logClient('Noise event action: $defaultAction');

    if (defaultAction == ListenerDefaultAction.autoOpenStream) {
      // Auto-request WebRTC stream from monitor
      _autoRequestStream(event.monitorId);
    }
  }

  /// Automatically request WebRTC stream when noise event received.
  Future<void> _autoRequestStream(String monitorId) async {
    if (state.status != ControlClientStatus.connected) {
      _logClient('Cannot auto-request stream: not connected');
      return;
    }

    // Check if already streaming (avoid duplicate requests)
    // For now, we send the request and let the monitor handle duplicates

    _logClient('Auto-requesting audio stream for noise event');

    try {
      await requestStream(mediaType: 'audio');
    } catch (e) {
      _logClient('Auto-stream request failed: $e');
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

    _logClient('Requesting stream: sessionId=$sessionId mediaType=$mediaType');
    await send(message);

    return sessionId;
  }

  /// End an active WebRTC stream session.
  Future<void> endStream(String sessionId) async {
    if (state.status != ControlClientStatus.connected) {
      _logClient('Cannot end stream: not connected');
      return;
    }

    final message = EndStreamMessage(sessionId: sessionId);
    _logClient('Ending stream: sessionId=$sessionId');
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
    _logClient('Sending WebRTC answer: sessionId=$sessionId');
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

    final message = WebRtcIceMessage(sessionId: sessionId, candidate: candidate);
    _logClient('Sending WebRTC ICE: sessionId=$sessionId');
    await send(message);
  }

  /// Pin the current stream to prevent auto-timeout.
  Future<void> pinStream(String sessionId) async {
    if (state.status != ControlClientStatus.connected) {
      _logClient('Cannot pin stream: not connected');
      return;
    }

    final message = PinStreamMessage(sessionId: sessionId);
    _logClient('Pinning stream: sessionId=$sessionId');
    await send(message);
  }

  /// Send FCM token to the connected monitor.
  Future<void> _sendFcmTokenToMonitor(String listenerId) async {
    final fcmService = FcmService.instance;
    final fcmToken = fcmService.currentToken;

    if (fcmToken == null || fcmToken.isEmpty) {
      _logClient('No FCM token available, skipping token sync');
      return;
    }

    try {
      final message = FcmTokenUpdateMessage(
        fcmToken: fcmToken,
        listenerId: listenerId,
      );
      await send(message);
      _logClient('Sent FCM token to monitor');
    } catch (e) {
      _logClient('Failed to send FCM token: $e');
    }
  }

  /// Update FCM token with the connected monitor (call when token refreshes).
  Future<void> updateFcmToken(String listenerId, String newToken) async {
    if (state.status != ControlClientStatus.connected) {
      _logClient('Not connected, cannot update FCM token');
      return;
    }

    try {
      final message = FcmTokenUpdateMessage(
        fcmToken: newToken,
        listenerId: listenerId,
      );
      await send(message);
      _logClient('Sent updated FCM token to monitor');
    } catch (e) {
      _logClient('Failed to send updated FCM token: $e');
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

  Future<void> _shutdown() async {
    _logClient('Disconnecting');
    _messageSub?.cancel();
    _messageSub = null;

    // Clear FCM callback to avoid handling events when not connected
    FcmService.instance.onNoiseEvent = null;

    // Stop foreground service
    try {
      await _listenerService?.stopListening();
    } catch (_) {}

    try {
      await _connection?.close();
    } catch (_) {}
    _connection = null;
    _client = null;

    // Close event streams
    _noiseEventController.close();
    _webrtcSignalingController.close();

    if (state.status != ControlClientStatus.idle) {
      state = const ControlClientState.idle();
    }
  }
}

// -----------------------------------------------------------------------------
// Logging
// -----------------------------------------------------------------------------

void _logPairing(String message) {
  developer.log(message, name: 'pairing_ctrl');
  debugPrint('[pairing_ctrl] $message');
}

void _logControl(String message) {
  developer.log(message, name: 'control_ctrl');
  debugPrint('[control_ctrl] $message');
}

void _logClient(String message) {
  developer.log(message, name: 'client_ctrl');
  debugPrint('[client_ctrl] $message');
}

String _shortFingerprint(String fingerprint) {
  if (fingerprint.length <= 12) return fingerprint;
  return '${fingerprint.substring(0, 6)}...${fingerprint.substring(fingerprint.length - 4)}';
}
