/// Control Server Controller for Monitor side (mTLS WebSocket).
///
/// Manages the control server lifecycle, handles client connections,
/// noise subscriptions, and WebRTC streaming coordination.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/build_flags.dart';
import '../domain/models.dart';
import '../domain/noise_subscription.dart';
import '../fcm/fcm_sender.dart';
import '../identity/device_identity.dart';
import '../state/app_state.dart';
import '../util/format_utils.dart';
import '../utils/canonical_json.dart';
import '../utils/logger.dart';
import '../webrtc/monitor_streaming_controller.dart';
import 'android_control_server.dart';
import 'ios_control_server.dart';
import 'control_connection.dart';
import 'control_messages.dart';
import 'control_server.dart' as server;

const _log = Logger('control_ctrl');

// -----------------------------------------------------------------------------
// State Types
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

// -----------------------------------------------------------------------------
// Controller
// -----------------------------------------------------------------------------

class ControlServerController extends Notifier<ControlServerState> {
  // Dart-only server (non-Android/iOS platforms)
  server.ControlServer? _server;
  // Android native server (foreground service)
  AndroidControlServer? _androidServer;
  // iOS native server
  IOSControlServer? _iOSServer;

  bool _starting = false;
  final Map<String, ControlConnection> _connections = {};
  // Native connections don't have ControlConnection, track by connectionId->fingerprint
  final Map<String, String> _nativeConnections = {};
  StreamSubscription<server.ControlServerEvent>? _eventSub;
  StreamSubscription<AndroidControlServerEvent>? _androidEventSub;
  StreamSubscription<IOSControlServerEvent>? _iOSEventSub;
  FcmSender? _fcmSender;

  /// Whether we're using a native server (Android or iOS).
  bool get _useNativeServer => Platform.isAndroid || Platform.isIOS;

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
      _log(
        'Control server already running with same config, skipping restart',
      );
      return;
    }

    _starting = true;

    final platformStr = Platform.isAndroid
        ? 'android-native'
        : Platform.isIOS
            ? 'ios-native'
            : 'dart';
    _log(
      'Starting control server port=$port '
      'trusted=${trustedFingerprints.length} '
      'fingerprint=${shortFingerprint(identity.certFingerprint)} '
      'platform=$platformStr',
    );

    state = ControlServerState.starting(
      port: port,
      trustedFingerprints: trustedFingerprints,
      fingerprint: identity.certFingerprint,
      deviceId: identity.deviceId,
    );

    try {
      if (Platform.isAndroid) {
        await _startAndroidServer(
          port: port,
          identity: identity,
          trustedPeers: trustedPeers,
        );
      } else if (Platform.isIOS) {
        await _startIOSServer(
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

      final actualPort = Platform.isAndroid
          ? (_androidServer?.boundPort ?? port)
          : Platform.isIOS
              ? (_iOSServer?.boundPort ?? port)
              : (_server?.boundPort ?? port);
      _log(
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
      _log('Control server start failed: $e');
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

  /// Start the iOS native control server.
  Future<void> _startIOSServer({
    required int port,
    required DeviceIdentity identity,
    required List<TrustedPeer> trustedPeers,
  }) async {
    _iOSServer ??= IOSControlServer();

    await _iOSServer!.start(
      port: port,
      identity: identity,
      trustedPeers: trustedPeers,
    );

    // Listen for server events
    _iOSEventSub?.cancel();
    _iOSEventSub = _iOSServer!.events.listen(_handleIOSServerEvent);
  }

  /// Handle events from the iOS native control server.
  void _handleIOSServerEvent(IOSControlServerEvent event) {
    switch (event) {
      case IOSServerStarted(:final port):
        _log('iOS server started on port $port');

      case IOSServerError(:final error):
        _log('iOS server error: $error');
        state = ControlServerState.error(
          error: error,
          port: state.port,
          trustedFingerprints: state.trustedFingerprints,
          fingerprint: state.fingerprint,
          deviceId: state.deviceId,
        );

      case IOSClientConnected(
        :final connectionId,
        :final fingerprint,
        :final remoteAddress,
      ):
        _log(
          'iOS client connected: $connectionId '
          'peer=${shortFingerprint(fingerprint)} remote=$remoteAddress',
        );
        _nativeConnections[connectionId] = fingerprint;
        state = state.copyWithConnectionCount(_nativeConnections.length);

      case IOSClientDisconnected(:final connectionId, :final reason):
        _log('iOS client disconnected: $connectionId reason=$reason');
        _nativeConnections.remove(connectionId);
        // Clean up any streaming sessions for this connection
        ref
            .read(monitorStreamingProvider.notifier)
            .endSessionsForConnection(connectionId);
        state = state.copyWithConnectionCount(_nativeConnections.length);

      case IOSWsMessage(:final connectionId, :final messageJson):
        _handleNativeWsMessage(connectionId, messageJson);

      case IOSHttpRequest(
        :final requestId,
        :final method,
        :final path,
        :final fingerprint,
        :final bodyJson,
      ):
        unawaited(_handleNativeHttpRequest(
          requestId: requestId,
          method: method,
          path: path,
          fingerprint: fingerprint,
          bodyJson: bodyJson,
        ));
    }
  }

  void _handleServerEvent(server.ControlServerEvent event) {
    switch (event) {
      case server.ClientConnected(:final connection):
        _log(
          'Client connected: ${connection.connectionId} '
          'peer=${shortFingerprint(connection.peerFingerprint)}',
        );
        _connections[connection.connectionId] = connection;
        _listenToConnection(connection);
        // Update connection count in state
        state = state.copyWithConnectionCount(_connections.length);
      case server.ClientDisconnected(:final connectionId, :final reason):
        _log('Client disconnected: $connectionId reason=$reason');
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
        _log('Android server started on port $port');

      case AndroidServerError(:final error):
        _log('Android server error: $error');
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
        _log(
          'Android client connected: $connectionId '
          'peer=${shortFingerprint(fingerprint)} remote=$remoteAddress',
        );
        _nativeConnections[connectionId] = fingerprint;
        state = state.copyWithConnectionCount(_nativeConnections.length);

      case AndroidClientDisconnected(:final connectionId, :final reason):
        _log('Android client disconnected: $connectionId reason=$reason');
        _nativeConnections.remove(connectionId);
        // Clean up any streaming sessions for this connection
        ref
            .read(monitorStreamingProvider.notifier)
            .endSessionsForConnection(connectionId);
        state = state.copyWithConnectionCount(_nativeConnections.length);

      case AndroidWsMessage(:final connectionId, :final messageJson):
        _handleNativeWsMessage(connectionId, messageJson);

      case AndroidHttpRequest(
        :final requestId,
        :final method,
        :final path,
        :final fingerprint,
        :final bodyJson,
      ):
        unawaited(_handleNativeHttpRequest(
          requestId: requestId,
          method: method,
          path: path,
          fingerprint: fingerprint,
          bodyJson: bodyJson,
        ));
    }
  }

  /// Handle WebSocket messages from native (Android/iOS) server.
  void _handleNativeWsMessage(String connectionId, String messageJson) {
    final fingerprint = _nativeConnections[connectionId];
    if (fingerprint == null) {
      _log('WS message from unknown native connection: $connectionId');
      return;
    }

    try {
      final json = jsonDecode(messageJson) as Map<String, dynamic>;
      final message = ControlMessageFactory.fromWireJson(json);
      _log(
        'Native WS received ${message.type.name} from $connectionId',
      );
      _handleNativeMessage(connectionId, fingerprint, message);
    } catch (e) {
      _log('Failed to parse native WS message: $e');
    }
  }

  /// Handle a control message from native (Android/iOS) connection.
  void _handleNativeMessage(
    String connectionId,
    String fingerprint,
    ControlMessage message,
  ) {
    switch (message) {
      case FcmTokenUpdateMessage(:final fcmToken, :final deviceId):
        unawaited(
          _handleNativeFcmTokenUpdate(
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

  /// Handle FCM token update from native (Android/iOS) connection.
  Future<void> _handleNativeFcmTokenUpdate({
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
      _log(
        'FCM token update rejected: fingerprint not trusted '
        'fp=${shortFingerprint(fingerprint)}',
      );
      return;
    }

    if (claimedDeviceId != null && claimedDeviceId != peer.remoteDeviceId) {
      _log(
        'FCM token update rejected: device mismatch '
        'claimed=$claimedDeviceId derived=${peer.remoteDeviceId}',
      );
      return;
    }

    _log(
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

  /// Handle HTTP request from native (Android/iOS) server.
  Future<void> _handleNativeHttpRequest({
    required String requestId,
    required String method,
    required String path,
    String? fingerprint,
    String? bodyJson,
  }) async {
    _log('Native HTTP $method $path requestId=$requestId');

    try {
      switch (path) {
        case '/health':
          await _respondNativeHealth(requestId, fingerprint);

        case '/test':
          await _respondNativeTest(requestId, fingerprint);

        case '/unpair':
          if (method == 'POST') {
            await _respondNativeUnpair(requestId, fingerprint, bodyJson);
          } else {
            await _respondNativeHttp(requestId, 405, null);
          }

        case '/noise/subscribe':
          if (method == 'POST') {
            await _respondNativeNoiseSubscribe(
              requestId,
              fingerprint,
              bodyJson,
            );
          } else {
            await _respondNativeHttp(requestId, 405, null);
          }

        case '/noise/unsubscribe':
          if (method == 'POST') {
            await _respondNativeNoiseUnsubscribe(
              requestId,
              fingerprint,
              bodyJson,
            );
          } else {
            await _respondNativeHttp(requestId, 405, null);
          }

        default:
          await _respondNativeHttp(
            requestId,
            404,
            jsonEncode({'error': 'not_found'}),
          );
      }
    } catch (e) {
      _log('Native HTTP error: $e');
      await _respondNativeHttp(
        requestId,
        500,
        jsonEncode({'error': 'internal_error', 'message': '$e'}),
      );
    }
  }

  /// Send HTTP response via native (Android/iOS) server.
  Future<void> _respondNativeHttp(
    String requestId,
    int statusCode,
    String? bodyJson,
  ) async {
    if (Platform.isAndroid) {
      await _androidServer?.respondHttp(requestId, statusCode, bodyJson);
    } else if (Platform.isIOS) {
      await _iOSServer?.respondHttp(requestId, statusCode, bodyJson);
    }
  }

  Future<void> _respondNativeHealth(
    String requestId,
    String? fingerprint,
  ) async {
    final body = canonicalizeJson({
      'status': 'ok',
      'role': 'monitor',
      'protocol': kTransportHttpWs,
      'activeConnections': _nativeConnections.length,
      'mTLS': fingerprint != null,
      'trusted': fingerprint != null,
      if (state.fingerprint != null) 'fingerprint': state.fingerprint,
      if (fingerprint != null) 'clientFingerprint': fingerprint,
    });
    await _respondNativeHttp(requestId, 200, body);
  }

  Future<void> _respondNativeTest(
    String requestId,
    String? fingerprint,
  ) async {
    if (fingerprint == null) {
      await _respondNativeHttp(
        requestId,
        401,
        canonicalizeJson({
          'error': 'client_certificate_required',
          'message': 'This endpoint requires mTLS authentication',
        }),
      );
      return;
    }

    await _respondNativeHttp(
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

  Future<void> _respondNativeUnpair(
    String requestId,
    String? fingerprint,
    String? bodyJson,
  ) async {
    if (fingerprint == null) {
      await _respondNativeHttp(
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
        await _respondNativeHttp(
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
    await _respondNativeHttp(
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

  Future<void> _respondNativeNoiseSubscribe(
    String requestId,
    String? fingerprint,
    String? bodyJson,
  ) async {
    if (fingerprint == null) {
      await _respondNativeHttp(
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
      await _respondNativeHttp(
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
      await _respondNativeHttp(
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
      await _respondNativeHttp(
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
      await _respondNativeHttp(
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
        await _respondNativeHttp(
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
        remoteAddress: 'native',
        threshold: threshold as int?,
        cooldownSeconds: cooldownSeconds as int?,
        autoStreamType: autoStreamType,
        autoStreamDurationSec: autoStreamDurationSec as int?,
      );

      await _respondNativeHttp(
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
      _log('Native noise subscribe error: $e');
      await _respondNativeHttp(
        requestId,
        500,
        canonicalizeJson({'error': 'internal_error', 'message': '$e'}),
      );
    }
  }

  Future<void> _respondNativeNoiseUnsubscribe(
    String requestId,
    String? fingerprint,
    String? bodyJson,
  ) async {
    if (fingerprint == null) {
      await _respondNativeHttp(
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
      await _respondNativeHttp(
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
      await _respondNativeHttp(
        requestId,
        400,
        canonicalizeJson({'error': 'invalid_json', 'message': '$e'}),
      );
      return;
    }

    final fcmToken = body['fcmToken'] as String?;
    final subscriptionId = body['subscriptionId'] as String?;

    if (fcmToken == null && subscriptionId == null) {
      await _respondNativeHttp(
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
        remoteAddress: 'native',
      );

      await _respondNativeHttp(
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
      _log('Native noise unsubscribe error: $e');
      await _respondNativeHttp(
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
    if (_useNativeServer) {
      // Native: send via platform channel (toWireJson includes 'type' field)
      final messageJson = jsonEncode(message.toWireJson());
      _log('Sending ${message.type.name} to native $connectionId');
      if (Platform.isAndroid) {
        await _androidServer?.sendTo(connectionId, messageJson);
      } else if (Platform.isIOS) {
        await _iOSServer?.sendTo(connectionId, messageJson);
      }
    } else {
      // Dart: send via WebSocket connection
      final connection = _connections[connectionId];
      if (connection == null) {
        _log('Cannot send to unknown connection: $connectionId');
        return;
      }
      _log('Sending ${message.type.name} to $connectionId');
      connection.send(message);
    }
  }

  void _listenToConnection(ControlConnection connection) {
    connection.messages.listen(
      (message) => _handleMessage(connection, message),
      onError: (e) =>
          _log('Connection error ${connection.connectionId}: $e'),
      onDone: () => _connections.remove(connection.connectionId),
    );
  }

  void _handleMessage(ControlConnection connection, ControlMessage message) {
    _log(
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
    _log('Stream request: session=$sessionId media=$mediaType');
    final streaming = ref.read(monitorStreamingProvider.notifier);
    streaming.handleStreamRequest(
      sessionId: sessionId,
      connectionId: connectionId,
      mediaType: mediaType,
    );
  }

  void _handleWebRtcAnswer(String sessionId, String sdp) {
    _log('WebRTC answer: session=$sessionId');
    final streaming = ref.read(monitorStreamingProvider.notifier);
    streaming.handleAnswer(sessionId: sessionId, sdp: sdp);
  }

  void _handleWebRtcIce(String sessionId, Map<String, dynamic> candidate) {
    _log('WebRTC ICE: session=$sessionId');
    final streaming = ref.read(monitorStreamingProvider.notifier);
    streaming.handleIceCandidate(sessionId: sessionId, candidate: candidate);
  }

  void _handleEndStream(String sessionId) {
    _log('End stream: session=$sessionId');
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
      _log(
        'FCM token update rejected: fingerprint not trusted '
        'fp=${shortFingerprint(connection.peerFingerprint)} '
        'remote=${connection.remoteAddress}',
      );
      return;
    }

    if (claimedDeviceId != null && claimedDeviceId != peer.remoteDeviceId) {
      _log(
        'FCM token update rejected: device mismatch '
        'claimed=$claimedDeviceId derived=${peer.remoteDeviceId} '
        'fp=${shortFingerprint(peer.certFingerprint)} '
        'remote=${connection.remoteAddress}',
      );
      return;
    }

    _log(
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
      _log(
        'Unpair request ignored: listener fingerprint not found '
        'fingerprint=${shortFingerprint(fingerprint)} deviceId=$deviceId',
      );
      return false;
    }

    _log(
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
    _log(
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
    _log(
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
    _log(
      'Adding trusted peer: ${peer.remoteDeviceId} '
      'fingerprint=${shortFingerprint(peer.certFingerprint)}',
    );

    if (_useNativeServer) {
      if (Platform.isAndroid) {
        await _androidServer?.addTrustedPeer(peer);
      } else if (Platform.isIOS) {
        await _iOSServer?.addTrustedPeer(peer);
      }
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
    _log(
      'Removing trusted peer: fingerprint=${shortFingerprint(fingerprint)}',
    );

    if (_useNativeServer) {
      if (Platform.isAndroid) {
        await _androidServer?.removeTrustedPeer(fingerprint);
      } else if (Platform.isIOS) {
        await _iOSServer?.removeTrustedPeer(fingerprint);
      }
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
    if (_useNativeServer) {
      final count = _nativeConnections.length;
      _log('Broadcasting ${message.type.name} to $count native clients');
      // toWireJson includes 'type' field required for deserialization
      final messageJson = jsonEncode(message.toWireJson());
      if (Platform.isAndroid) {
        await _androidServer?.broadcast(messageJson);
      } else if (Platform.isIOS) {
        await _iOSServer?.broadcast(messageJson);
      }
    } else {
      _log(
        'Broadcasting ${message.type.name} to ${_connections.length} clients',
      );
      for (final conn in _connections.values) {
        try {
          await conn.send(message);
        } catch (e) {
          _log('Broadcast to ${conn.connectionId} failed: $e');
        }
      }
    }
  }

  /// Send a message to a specific connection.
  Future<void> sendTo(String connectionId, ControlMessage message) async {
    if (_useNativeServer) {
      // toWireJson includes 'type' field required for deserialization
      final messageJson = jsonEncode(message.toWireJson());
      if (Platform.isAndroid) {
        await _androidServer?.sendTo(connectionId, messageJson);
      } else if (Platform.isIOS) {
        await _iOSServer?.sendTo(connectionId, messageJson);
      }
    } else {
      final conn = _connections[connectionId];
      if (conn == null) {
        _log('Cannot send to $connectionId - not connected');
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
      _log(
        'No eligible subscriptions for noise event (level=$peakLevel)',
      );
      return;
    }

    _log(
      'Broadcasting noise to ${eligibleSubs.length}/${activeSubs.length} '
      'eligible subscriptions (level=$peakLevel)',
    );

    // Path 1: WebSocket broadcast to connected clients
    // (only to those whose subscription is eligible)
    final eligibleFingerprints = eligibleSubs
        .map((s) => s.certFingerprint)
        .toSet();

    if (_useNativeServer) {
      // Native: send to eligible connections via platform channel
      // toWireJson includes 'type' field required for deserialization
      final messageJson = jsonEncode(message.toWireJson());
      for (final entry in _nativeConnections.entries) {
        if (eligibleFingerprints.contains(entry.value)) {
          try {
            if (Platform.isAndroid) {
              await _androidServer?.sendTo(entry.key, messageJson);
            } else if (Platform.isIOS) {
              await _iOSServer?.sendTo(entry.key, messageJson);
            }
          } catch (e) {
            _log('Failed to send to native ${entry.key}: $e');
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
            _log('Failed to send to ${conn.connectionId}: $e');
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
    final connectedFingerprints = _useNativeServer
        ? _nativeConnections.values.toSet()
        : _connections.values.map((c) => c.peerFingerprint).toSet();
    final subsWithoutWebSocket = eligibleSubs
        .where((s) => !connectedFingerprints.contains(s.certFingerprint))
        .toList();

    final wsOnlyCount = subsWithoutWebSocket
        .where((s) => s.isWebsocketOnly)
        .length;
    _log(
      'Noise FCM filter: eligible=${eligibleSubs.length} '
      'noWs=${subsWithoutWebSocket.length} wsOnly=$wsOnlyCount '
      'connectedWs=${connectedFingerprints.length}',
    );

    if (subsWithoutWebSocket.isEmpty) {
      _log('All eligible subs have WebSocket, skipping FCM');
      return;
    }

    final subsNeedingFcm = subsWithoutWebSocket
        .where((s) => !s.isWebsocketOnly)
        .toList();

    if (subsNeedingFcm.isEmpty) {
      _log('Eligible subs without WebSocket are ws-only, skipping FCM');
      return;
    }

    final fcmTokens = subsNeedingFcm.map((s) => s.fcmToken).toSet().toList();

    if (fcmTokens.isEmpty) {
      _log('No FCM tokens available, skipping push');
      return;
    }

    // Get monitor name for notification
    final appSession = ref.read(appSessionProvider).asData?.value;
    final monitorName = appSession?.deviceName ?? 'Monitor';

    try {
      _fcmSender ??= FcmSender();

      if (!_fcmSender!.isEnabled) {
        _log('FCM not configured, skipping push');
        return;
      }

      final result = await _fcmSender!.sendNoiseEvent(
        remoteDeviceId: deviceId,
        monitorName: monitorName,
        timestamp: timestamp,
        peakLevel: peakLevel,
        fcmTokens: fcmTokens,
      );

      _log(
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
      _log('FCM send error: $e');
      // Don't throw - WebSocket delivery is primary path
    }
  }

  Future<void> stop() => _shutdown();

  Future<void> _shutdown() async {
    _log('Stopping control server');
    _eventSub?.cancel();
    _eventSub = null;
    _androidEventSub?.cancel();
    _androidEventSub = null;
    _iOSEventSub?.cancel();
    _iOSEventSub = null;
    _connections.clear();
    _nativeConnections.clear();
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

    try {
      await _iOSServer?.stop();
      _iOSServer?.dispose();
    } catch (_) {}
    _iOSServer = null;

    if (state.status != ControlServerStatus.stopped) {
      state = const ControlServerState.stopped();
    }
  }
}
