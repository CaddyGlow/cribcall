import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../identity/device_identity.dart';
import '../identity/pkcs8.dart';
import '../utils/logger.dart';

// -----------------------------------------------------------------------------
// Android Control Server (Platform Channel Bridge)
// -----------------------------------------------------------------------------

/// Server events for Android native control server.
sealed class AndroidControlServerEvent {}

class AndroidClientConnected extends AndroidControlServerEvent {
  AndroidClientConnected({
    required this.connectionId,
    required this.fingerprint,
    required this.remoteAddress,
  });
  final String connectionId;
  final String fingerprint;
  final String remoteAddress;
}

class AndroidClientDisconnected extends AndroidControlServerEvent {
  AndroidClientDisconnected({required this.connectionId, this.reason});
  final String connectionId;
  final String? reason;
}

class AndroidWsMessage extends AndroidControlServerEvent {
  AndroidWsMessage({required this.connectionId, required this.messageJson});
  final String connectionId;
  final String messageJson;
}

class AndroidHttpRequest extends AndroidControlServerEvent {
  AndroidHttpRequest({
    required this.requestId,
    required this.method,
    required this.path,
    this.fingerprint,
    this.bodyJson,
  });
  final String requestId;
  final String method;
  final String path;
  final String? fingerprint;
  final String? bodyJson;
}

class AndroidServerStarted extends AndroidControlServerEvent {
  AndroidServerStarted({required this.port});
  final int port;
}

class AndroidServerError extends AndroidControlServerEvent {
  AndroidServerError({required this.error});
  final String error;
}

/// Android native control server backed by Kotlin foreground service.
/// Handles mTLS and WebSocket in native code for background resilience.
class AndroidControlServer {
  static const _methodChannel = MethodChannel('cribcall/monitor_server');
  static const _eventChannel = EventChannel('cribcall/monitor_events');

  int? _boundPort;
  final _eventsController =
      StreamController<AndroidControlServerEvent>.broadcast();
  StreamSubscription<dynamic>? _eventSubscription;
  bool _started = false;

  int? get boundPort => _boundPort;
  bool get isRunning => _started && _boundPort != null;
  Stream<AndroidControlServerEvent> get events => _eventsController.stream;

  /// Start the control server via Android foreground service.
  Future<void> start({
    required int port,
    required DeviceIdentity identity,
    required List<TrustedPeer> trustedPeers,
  }) async {
    await stop();

    _log(
      'Starting Android control server port=$port '
      'peers=${trustedPeers.length}',
    );

    // Subscribe to events first
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      _handleEvent,
      onError: _handleEventError,
    );

    // Serialize identity for platform channel
    final identityJson = _serializeIdentity(identity);
    final trustedPeersJson = _serializeTrustedPeers(trustedPeers);

    try {
      await _methodChannel.invokeMethod('start', {
        'port': port,
        'identityJson': identityJson,
        'trustedPeersJson': trustedPeersJson,
      });
      _started = true;
      _log('Android control server start requested');
    } catch (e) {
      _log('Android control server start failed: $e');
      _started = false;
      rethrow;
    }
  }

  /// Stop the control server.
  Future<void> stop() async {
    if (!_started) return;
    _log('Stopping Android control server');

    try {
      await _methodChannel.invokeMethod('stop');
    } catch (e) {
      _log('Stop error (ignored): $e');
    }

    _started = false;
    _boundPort = null;
    _eventSubscription?.cancel();
    _eventSubscription = null;
  }

  /// Add a trusted peer dynamically.
  Future<void> addTrustedPeer(TrustedPeer peer) async {
    final peerJson = _serializeTrustedPeer(peer);
    await _methodChannel.invokeMethod('addTrustedPeer', {'peerJson': peerJson});
    _log('Added trusted peer: ${peer.certFingerprint.substring(0, 12)}');
  }

  /// Remove a trusted peer by fingerprint.
  Future<void> removeTrustedPeer(String fingerprint) async {
    await _methodChannel.invokeMethod('removeTrustedPeer', {
      'fingerprint': fingerprint,
    });
    _log('Removed trusted peer: ${fingerprint.substring(0, 12)}');
  }

  /// Broadcast a message to all connected WebSocket clients.
  Future<void> broadcast(String messageJson) async {
    await _methodChannel.invokeMethod('broadcast', {
      'messageJson': messageJson,
    });
  }

  /// Send a message to a specific WebSocket connection.
  Future<void> sendTo(String connectionId, String messageJson) async {
    await _methodChannel.invokeMethod('sendTo', {
      'connectionId': connectionId,
      'messageJson': messageJson,
    });
  }

  /// Respond to a pending HTTP request.
  Future<void> respondHttp(
    String requestId,
    int statusCode,
    String? bodyJson,
  ) async {
    await _methodChannel.invokeMethod('respondHttp', {
      'requestId': requestId,
      'statusCode': statusCode,
      'bodyJson': bodyJson,
    });
  }

  /// Check if the server is running.
  Future<bool> checkRunning() async {
    try {
      final running = await _methodChannel.invokeMethod<bool>('isRunning');
      return running ?? false;
    } catch (e) {
      return false;
    }
  }

  void _handleEvent(dynamic event) {
    if (event is! Map) {
      _log('Invalid event type: ${event.runtimeType}');
      return;
    }

    final eventType = event['event'] as String?;
    _log('Received event: $eventType');

    switch (eventType) {
      case 'serverStarted':
        _boundPort = event['port'] as int?;
        _eventsController.add(AndroidServerStarted(port: _boundPort ?? 0));

      case 'serverError':
        final error = event['error'] as String? ?? 'Unknown error';
        _eventsController.add(AndroidServerError(error: error));
        _started = false;
        _boundPort = null;

      case 'clientConnected':
        _eventsController.add(
          AndroidClientConnected(
            connectionId: event['connectionId'] as String? ?? '',
            fingerprint: event['fingerprint'] as String? ?? '',
            remoteAddress: event['remoteAddress'] as String? ?? '',
          ),
        );

      case 'clientDisconnected':
        _eventsController.add(
          AndroidClientDisconnected(
            connectionId: event['connectionId'] as String? ?? '',
            reason: event['reason'] as String?,
          ),
        );

      case 'wsMessage':
        _eventsController.add(
          AndroidWsMessage(
            connectionId: event['connectionId'] as String? ?? '',
            messageJson: event['message'] as String? ?? '',
          ),
        );

      case 'httpRequest':
        _eventsController.add(
          AndroidHttpRequest(
            requestId: event['requestId'] as String? ?? '',
            method: event['method'] as String? ?? '',
            path: event['path'] as String? ?? '',
            fingerprint: event['fingerprint'] as String?,
            bodyJson: event['body'] as String?,
          ),
        );

      default:
        _log('Unknown event type: $eventType');
    }
  }

  void _handleEventError(dynamic error) {
    _log('Event channel error: $error');
    _eventsController.add(AndroidServerError(error: '$error'));
  }

  // ---------------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------------

  String _serializeIdentity(DeviceIdentity identity) {
    return jsonEncode({
      'deviceId': identity.deviceId,
      'certDer': base64Encode(identity.certificateDer),
      'privateKey': base64Encode(_extractPrivateKeyBytes(identity)),
      'fingerprint': identity.certFingerprint,
    });
  }

  /// Extract raw private key bytes from identity for PKCS#8 encoding.
  List<int> _extractPrivateKeyBytes(DeviceIdentity identity) {
    final keyPair = identity.keyPair;
    if (keyPair is! SimpleKeyPairData) {
      throw StateError('Unsupported key pair type: ${keyPair.runtimeType}');
    }

    // Use the shared PKCS#8 encoder to ensure Android receives a parseable key.
    return p256PrivateKeyPkcs8(
      privateKeyBytes: keyPair.bytes,
      publicKeyBytes: identity.publicKeyUncompressed,
    );
  }

  // Legacy manual PKCS#8 builder removed; p256PrivateKeyPkcs8 is used instead.

  String _serializeTrustedPeers(List<TrustedPeer> peers) {
    return jsonEncode(peers.map((p) => _serializeTrustedPeerMap(p)).toList());
  }

  String _serializeTrustedPeer(TrustedPeer peer) {
    return jsonEncode(_serializeTrustedPeerMap(peer));
  }

  Map<String, dynamic> _serializeTrustedPeerMap(TrustedPeer peer) {
    return {
      'deviceId': peer.remoteDeviceId,
      'fingerprint': peer.certFingerprint,
      if (peer.certificateDer != null)
        'certDer': base64Encode(peer.certificateDer!),
    };
  }

  void dispose() {
    _eventSubscription?.cancel();
    _eventsController.close();
  }
}

const _log = Logger('android_ctrl_server');
