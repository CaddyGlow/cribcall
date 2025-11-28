import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/build_flags.dart';
import '../domain/models.dart';
import '../domain/noise_subscription.dart';
import '../identity/device_identity.dart';
import '../notifications/notification_service.dart';
import '../state/app_state.dart';
import '../state/per_monitor_settings.dart';
import '../util/format_utils.dart';
import '../utils/canonical_json.dart';
import 'android_control_server.dart';
import 'control_connection.dart';
import 'control_messages.dart';
import 'control_server.dart' as server;
import 'pairing_server.dart';
import 'control_client.dart' as client;
import '../fcm/fcm_sender.dart';
import '../fcm/fcm_service.dart';
import '../background/background_service.dart';
import '../webrtc/monitor_streaming_controller.dart';
import 'package:uuid/uuid.dart';

// -----------------------------------------------------------------------------
// Pairing Server Controller (Monitor side - TLS only)
// -----------------------------------------------------------------------------

enum PairingServerStatus { stopped, starting, running, error }

/// Info about an active pairing session awaiting confirmation.
class ActivePairingSession {
  const ActivePairingSession({
    required this.sessionId,
    required this.listenerName,
    required this.comparisonCode,
    required this.expiresAt,
  });

  final String sessionId;

  /// Name of the device requesting to pair.
  final String listenerName;

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

  const PairingServerState.starting({
    required int port,
    required String fingerprint,
  }) : this._(
         status: PairingServerStatus.starting,
         port: port,
         fingerprint: fingerprint,
       );

  const PairingServerState.running({
    required int port,
    required String fingerprint,
    ActivePairingSession? activeSession,
  }) : this._(
         status: PairingServerStatus.running,
         port: port,
         fingerprint: fingerprint,
         activeSession: activeSession,
       );

  const PairingServerState.error({
    required String error,
    int? port,
    String? fingerprint,
  }) : this._(
         status: PairingServerStatus.error,
         port: port,
         fingerprint: fingerprint,
         error: error,
       );

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

    final current = state;
    if (current.status == PairingServerStatus.running &&
        current.port == port &&
        current.fingerprint == identity.certFingerprint) {
      _logPairing(
        'Pairing server already running with same config, skipping restart',
      );
      return;
    }

    _starting = true;

    _logPairing(
      'Starting pairing server port=$port '
      'fingerprint=${shortFingerprint(identity.certFingerprint)}',
    );

    state = PairingServerState.starting(
      port: port,
      fingerprint: identity.certFingerprint,
    );

    try {
      await _shutdown();
      _server = PairingServer(
        onPairingComplete: _onPairingComplete,
        onSessionCreated: _onSessionCreated,
        onSessionRejected: _onSessionRejected,
        onSessionConfirmed: _onSessionConfirmed,
      );

      await _server!.start(
        port: port,
        identity: identity,
        monitorName: monitorName,
      );

      final actualPort = _server!.boundPort ?? port;
      _logPairing(
        'Pairing server running on port $actualPort '
        'fingerprint=${shortFingerprint(identity.certFingerprint)}',
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

  void _onSessionCreated(
    String sessionId,
    String listenerName,
    String comparisonCode,
    DateTime expiresAt,
  ) {
    _logPairing(
      'Pairing session created: sessionId=$sessionId '
      'listenerName=$listenerName comparisonCode=$comparisonCode '
      'expiresAt=$expiresAt',
    );

    // Show system notification for pairing request
    NotificationService.instance.showPairingRequest(
      listenerName: listenerName,
      comparisonCode: comparisonCode,
      sessionId: sessionId,
    );

    // Update state with active session
    state = state.copyWithSession(
      ActivePairingSession(
        sessionId: sessionId,
        listenerName: listenerName,
        comparisonCode: comparisonCode,
        expiresAt: expiresAt,
      ),
    );
  }

  void _onSessionConfirmed(String sessionId) {
    _logPairing('Pairing session confirmed by monitor: sessionId=$sessionId');
    // Cancel notification - user has responded via the app
    NotificationService.instance.cancelPairingRequest();
  }

  void _onSessionRejected(String sessionId) {
    _logPairing('Pairing session rejected by monitor: sessionId=$sessionId');
    // Cancel notification and clear the session from UI
    NotificationService.instance.cancelPairingRequest();
    state = state.copyWithSession(null);
  }

  void _onPairingComplete(TrustedPeer peer) {
    _logPairing(
      'Pairing complete: deviceId=${peer.remoteDeviceId} '
      'name=${peer.name} '
      'fingerprint=${shortFingerprint(peer.certFingerprint)}',
    );
    // Cancel notification and clear active session, persist trusted listener
    NotificationService.instance.cancelPairingRequest();
    state = state.copyWithSession(null);
    ref.read(trustedListenersProvider.notifier).addListener(peer);
  }

  /// Monitor user confirms the pairing request.
  /// Returns true if the session was successfully confirmed.
  bool confirmSession(String sessionId) {
    final srv = _server;
    if (srv == null) {
      _logPairing('Cannot confirm session: server not running');
      return false;
    }
    return srv.confirmSession(sessionId);
  }

  /// Monitor user rejects the pairing request.
  /// Returns true if the session was successfully rejected.
  bool rejectSession(String sessionId) {
    final srv = _server;
    if (srv == null) {
      _logPairing('Cannot reject session: server not running');
      return false;
    }
    return srv.rejectSession(sessionId);
  }

  /// Clears the active pairing session (e.g., if user cancels or session expires)
  void clearSession() {
    final session = state.activeSession;
    if (session != null) {
      // Also reject it on the server side
      _server?.rejectSession(session.sessionId);
    }
    // Cancel notification
    NotificationService.instance.cancelPairingRequest();
    state = state.copyWithSession(null);
  }

  /// Generate a new one-time pairing token for QR code flow.
  /// Invalidates any previous token.
  /// Returns null if server is not running.
  String? generatePairingToken() {
    final srv = _server;
    if (srv == null) {
      _logPairing('Cannot generate pairing token: server not running');
      return null;
    }
    return srv.generatePairingToken();
  }

  /// Invalidate the current pairing token.
  void invalidatePairingToken() {
    _server?.invalidateToken();
  }

  /// Check if the server has a valid pairing token.
  bool get hasValidPairingToken => _server?.hasValidToken ?? false;

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
    this.deviceId,
    this.error,
    this.activeConnectionsCount = 0,
  });

  const ControlServerState.stopped()
    : this._(status: ControlServerStatus.stopped);

  const ControlServerState.starting({
    required int port,
    required List<String> trustedFingerprints,
    required String fingerprint,
    required String deviceId,
  }) : this._(
         status: ControlServerStatus.starting,
         port: port,
         trustedFingerprints: trustedFingerprints,
         fingerprint: fingerprint,
         deviceId: deviceId,
       );

  const ControlServerState.running({
    required int port,
    required List<String> trustedFingerprints,
    required String fingerprint,
    required String deviceId,
    int activeConnectionsCount = 0,
  }) : this._(
         status: ControlServerStatus.running,
         port: port,
         trustedFingerprints: trustedFingerprints,
         fingerprint: fingerprint,
         deviceId: deviceId,
         activeConnectionsCount: activeConnectionsCount,
       );

  const ControlServerState.error({
    required String error,
    int? port,
    List<String> trustedFingerprints = const [],
    String? fingerprint,
    String? deviceId,
  }) : this._(
         status: ControlServerStatus.error,
         port: port,
         trustedFingerprints: trustedFingerprints,
         fingerprint: fingerprint,
         deviceId: deviceId,
         error: error,
       );

  final ControlServerStatus status;
  final int? port;
  final List<String> trustedFingerprints;
  final String? fingerprint;

  /// Device UUID used for monitor identification.
  final String? deviceId;
  final String? error;

  /// Number of currently connected listeners.
  final int activeConnectionsCount;

  bool get isRunning => status == ControlServerStatus.running;

  /// Creates a copy with updated connection count.
  ControlServerState copyWithConnectionCount(int count) {
    return ControlServerState._(
      status: status,
      port: port,
      trustedFingerprints: trustedFingerprints,
      fingerprint: fingerprint,
      deviceId: deviceId,
      error: error,
      activeConnectionsCount: count,
    );
  }
}

bool _setEquals<T>(Set<T> a, Set<T> b) {
  if (a.length != b.length) return false;
  return a.containsAll(b);
}

class ControlServerController extends Notifier<ControlServerState> {
  // Dart-only server (non-Android platforms)
  server.ControlServer? _server;
  // Android native server (foreground service)
  AndroidControlServer? _androidServer;

  bool _starting = false;
  final Map<String, ControlConnection> _connections = {};
  // Android connections don't have ControlConnection, track by connectionId->fingerprint
  final Map<String, String> _androidConnections = {};
  StreamSubscription<server.ControlServerEvent>? _eventSub;
  StreamSubscription<AndroidControlServerEvent>? _androidEventSub;
  FcmSender? _fcmSender;

  /// Whether we're using the Android native server.
  bool get _useAndroidServer => Platform.isAndroid;

  /// Track last noise broadcast timestamp per subscription (for per-listener cooldown).
  final Map<String, int> _lastBroadcastPerSubscription = {};

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

    final trustedFingerprints = trustedPeers
        .map((p) => p.certFingerprint)
        .toList();

    // Skip restart if already running with same configuration
    if (state.isRunning &&
        state.port == port &&
        state.fingerprint == identity.certFingerprint &&
        _setEquals(
          state.trustedFingerprints.toSet(),
          trustedFingerprints.toSet(),
        )) {
      _logControl(
        'Control server already running with same config, skipping restart',
      );
      return;
    }

    _starting = true;

    _logControl(
      'Starting control server port=$port '
      'trusted=${trustedFingerprints.length} '
      'fingerprint=${shortFingerprint(identity.certFingerprint)} '
      'platform=${_useAndroidServer ? 'android-native' : 'dart'}',
    );

    state = ControlServerState.starting(
      port: port,
      trustedFingerprints: trustedFingerprints,
      fingerprint: identity.certFingerprint,
      deviceId: identity.deviceId,
    );

    try {
      if (_useAndroidServer) {
        await _startAndroidServer(
          port: port,
          identity: identity,
          trustedPeers: trustedPeers,
        );
      } else {
        await _startDartServer(
          port: port,
          identity: identity,
          trustedPeers: trustedPeers,
        );
      }

      // Set up streaming controller send callback
      ref
          .read(monitorStreamingProvider.notifier)
          .setSendCallback(_sendToConnection);

      final actualPort = _useAndroidServer
          ? (_androidServer?.boundPort ?? port)
          : (_server?.boundPort ?? port);
      _logControl(
        'Control server running on port $actualPort '
        'trusted=${trustedFingerprints.length} '
        'fingerprint=${shortFingerprint(identity.certFingerprint)}',
      );

      state = ControlServerState.running(
        port: actualPort,
        trustedFingerprints: trustedFingerprints,
        fingerprint: identity.certFingerprint,
        deviceId: identity.deviceId,
      );
    } catch (e) {
      _logControl('Control server start failed: $e');
      state = ControlServerState.error(
        error: '$e',
        port: port,
        trustedFingerprints: trustedFingerprints,
        fingerprint: identity.certFingerprint,
        deviceId: identity.deviceId,
      );
    } finally {
      _starting = false;
    }
  }

  /// Start the Dart-only control server (non-Android platforms).
  Future<void> _startDartServer({
    required int port,
    required DeviceIdentity identity,
    required List<TrustedPeer> trustedPeers,
  }) async {
    _server ??= server.ControlServer(
      onUnpairRequest: _handleUnpairRequest,
      onNoiseSubscribe: _handleNoiseSubscribeRequest,
      onNoiseUnsubscribe: _handleNoiseUnsubscribeRequest,
    );

    await _server!.start(
      port: port,
      identity: identity,
      trustedPeers: trustedPeers,
    );

    // Listen for server events (new connections, etc.)
    _eventSub?.cancel();
    _eventSub = _server!.events.listen(_handleServerEvent);
  }

  /// Start the Android native control server (foreground service).
  Future<void> _startAndroidServer({
    required int port,
    required DeviceIdentity identity,
    required List<TrustedPeer> trustedPeers,
  }) async {
    _androidServer ??= AndroidControlServer();

    await _androidServer!.start(
      port: port,
      identity: identity,
      trustedPeers: trustedPeers,
    );

    // Listen for server events
    _androidEventSub?.cancel();
    _androidEventSub = _androidServer!.events.listen(_handleAndroidServerEvent);
  }

  void _handleServerEvent(server.ControlServerEvent event) {
    switch (event) {
      case server.ClientConnected(:final connection):
        _logControl(
          'Client connected: ${connection.connectionId} '
          'peer=${shortFingerprint(connection.peerFingerprint)}',
        );
        _connections[connection.connectionId] = connection;
        _listenToConnection(connection);
        // Update connection count in state
        state = state.copyWithConnectionCount(_connections.length);
      case server.ClientDisconnected(:final connectionId, :final reason):
        _logControl('Client disconnected: $connectionId reason=$reason');
        _connections.remove(connectionId);
        // Clean up any streaming sessions for this connection
        ref
            .read(monitorStreamingProvider.notifier)
            .endSessionsForConnection(connectionId);
        // Update connection count in state
        state = state.copyWithConnectionCount(_connections.length);
    }
  }

  /// Handle events from the Android native control server.
  void _handleAndroidServerEvent(AndroidControlServerEvent event) {
    switch (event) {
      case AndroidServerStarted(:final port):
        _logControl('Android server started on port $port');

      case AndroidServerError(:final error):
        _logControl('Android server error: $error');
        state = ControlServerState.error(
          error: error,
          port: state.port,
          trustedFingerprints: state.trustedFingerprints,
          fingerprint: state.fingerprint,
          deviceId: state.deviceId,
        );

      case AndroidClientConnected(
        :final connectionId,
        :final fingerprint,
        :final remoteAddress,
      ):
        _logControl(
          'Android client connected: $connectionId '
          'peer=${shortFingerprint(fingerprint)} remote=$remoteAddress',
        );
        _androidConnections[connectionId] = fingerprint;
        state = state.copyWithConnectionCount(_androidConnections.length);

      case AndroidClientDisconnected(:final connectionId, :final reason):
        _logControl('Android client disconnected: $connectionId reason=$reason');
        _androidConnections.remove(connectionId);
        // Clean up any streaming sessions for this connection
        ref
            .read(monitorStreamingProvider.notifier)
            .endSessionsForConnection(connectionId);
        state = state.copyWithConnectionCount(_androidConnections.length);

      case AndroidWsMessage(:final connectionId, :final messageJson):
        _handleAndroidWsMessage(connectionId, messageJson);

      case AndroidHttpRequest(
        :final requestId,
        :final method,
        :final path,
        :final fingerprint,
        :final bodyJson,
      ):
        unawaited(_handleAndroidHttpRequest(
          requestId: requestId,
          method: method,
          path: path,
          fingerprint: fingerprint,
          bodyJson: bodyJson,
        ));
    }
  }

  /// Handle WebSocket messages from Android native server.
  void _handleAndroidWsMessage(String connectionId, String messageJson) {
    final fingerprint = _androidConnections[connectionId];
    if (fingerprint == null) {
      _logControl('WS message from unknown Android connection: $connectionId');
      return;
    }

    try {
      final json = jsonDecode(messageJson) as Map<String, dynamic>;
      final message = ControlMessageFactory.fromWireJson(json);
      _logControl(
        'Android WS received ${message.type.name} from $connectionId',
      );
      _handleAndroidMessage(connectionId, fingerprint, message);
    } catch (e) {
      _logControl('Failed to parse Android WS message: $e');
    }
  }

  /// Handle a control message from Android connection.
  void _handleAndroidMessage(
    String connectionId,
    String fingerprint,
    ControlMessage message,
  ) {
    switch (message) {
      case FcmTokenUpdateMessage(:final fcmToken, :final deviceId):
        unawaited(
          _handleAndroidFcmTokenUpdate(
            connectionId: connectionId,
            fingerprint: fingerprint,
            claimedDeviceId: deviceId,
            fcmToken: fcmToken,
          ),
        );

      // WebRTC signaling messages
      case StartStreamRequestMessage(:final sessionId, :final mediaType):
        _handleStreamRequest(connectionId, sessionId, mediaType);

      case WebRtcAnswerMessage(:final sessionId, :final sdp):
        _handleWebRtcAnswer(sessionId, sdp);

      case WebRtcIceMessage(:final sessionId, :final candidate):
        _handleWebRtcIce(sessionId, candidate);

      case EndStreamMessage(:final sessionId):
        _handleEndStream(sessionId);

      default:
        // Other message types handled as needed
        break;
    }
  }

  /// Handle FCM token update from Android connection.
  Future<void> _handleAndroidFcmTokenUpdate({
    required String connectionId,
    required String fingerprint,
    required String fcmToken,
    String? claimedDeviceId,
  }) async {
    final listeners = await ref.read(trustedListenersProvider.future);
    final peer = listeners.firstWhereOrNull(
      (p) => p.certFingerprint == fingerprint,
    );
    if (peer == null) {
      _logControl(
        'FCM token update rejected: fingerprint not trusted '
        'fp=${shortFingerprint(fingerprint)}',
      );
      return;
    }

    if (claimedDeviceId != null && claimedDeviceId != peer.remoteDeviceId) {
      _logControl(
        'FCM token update rejected: device mismatch '
        'claimed=$claimedDeviceId derived=${peer.remoteDeviceId}',
      );
      return;
    }

    _logControl(
      'FCM token update from listener=${peer.remoteDeviceId} '
      'fp=${shortFingerprint(peer.certFingerprint)}',
    );
    await ref
        .read(trustedListenersProvider.notifier)
        .updateFcmToken(peer.remoteDeviceId, fcmToken);
    await ref
        .read(noiseSubscriptionsProvider.notifier)
        .upsert(
          peer: peer,
          fcmToken: fcmToken,
          platform: 'ws',
          leaseSeconds: null,
        );
  }

  /// Handle HTTP request from Android native server.
  Future<void> _handleAndroidHttpRequest({
    required String requestId,
    required String method,
    required String path,
    String? fingerprint,
    String? bodyJson,
  }) async {
    _logControl('Android HTTP $method $path requestId=$requestId');

    try {
      switch (path) {
        case '/health':
          await _respondAndroidHealth(requestId, fingerprint);

        case '/test':
          await _respondAndroidTest(requestId, fingerprint);

        case '/unpair':
          if (method == 'POST') {
            await _respondAndroidUnpair(requestId, fingerprint, bodyJson);
          } else {
            await _androidServer?.respondHttp(requestId, 405, null);
          }

        case '/noise/subscribe':
          if (method == 'POST') {
            await _respondAndroidNoiseSubscribe(
              requestId,
              fingerprint,
              bodyJson,
            );
          } else {
            await _androidServer?.respondHttp(requestId, 405, null);
          }

        case '/noise/unsubscribe':
          if (method == 'POST') {
            await _respondAndroidNoiseUnsubscribe(
              requestId,
              fingerprint,
              bodyJson,
            );
          } else {
            await _androidServer?.respondHttp(requestId, 405, null);
          }

        default:
          await _androidServer?.respondHttp(
            requestId,
            404,
            jsonEncode({'error': 'not_found'}),
          );
      }
    } catch (e) {
      _logControl('Android HTTP error: $e');
      await _androidServer?.respondHttp(
        requestId,
        500,
        jsonEncode({'error': 'internal_error', 'message': '$e'}),
      );
    }
  }

  Future<void> _respondAndroidHealth(
    String requestId,
    String? fingerprint,
  ) async {
    final body = canonicalizeJson({
      'status': 'ok',
      'role': 'monitor',
      'protocol': kTransportHttpWs,
      'activeConnections': _androidConnections.length,
      'mTLS': fingerprint != null,
      'trusted': fingerprint != null,
      if (state.fingerprint != null) 'fingerprint': state.fingerprint,
      if (fingerprint != null) 'clientFingerprint': fingerprint,
    });
    await _androidServer?.respondHttp(requestId, 200, body);
  }

  Future<void> _respondAndroidTest(
    String requestId,
    String? fingerprint,
  ) async {
    if (fingerprint == null) {
      await _androidServer?.respondHttp(
        requestId,
        401,
        canonicalizeJson({
          'error': 'client_certificate_required',
          'message': 'This endpoint requires mTLS authentication',
        }),
      );
      return;
    }

    await _androidServer?.respondHttp(
      requestId,
      200,
      canonicalizeJson({
        'status': 'ok',
        'message': 'mTLS authentication successful',
        'clientFingerprint': fingerprint,
        'trusted': true,
      }),
    );
  }

  Future<void> _respondAndroidUnpair(
    String requestId,
    String? fingerprint,
    String? bodyJson,
  ) async {
    if (fingerprint == null) {
      await _androidServer?.respondHttp(
        requestId,
        401,
        canonicalizeJson({
          'error': 'client_certificate_required',
          'message': 'This endpoint requires mTLS authentication',
        }),
      );
      return;
    }

    String? deviceId;
    if (bodyJson != null && bodyJson.isNotEmpty) {
      try {
        final payload = jsonDecode(bodyJson);
        if (payload is Map && payload['deviceId'] is String) {
          deviceId = payload['deviceId'] as String;
        }
      } catch (e) {
        await _androidServer?.respondHttp(
          requestId,
          400,
          canonicalizeJson({
            'error': 'invalid_body',
            'message': 'Body must be JSON with optional deviceId',
          }),
        );
        return;
      }
    }

    final unpaired = await _handleUnpairRequest(fingerprint, deviceId);
    await _androidServer?.respondHttp(
      requestId,
      200,
      canonicalizeJson({
        'status': 'ok',
        'unpaired': unpaired,
        if (deviceId != null) 'deviceId': deviceId,
        if (!unpaired) 'reason': 'device_not_found',
      }),
    );
  }

  Future<void> _respondAndroidNoiseSubscribe(
    String requestId,
    String? fingerprint,
    String? bodyJson,
  ) async {
    if (fingerprint == null) {
      await _androidServer?.respondHttp(
        requestId,
        401,
        canonicalizeJson({
          'error': 'unauthenticated',
          'message': 'Client certificate required',
        }),
      );
      return;
    }

    if (bodyJson == null || bodyJson.isEmpty) {
      await _androidServer?.respondHttp(
        requestId,
        400,
        canonicalizeJson({'error': 'invalid_json', 'message': 'Body required'}),
      );
      return;
    }

    Map<String, dynamic> body;
    try {
      body = jsonDecode(bodyJson) as Map<String, dynamic>;
    } catch (e) {
      await _androidServer?.respondHttp(
        requestId,
        400,
        canonicalizeJson({'error': 'invalid_json', 'message': '$e'}),
      );
      return;
    }

    final fcmToken = body['fcmToken'];
    final platform = body['platform'];
    final leaseSeconds = body['leaseSeconds'];
    final threshold = body['threshold'];
    final cooldownSeconds = body['cooldownSeconds'];
    final autoStreamTypeName = body['autoStreamType'];
    final autoStreamDurationSec = body['autoStreamDurationSec'];

    if (fcmToken is! String || fcmToken.isEmpty) {
      await _androidServer?.respondHttp(
        requestId,
        400,
        canonicalizeJson({
          'error': 'invalid_fcm_token',
          'message': 'fcmToken is required',
        }),
      );
      return;
    }

    if (platform is! String || platform.isEmpty) {
      await _androidServer?.respondHttp(
        requestId,
        400,
        canonicalizeJson({
          'error': 'invalid_platform',
          'message': 'platform is required',
        }),
      );
      return;
    }

    AutoStreamType? autoStreamType;
    if (autoStreamTypeName is String) {
      try {
        autoStreamType = AutoStreamType.values.byName(autoStreamTypeName);
      } catch (_) {
        await _androidServer?.respondHttp(
          requestId,
          400,
          canonicalizeJson({
            'error': 'invalid_auto_stream_type',
            'message': 'autoStreamType must be one of: none, audio, audioVideo',
          }),
        );
        return;
      }
    }

    try {
      final result = await _handleNoiseSubscribeRequest(
        fingerprint: fingerprint,
        fcmToken: fcmToken,
        platform: platform,
        leaseSeconds: leaseSeconds as int?,
        remoteAddress: 'android-native',
        threshold: threshold as int?,
        cooldownSeconds: cooldownSeconds as int?,
        autoStreamType: autoStreamType,
        autoStreamDurationSec: autoStreamDurationSec as int?,
      );

      await _androidServer?.respondHttp(
        requestId,
        200,
        canonicalizeJson({
          'subscriptionId': result.subscriptionId,
          'deviceId': result.deviceId,
          'expiresAt': result.expiresAt.toUtc().toIso8601String(),
          'acceptedLeaseSeconds': result.acceptedLeaseSeconds,
        }),
      );
    } catch (e) {
      _logControl('Android noise subscribe error: $e');
      await _androidServer?.respondHttp(
        requestId,
        500,
        canonicalizeJson({'error': 'internal_error', 'message': '$e'}),
      );
    }
  }

  Future<void> _respondAndroidNoiseUnsubscribe(
    String requestId,
    String? fingerprint,
    String? bodyJson,
  ) async {
    if (fingerprint == null) {
      await _androidServer?.respondHttp(
        requestId,
        401,
        canonicalizeJson({
          'error': 'unauthenticated',
          'message': 'Client certificate required',
        }),
      );
      return;
    }

    if (bodyJson == null || bodyJson.isEmpty) {
      await _androidServer?.respondHttp(
        requestId,
        400,
        canonicalizeJson({'error': 'invalid_json', 'message': 'Body required'}),
      );
      return;
    }

    Map<String, dynamic> body;
    try {
      body = jsonDecode(bodyJson) as Map<String, dynamic>;
    } catch (e) {
      await _androidServer?.respondHttp(
        requestId,
        400,
        canonicalizeJson({'error': 'invalid_json', 'message': '$e'}),
      );
      return;
    }

    final fcmToken = body['fcmToken'] as String?;
    final subscriptionId = body['subscriptionId'] as String?;

    if (fcmToken == null && subscriptionId == null) {
      await _androidServer?.respondHttp(
        requestId,
        400,
        canonicalizeJson({
          'error': 'missing_identifier',
          'message': 'fcmToken or subscriptionId required',
        }),
      );
      return;
    }

    try {
      final result = await _handleNoiseUnsubscribeRequest(
        fingerprint: fingerprint,
        fcmToken: fcmToken,
        subscriptionId: subscriptionId,
        remoteAddress: 'android-native',
      );

      await _androidServer?.respondHttp(
        requestId,
        200,
        canonicalizeJson({
          'deviceId': result.deviceId,
          'unsubscribed': result.removed,
          if (result.subscriptionId != null)
            'subscriptionId': result.subscriptionId,
          if (result.expiresAt != null)
            'expiresAt': result.expiresAt!.toUtc().toIso8601String(),
        }),
      );
    } catch (e) {
      _logControl('Android noise unsubscribe error: $e');
      await _androidServer?.respondHttp(
        requestId,
        500,
        canonicalizeJson({'error': 'internal_error', 'message': '$e'}),
      );
    }
  }

  /// Send a message to a specific connection.
  Future<void> _sendToConnection(
    String connectionId,
    ControlMessage message,
  ) async {
    if (_useAndroidServer) {
      // Android: send via platform channel (toWireJson includes 'type' field)
      final messageJson = jsonEncode(message.toWireJson());
      _logControl('Sending ${message.type.name} to Android $connectionId');
      await _androidServer?.sendTo(connectionId, messageJson);
    } else {
      // Dart: send via WebSocket connection
      final connection = _connections[connectionId];
      if (connection == null) {
        _logControl('Cannot send to unknown connection: $connectionId');
        return;
      }
      _logControl('Sending ${message.type.name} to $connectionId');
      connection.send(message);
    }
  }

  void _listenToConnection(ControlConnection connection) {
    connection.messages.listen(
      (message) => _handleMessage(connection, message),
      onError: (e) =>
          _logControl('Connection error ${connection.connectionId}: $e'),
      onDone: () => _connections.remove(connection.connectionId),
    );
  }

  void _handleMessage(ControlConnection connection, ControlMessage message) {
    _logControl(
      'Received ${message.type.name} from ${connection.connectionId}',
    );
    // Handle control messages
    switch (message) {
      case FcmTokenUpdateMessage(:final fcmToken, :final deviceId):
        unawaited(
          _handleFcmTokenUpdate(
            connection: connection,
            claimedDeviceId: deviceId,
            fcmToken: fcmToken,
          ),
        );

      // WebRTC signaling messages
      case StartStreamRequestMessage(:final sessionId, :final mediaType):
        _handleStreamRequest(connection.connectionId, sessionId, mediaType);

      case WebRtcAnswerMessage(:final sessionId, :final sdp):
        _handleWebRtcAnswer(sessionId, sdp);

      case WebRtcIceMessage(:final sessionId, :final candidate):
        _handleWebRtcIce(sessionId, candidate);

      case EndStreamMessage(:final sessionId):
        _handleEndStream(sessionId);

      default:
        // Other message types handled as needed
        break;
    }
  }

  void _handleStreamRequest(
    String connectionId,
    String sessionId,
    String mediaType,
  ) {
    _logControl('Stream request: session=$sessionId media=$mediaType');
    final streaming = ref.read(monitorStreamingProvider.notifier);
    streaming.handleStreamRequest(
      sessionId: sessionId,
      connectionId: connectionId,
      mediaType: mediaType,
    );
  }

  void _handleWebRtcAnswer(String sessionId, String sdp) {
    _logControl('WebRTC answer: session=$sessionId');
    final streaming = ref.read(monitorStreamingProvider.notifier);
    streaming.handleAnswer(sessionId: sessionId, sdp: sdp);
  }

  void _handleWebRtcIce(String sessionId, Map<String, dynamic> candidate) {
    _logControl('WebRTC ICE: session=$sessionId');
    final streaming = ref.read(monitorStreamingProvider.notifier);
    streaming.handleIceCandidate(sessionId: sessionId, candidate: candidate);
  }

  void _handleEndStream(String sessionId) {
    _logControl('End stream: session=$sessionId');
    final streaming = ref.read(monitorStreamingProvider.notifier);
    streaming.handleEndStream(sessionId: sessionId);
  }

  /// Handle FCM token update from a listener.
  /// Device identity is derived from the mTLS fingerprint to prevent spoofing
  /// another listener's deviceId in the payload.
  Future<void> _handleFcmTokenUpdate({
    required ControlConnection connection,
    required String fcmToken,
    String? claimedDeviceId,
  }) async {
    final listeners = await ref.read(trustedListenersProvider.future);
    final peer = listeners.firstWhereOrNull(
      (p) => p.certFingerprint == connection.peerFingerprint,
    );
    if (peer == null) {
      _logControl(
        'FCM token update rejected: fingerprint not trusted '
        'fp=${shortFingerprint(connection.peerFingerprint)} '
        'remote=${connection.remoteAddress}',
      );
      return;
    }

    if (claimedDeviceId != null && claimedDeviceId != peer.remoteDeviceId) {
      _logControl(
        'FCM token update rejected: device mismatch '
        'claimed=$claimedDeviceId derived=${peer.remoteDeviceId} '
        'fp=${shortFingerprint(peer.certFingerprint)} '
        'remote=${connection.remoteAddress}',
      );
      return;
    }

    _logControl(
      'FCM token update from listener=${peer.remoteDeviceId} '
      'fp=${shortFingerprint(peer.certFingerprint)}',
    );
    await ref
        .read(trustedListenersProvider.notifier)
        .updateFcmToken(peer.remoteDeviceId, fcmToken);
    await ref
        .read(noiseSubscriptionsProvider.notifier)
        .upsert(
          peer: peer,
          fcmToken: fcmToken,
          platform: 'ws',
          leaseSeconds: null,
        );
  }

  /// Handle an authenticated unpair request initiated by a listener.
  Future<bool> _handleUnpairRequest(
    String fingerprint,
    String? deviceId,
  ) async {
    final listeners = await ref.read(trustedListenersProvider.future);
    final peer = listeners.firstWhereOrNull(
      (p) => p.certFingerprint == fingerprint,
    );
    if (peer == null) {
      _logControl(
        'Unpair request ignored: listener fingerprint not found '
        'fingerprint=${shortFingerprint(fingerprint)} deviceId=$deviceId',
      );
      return false;
    }

    _logControl(
      'Unpairing listener ${peer.remoteDeviceId} via fingerprint '
      '${shortFingerprint(peer.certFingerprint)} (deviceId=$deviceId ignored)',
    );
    await ref
        .read(trustedListenersProvider.notifier)
        .revoke(peer.remoteDeviceId);
    await ref
        .read(noiseSubscriptionsProvider.notifier)
        .clearForFingerprint(peer.certFingerprint);
    await removeTrustedPeer(peer.certFingerprint);
    return true;
  }

  Future<server.NoiseSubscribeResult> _handleNoiseSubscribeRequest({
    required String fingerprint,
    required String fcmToken,
    required String platform,
    required int? leaseSeconds,
    required String remoteAddress,
    int? threshold,
    int? cooldownSeconds,
    AutoStreamType? autoStreamType,
    int? autoStreamDurationSec,
  }) async {
    final listeners = await ref.read(trustedListenersProvider.future);
    final peer = listeners.firstWhereOrNull(
      (p) => p.certFingerprint == fingerprint,
    );
    if (peer == null) {
      throw StateError('Noise subscribe rejected: fingerprint not trusted');
    }

    final result = await ref
        .read(noiseSubscriptionsProvider.notifier)
        .upsert(
          peer: peer,
          fcmToken: fcmToken,
          platform: platform,
          leaseSeconds: leaseSeconds,
          threshold: threshold,
          cooldownSeconds: cooldownSeconds,
          autoStreamType: autoStreamType,
          autoStreamDurationSec: autoStreamDurationSec,
        );

    final deliveryMode = isWebsocketOnlyNoiseToken(fcmToken)
        ? 'ws-only'
        : platform;
    _logControl(
      'Noise subscribe: device=${peer.remoteDeviceId} remote=$remoteAddress '
      'expiresAt=${DateTime.fromMillisecondsSinceEpoch(result.subscription.expiresAtEpochSec * 1000, isUtc: true)} '
      'delivery=$deliveryMode threshold=${result.subscription.threshold} '
      'cooldown=${result.subscription.cooldownSeconds} '
      'autoStream=${result.subscription.autoStreamType?.name ?? 'default'}',
    );

    return (
      deviceId: peer.remoteDeviceId,
      subscriptionId: result.subscription.subscriptionId,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        result.subscription.expiresAtEpochSec * 1000,
        isUtc: true,
      ),
      acceptedLeaseSeconds: result.acceptedLeaseSeconds,
    );
  }

  Future<server.NoiseUnsubscribeResult> _handleNoiseUnsubscribeRequest({
    required String fingerprint,
    String? fcmToken,
    String? subscriptionId,
    required String remoteAddress,
  }) async {
    final listeners = await ref.read(trustedListenersProvider.future);
    final peer = listeners.firstWhereOrNull(
      (p) => p.certFingerprint == fingerprint,
    );
    if (peer == null) {
      throw StateError('Noise unsubscribe rejected: fingerprint not trusted');
    }

    final removed = await ref
        .read(noiseSubscriptionsProvider.notifier)
        .unsubscribe(
          peer: peer,
          fcmToken: fcmToken,
          subscriptionId: subscriptionId,
        );
    _logControl(
      'Noise unsubscribe: device=${peer.remoteDeviceId} '
      'remote=$remoteAddress removed=${removed != null}',
    );

    return (
      deviceId: peer.remoteDeviceId,
      subscriptionId: subscriptionId ?? removed?.subscriptionId,
      expiresAt: removed == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              removed.expiresAtEpochSec * 1000,
              isUtc: true,
            ),
      removed: removed != null,
    );
  }

  /// Add a newly paired peer to the trusted list.
  /// Uses hot reload to update the server without restart.
  Future<void> addTrustedPeer(TrustedPeer peer) async {
    _logControl(
      'Adding trusted peer: ${peer.remoteDeviceId} '
      'fingerprint=${shortFingerprint(peer.certFingerprint)}',
    );

    if (_useAndroidServer) {
      final androidSrv = _androidServer;
      if (androidSrv == null) return;
      await androidSrv.addTrustedPeer(peer);
    } else {
      final srv = _server;
      if (srv == null) return;
      await srv.addTrustedPeer(peer);
    }

    // Update state with new trusted list
    final newFingerprints = [
      ...state.trustedFingerprints,
      peer.certFingerprint,
    ];
    state = ControlServerState.running(
      port: state.port ?? kControlDefaultPort,
      trustedFingerprints: newFingerprints,
      fingerprint: state.fingerprint ?? '',
      deviceId: state.deviceId ?? '',
    );
  }

  /// Remove a peer from the trusted list.
  Future<void> removeTrustedPeer(String fingerprint) async {
    _logControl(
      'Removing trusted peer: fingerprint=${shortFingerprint(fingerprint)}',
    );

    if (_useAndroidServer) {
      final androidSrv = _androidServer;
      if (androidSrv == null) return;
      await androidSrv.removeTrustedPeer(fingerprint);
    } else {
      final srv = _server;
      if (srv == null) return;
      await srv.removeTrustedPeer(fingerprint);
    }

    await ref
        .read(noiseSubscriptionsProvider.notifier)
        .clearForFingerprint(fingerprint);

    // Update state
    final newFingerprints = state.trustedFingerprints
        .where((fp) => fp != fingerprint)
        .toList();
    state = ControlServerState.running(
      port: state.port ?? kControlDefaultPort,
      trustedFingerprints: newFingerprints,
      fingerprint: state.fingerprint ?? '',
      deviceId: state.deviceId ?? '',
    );
  }

  /// Broadcast a message to all connected clients.
  Future<void> broadcast(ControlMessage message) async {
    if (_useAndroidServer) {
      final count = _androidConnections.length;
      _logControl('Broadcasting ${message.type.name} to $count Android clients');
      // toWireJson includes 'type' field required for deserialization
      final messageJson = jsonEncode(message.toWireJson());
      await _androidServer?.broadcast(messageJson);
    } else {
      _logControl(
        'Broadcasting ${message.type.name} to ${_connections.length} clients',
      );
      for (final conn in _connections.values) {
        try {
          await conn.send(message);
        } catch (e) {
          _logControl('Broadcast to ${conn.connectionId} failed: $e');
        }
      }
    }
  }

  /// Send a message to a specific connection.
  Future<void> sendTo(String connectionId, ControlMessage message) async {
    if (_useAndroidServer) {
      // toWireJson includes 'type' field required for deserialization
      final messageJson = jsonEncode(message.toWireJson());
      await _androidServer?.sendTo(connectionId, messageJson);
    } else {
      final conn = _connections[connectionId];
      if (conn == null) {
        _logControl('Cannot send to $connectionId - not connected');
        return;
      }
      await conn.send(message);
    }
  }

  /// Broadcast a noise event to eligible listeners via WebSocket AND FCM.
  /// Filters per subscription based on threshold and cooldown preferences.
  Future<void> broadcastNoiseEvent({
    required int timestampMs,
    required int peakLevel,
  }) async {
    final deviceId = state.deviceId ?? '';
    final message = NoiseEventMessage(
      deviceId: deviceId,
      timestamp: timestampMs,
      peakLevel: peakLevel,
    );

    // Get active subscriptions with their preferences
    final subsController = ref.read(noiseSubscriptionsProvider.notifier);
    await subsController.removeExpired();
    final activeSubs = subsController.active();

    // Filter subscriptions based on per-listener threshold and cooldown
    final eligibleSubs = <NoiseSubscription>[];
    for (final sub in activeSubs) {
      // Check threshold
      if (peakLevel < sub.effectiveThreshold) {
        continue;
      }

      // Check cooldown
      final lastBroadcast =
          _lastBroadcastPerSubscription[sub.subscriptionId] ?? 0;
      final cooldownMs = sub.effectiveCooldownSeconds * 1000;
      if (timestampMs - lastBroadcast < cooldownMs) {
        continue;
      }

      // Subscription is eligible
      eligibleSubs.add(sub);
      _lastBroadcastPerSubscription[sub.subscriptionId] = timestampMs;
    }

    if (eligibleSubs.isEmpty) {
      _logControl(
        'No eligible subscriptions for noise event (level=$peakLevel)',
      );
      return;
    }

    _logControl(
      'Broadcasting noise to ${eligibleSubs.length}/${activeSubs.length} '
      'eligible subscriptions (level=$peakLevel)',
    );

    // Path 1: WebSocket broadcast to connected clients
    // (only to those whose subscription is eligible)
    final eligibleFingerprints = eligibleSubs
        .map((s) => s.certFingerprint)
        .toSet();

    if (_useAndroidServer) {
      // Android: send to eligible connections via platform channel
      // toWireJson includes 'type' field required for deserialization
      final messageJson = jsonEncode(message.toWireJson());
      for (final entry in _androidConnections.entries) {
        if (eligibleFingerprints.contains(entry.value)) {
          try {
            await _androidServer?.sendTo(entry.key, messageJson);
          } catch (e) {
            _logControl('Failed to send to Android ${entry.key}: $e');
          }
        }
      }
    } else {
      // Dart: send to eligible connections directly
      for (final conn in _connections.values) {
        if (eligibleFingerprints.contains(conn.peerFingerprint)) {
          try {
            await conn.send(message);
          } catch (e) {
            _logControl('Failed to send to ${conn.connectionId}: $e');
          }
        }
      }
    }

    // Path 2: FCM push to eligible listeners (only if no WebSocket connection)
    await _sendNoiseEventViaFcmFiltered(
      deviceId: deviceId,
      timestamp: timestampMs,
      peakLevel: peakLevel,
      eligibleSubs: eligibleSubs,
    );
  }

  /// Send noise event via FCM to pre-filtered eligible subscriptions.
  /// Only sends to subscriptions that don't have an active WebSocket connection.
  Future<void> _sendNoiseEventViaFcmFiltered({
    required String deviceId,
    required int timestamp,
    required int peakLevel,
    required List<NoiseSubscription> eligibleSubs,
  }) async {
    // Filter out subscriptions that have active WebSocket connections
    final connectedFingerprints = _useAndroidServer
        ? _androidConnections.values.toSet()
        : _connections.values.map((c) => c.peerFingerprint).toSet();
    final subsWithoutWebSocket = eligibleSubs
        .where((s) => !connectedFingerprints.contains(s.certFingerprint))
        .toList();

    final wsOnlyCount = subsWithoutWebSocket
        .where((s) => s.isWebsocketOnly)
        .length;
    _logControl(
      'Noise FCM filter: eligible=${eligibleSubs.length} '
      'noWs=${subsWithoutWebSocket.length} wsOnly=$wsOnlyCount '
      'connectedWs=${connectedFingerprints.length}',
    );

    if (subsWithoutWebSocket.isEmpty) {
      _logControl('All eligible subs have WebSocket, skipping FCM');
      return;
    }

    final subsNeedingFcm = subsWithoutWebSocket
        .where((s) => !s.isWebsocketOnly)
        .toList();

    if (subsNeedingFcm.isEmpty) {
      _logControl('Eligible subs without WebSocket are ws-only, skipping FCM');
      return;
    }

    final fcmTokens = subsNeedingFcm.map((s) => s.fcmToken).toSet().toList();

    if (fcmTokens.isEmpty) {
      _logControl('No FCM tokens available, skipping push');
      return;
    }

    // Get monitor name for notification
    final appSession = ref.read(appSessionProvider).asData?.value;
    final monitorName = appSession?.deviceName ?? 'Monitor';

    try {
      _fcmSender ??= FcmSender();

      if (!_fcmSender!.isEnabled) {
        _logControl('FCM not configured, skipping push');
        return;
      }

      final result = await _fcmSender!.sendNoiseEvent(
        remoteDeviceId: deviceId,
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
        final subsController = ref.read(noiseSubscriptionsProvider.notifier);
        await subsController.clearByTokens(result.invalidTokens);
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
    _androidEventSub?.cancel();
    _androidEventSub = null;
    _connections.clear();
    _androidConnections.clear();
    _fcmSender?.dispose();
    _fcmSender = null;

    // Stop platform-specific server
    try {
      await _server?.stop();
    } catch (_) {}
    _server = null;

    try {
      await _androidServer?.stop();
      _androidServer?.dispose();
    } catch (_) {}
    _androidServer = null;

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

    _logClient(
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

      _logClient(
        'Connected to monitor: connectionId=${_connection!.connectionId} '
        'peer=${shortFingerprint(_connection!.peerFingerprint)}',
      );

      // Listen for messages
      _messageSub = _connection!.messages.listen(
        _handleMessage,
        onError: (e) {
          _logClient('Connection error: $e');
          state = ControlClientState.error(
            remoteDeviceId: monitor.remoteDeviceId,
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
      _logClient('Connection failed: $e');
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
    _logClient('Received ${message.type.name}');

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
    _logClient(
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
    _logClient('Checking dedup for event: ${event.eventId}');
    final dedup = ref.read(noiseEventDeduplicationProvider.notifier);
    final isNew = dedup.processEvent(event);
    _logClient('Dedup result: isNew=$isNew');
    if (!isNew) {
      _logClient('Duplicate noise event ignored (already received via FCM)');
      return;
    }

    _processNewNoiseEvent(event);
  }

  /// Handle noise event received via FCM (background/foreground).
  void _handleFcmNoiseEvent(NoiseEventData event) {
    _logClient(
      'FCM noise event: remoteDeviceId=${event.remoteDeviceId} peakLevel=${event.peakLevel}',
    );

    // Check if already received via WebSocket
    final dedup = ref.read(noiseEventDeduplicationProvider.notifier);
    if (!dedup.processEvent(event)) {
      _logClient(
        'Duplicate noise event ignored (already received via WebSocket)',
      );
      return;
    }

    _processNewNoiseEvent(event);
  }

  /// Process a new (non-duplicate) noise event.
  void _processNewNoiseEvent(NoiseEventData event) {
    _logClient('Processing noise event: ${event.eventId} disposed=$_disposed');

    if (_disposed) {
      _logClient('Noise event ignored: controller disposed');
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
    _logClient('Emitting noise event to stream');
    _noiseEventController.add(event);

    // Check listener settings to determine action
    final listenerSettings = ref.read(listenerSettingsProvider).asData?.value;
    final defaultAction =
        listenerSettings?.defaultAction ?? ListenerDefaultAction.notify;

    _logClient('Noise event action: $defaultAction');

    if (defaultAction == ListenerDefaultAction.autoOpenStream) {
      // Auto-request WebRTC stream from monitor
      _autoRequestStream(event.remoteDeviceId);
    }
  }

  void _onTokenRefresh(String token) {
    if (_disposed) return;
    _logClient('FCM token refreshed, renewing noise subscription');
    unawaited(_subscribeNoiseLease(force: true));
  }

  Future<void> _subscribeNoiseLease({bool force = false}) async {
    if (_currentHost == null ||
        _currentPort == null ||
        _expectedFingerprint == null) {
      _logClient('Noise subscribe skipped: missing monitor address');
      return;
    }
    final token = _resolveNoiseToken();
    if (token == null || token.isEmpty) {
      _logClient('Noise subscribe skipped: no push token');
      return;
    }
    final usingWebsocketOnly = isWebsocketOnlyNoiseToken(token);
    if (_client == null) {
      _logClient('Noise subscribe skipped: client not initialized');
      return;
    }
    final now = DateTime.now().toUtc();
    if (!force &&
        _activeSubscriptionExpiry != null &&
        _activeSubscriptionExpiry!.isAfter(
          now.add(const Duration(minutes: 5)),
        ) &&
        _lastSubscribedToken == token) {
      _logClient('Noise subscription still valid, skipping renew');
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
      _logClient(
        'Noise subscription updated: subId=${response.subscriptionId} '
        'expiresAt=${response.expiresAt.toIso8601String()} '
        'lease=${response.acceptedLeaseSeconds}s '
        'threshold=$effectiveThreshold cooldown=$effectiveCooldown '
        'autoStream=${effectiveAutoStreamType.name} '
        'delivery=${usingWebsocketOnly ? 'ws-only' : 'fcm'}',
      );
    } catch (e) {
      _logClient('Noise subscribe failed: $e');
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
      _logClient('Noise subscription cleared');
    } catch (e) {
      _logClient('Noise unsubscribe failed (ignored): $e');
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
      _logClient('Noise lease renewal timer fired');
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

    final message = WebRtcIceMessage(
      sessionId: sessionId,
      candidate: candidate,
    );
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
  Future<void> _sendFcmTokenToMonitor(String deviceId) async {
    final fcmService = FcmService.instance;
    final fcmToken = fcmService.currentToken;

    if (fcmToken == null || fcmToken.isEmpty) {
      _logClient('No FCM token available, skipping token sync');
      return;
    }

    try {
      final message = FcmTokenUpdateMessage(
        fcmToken: fcmToken,
        deviceId: deviceId,
      );
      await send(message);
      _logClient('Sent FCM token to monitor');
    } catch (e) {
      _logClient('Failed to send FCM token: $e');
    }
  }

  /// Update FCM token with the connected monitor (call when token refreshes).
  Future<void> updateFcmToken(String deviceId, String newToken) async {
    if (state.status != ControlClientStatus.connected) {
      _logClient('Not connected, cannot update FCM token');
      return;
    }

    try {
      final message = FcmTokenUpdateMessage(
        fcmToken: newToken,
        deviceId: deviceId,
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

  /// Refresh the noise subscription with current preferences.
  /// Call this when listener or per-monitor settings change.
  Future<void> refreshNoiseSubscription() async {
    if (state.status != ControlClientStatus.connected) {
      _logClient('refreshNoiseSubscription skipped: not connected');
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
    _logClient('Disconnecting');
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
