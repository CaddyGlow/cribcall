import 'dart:async';

import '../config/build_flags.dart';
import '../control/control_client.dart';
import '../control/control_connection.dart';
import '../control/control_messages.dart';
import '../control/control_server.dart';
import '../control/pairing_server.dart';
import '../domain/models.dart';
import '../identity/device_identity.dart';

/// CLI harness for a monitor device using the two-port architecture.
/// - PairingServer (TLS only, port 48081) for pairing new listeners
/// - ControlServer (mTLS, port 48080) for control connections
class MonitorCliHarness {
  MonitorCliHarness({
    required this.identity,
    required this.monitorName,
    this.controlPort = kControlDefaultPort,
    this.pairingPort = kPairingDefaultPort,
    Iterable<TrustedPeer> trustedPeers = const [],
    this.logger,
    this.onTrustedListener,
    this.onMessage,
  }) : _trustedPeers = [...trustedPeers];

  final DeviceIdentity identity;
  final String monitorName;
  final int controlPort;
  final int pairingPort;
  final List<TrustedPeer> _trustedPeers;
  final void Function(String message)? logger;
  final void Function(TrustedPeer peer)? onTrustedListener;
  final void Function(ControlMessage message)? onMessage;

  PairingServer? _pairingServer;
  ControlServer? _controlServer;
  final List<StreamSubscription> _subscriptions = [];
  bool _started = false;

  int? get boundControlPort => _controlServer?.boundPort;
  int? get boundPairingPort => _pairingServer?.boundPort;

  List<TrustedPeer> get trustedPeers => List.unmodifiable(_trustedPeers);

  Future<void> start() async {
    if (_started) return;

    // Start pairing server (TLS only)
    _pairingServer = PairingServer(
      onPairingComplete: _handlePairingComplete,
    );
    await _pairingServer!.start(
      port: pairingPort,
      identity: identity,
      monitorName: monitorName,
    );
    _log(
      'Pairing server listening on ${_pairingServer!.boundPort} '
      'fingerprint=${_shortFp(identity.certFingerprint)}',
    );

    // Start control server (mTLS)
    _controlServer = ControlServer();
    await _controlServer!.start(
      port: controlPort,
      identity: identity,
      trustedPeers: _trustedPeers,
    );
    _log(
      'Control server listening on ${_controlServer!.boundPort} '
      'fingerprint=${_shortFp(identity.certFingerprint)} '
      'trustedPeers=${_trustedPeers.length}',
    );

    // Listen for control server events
    final eventSub = _controlServer!.events.listen((event) {
      if (event is ClientConnected) {
        _log(
          'Client connected: ${event.connection.connectionId} '
          'peer=${_shortFp(event.connection.peerFingerprint)}',
        );
        _attachConnectionListeners(event.connection);
      } else if (event is ClientDisconnected) {
        _log(
          'Client disconnected: ${event.connectionId} '
          'reason=${event.reason ?? 'closed'}',
        );
      }
    });
    _subscriptions.add(eventSub);

    _started = true;
  }

  Future<void> stop() async {
    if (!_started) return;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    await _pairingServer?.stop();
    await _controlServer?.stop();
    _pairingServer = null;
    _controlServer = null;
    _started = false;
    _log('Monitor harness stopped');
  }

  void _handlePairingComplete(TrustedPeer peer) {
    _log(
      'Pairing complete: id=${peer.deviceId} '
      'name=${peer.name} '
      'fingerprint=${_shortFp(peer.certFingerprint)}',
    );

    // Add to trusted peers
    if (!_trustedPeers.any((p) => p.certFingerprint == peer.certFingerprint)) {
      _trustedPeers.add(peer);
      // Update control server with new trusted peer
      _controlServer?.addTrustedPeer(peer);
    }

    onTrustedListener?.call(peer);
  }

  void _attachConnectionListeners(ControlConnection connection) {
    final messageSub = connection.messages.listen((message) async {
      onMessage?.call(message);
      if (message is PingMessage) {
        await connection.send(PongMessage(timestamp: message.timestamp));
        _log(
          'Ping received on connId=${connection.connectionId}; pong sent '
          'ts=${message.timestamp}',
        );
      } else if (message is NoiseEventMessage) {
        _log(
          'NOISE_EVENT monitorId=${message.monitorId} '
          'peak=${message.peakLevel} '
          'ts=${message.timestamp}',
        );
      }
    });

    _subscriptions.add(messageSub);
  }

  void _log(String message) {
    logger?.call(message);
  }
}

/// CLI harness for a listener device.
/// Uses ControlClient for pairing + mTLS WebSocket control.
class ListenerCliHarness {
  ListenerCliHarness({
    required this.identity,
    required this.monitorHost,
    required this.monitorControlPort,
    required this.monitorPairingPort,
    required this.monitorFingerprint,
    this.listenerName = 'CLI Listener',
    this.logger,
    this.onMessage,
  });

  final DeviceIdentity identity;
  final String monitorHost;
  final int monitorControlPort;
  final int monitorPairingPort;
  final String monitorFingerprint;
  final String listenerName;
  final void Function(String message)? logger;
  final void Function(ControlMessage message)? onMessage;

  ControlClient? _client;
  ControlConnection? _connection;
  StreamSubscription<ControlMessage>? _messageSub;
  bool _stopped = false;

  /// Pair with the monitor using numeric comparison protocol.
  /// Returns the pairing result on success.
  ///
  /// The [onComparisonCode] callback is called with the comparison code that
  /// the user should verify matches what the monitor displays. If it returns
  /// false, pairing is aborted.
  Future<ListenerRunResult> pairAndConnect({
    required Future<bool> Function(String comparisonCode) onComparisonCode,
    bool sendPingAfterConnect = false,
  }) async {
    _stopped = false;
    try {
      _client = ControlClient(identity: identity);

      // Step 1: Initiate pairing
      _log(
        'Starting pairing with $monitorHost:$monitorPairingPort '
        'expectedFp=${_shortFp(monitorFingerprint)}',
      );

      final initResult = await _client!.initPairing(
        host: monitorHost,
        pairingPort: monitorPairingPort,
        expectedFingerprint: monitorFingerprint,
        listenerName: listenerName,
        allowUnpinned: monitorFingerprint.isEmpty,
      );

      _log(
        'Pairing initiated: session=${initResult.sessionId} '
        'comparisonCode=${initResult.comparisonCode}',
      );

      // Step 2: Verify comparison code
      final confirmed = await onComparisonCode(initResult.comparisonCode);
      if (!confirmed) {
        _log('Pairing cancelled: comparison code not confirmed');
        _client?.close();
        return ListenerRunResult.failed('Comparison code not confirmed');
      }

      // Step 3: Confirm pairing
      final effectiveFingerprint = monitorFingerprint.isNotEmpty
          ? monitorFingerprint
          : (_client!.lastSeenFingerprint ?? '');

      final pairingResult = await _client!.confirmPairing(
        host: monitorHost,
        pairingPort: monitorPairingPort,
        expectedFingerprint: effectiveFingerprint,
        sessionId: initResult.sessionId,
        pairingKey: initResult.pairingKey,
        allowUnpinned: monitorFingerprint.isEmpty,
      );

      _log(
        'Pairing successful: monitorId=${pairingResult.monitorId} '
        'monitorName=${pairingResult.monitorName}',
      );

      // Step 4: Connect to control server (mTLS)
      _log(
        'Connecting to control server $monitorHost:$monitorControlPort',
      );

      _connection = await _client!.connect(
        host: monitorHost,
        port: monitorControlPort,
        expectedFingerprint: pairingResult.monitorCertFingerprint,
      );

      _log(
        'Control connection established: ${_connection!.connectionId} '
        'peer=${_shortFp(_connection!.peerFingerprint)}',
      );

      // Listen for messages
      _messageSub = _connection!.messages.listen((message) async {
        onMessage?.call(message);
        if (message is PongMessage) {
          _log('PONG ts=${message.timestamp}');
        } else if (message is PingMessage) {
          await _connection?.send(PongMessage(timestamp: message.timestamp));
        } else if (message is NoiseEventMessage) {
          _log(
            'NOISE_EVENT monitorId=${message.monitorId} '
            'peak=${message.peakLevel} '
            'ts=${message.timestamp}',
          );
        }
      });

      if (sendPingAfterConnect) {
        await _connection!.send(
          PingMessage(timestamp: DateTime.now().millisecondsSinceEpoch),
        );
        _log('Ping sent');
      }

      return ListenerRunResult.paired(
        connectionId: _connection!.connectionId,
        peerFingerprint: _connection!.peerFingerprint,
        pairingResult: pairingResult,
      );
    } catch (e) {
      _log('Pairing/connection failed: $e');
      return ListenerRunResult.failed('$e');
    }
  }

  /// Connect to a monitor that is already trusted (skip pairing).
  Future<ListenerRunResult> connect({
    bool sendPingAfterConnect = false,
  }) async {
    _stopped = false;
    try {
      _client = ControlClient(identity: identity);

      _log(
        'Connecting to control server $monitorHost:$monitorControlPort '
        'expectedFp=${_shortFp(monitorFingerprint)}',
      );

      _connection = await _client!.connect(
        host: monitorHost,
        port: monitorControlPort,
        expectedFingerprint: monitorFingerprint,
      );

      _log(
        'Control connection established: ${_connection!.connectionId} '
        'peer=${_shortFp(_connection!.peerFingerprint)}',
      );

      // Listen for messages
      _messageSub = _connection!.messages.listen((message) async {
        onMessage?.call(message);
        if (message is PongMessage) {
          _log('PONG ts=${message.timestamp}');
        } else if (message is PingMessage) {
          await _connection?.send(PongMessage(timestamp: message.timestamp));
        } else if (message is NoiseEventMessage) {
          _log(
            'NOISE_EVENT monitorId=${message.monitorId} '
            'peak=${message.peakLevel} '
            'ts=${message.timestamp}',
          );
        }
      });

      if (sendPingAfterConnect) {
        await _connection!.send(
          PingMessage(timestamp: DateTime.now().millisecondsSinceEpoch),
        );
        _log('Ping sent');
      }

      return ListenerRunResult.paired(
        connectionId: _connection!.connectionId,
        peerFingerprint: _connection!.peerFingerprint,
      );
    } catch (e) {
      _log('Connection failed: $e');
      return ListenerRunResult.failed('$e');
    }
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _messageSub?.cancel();
    await _connection?.close();
    _messageSub = null;
    _connection = null;
    _client = null;
    _log('Listener harness stopped');
  }

  void _log(String message) {
    logger?.call(message);
  }
}

class ListenerRunResult {
  const ListenerRunResult._({
    required this.paired,
    this.error,
    this.connectionId,
    this.peerFingerprint,
    this.pairingResult,
  });

  final bool paired;
  final String? error;
  final String? connectionId;
  final String? peerFingerprint;
  final PairingResult? pairingResult;

  bool get ok => paired && error == null;

  factory ListenerRunResult.paired({
    String? connectionId,
    String? peerFingerprint,
    PairingResult? pairingResult,
  }) {
    return ListenerRunResult._(
      paired: true,
      connectionId: connectionId,
      peerFingerprint: peerFingerprint,
      pairingResult: pairingResult,
    );
  }

  factory ListenerRunResult.failed(String error) {
    return ListenerRunResult._(paired: false, error: error);
  }
}

String _shortFp(String fingerprint) {
  if (fingerprint.length <= 12) return fingerprint;
  final prefix = fingerprint.substring(0, 6);
  final suffix = fingerprint.substring(fingerprint.length - 4);
  return '$prefix...$suffix';
}
