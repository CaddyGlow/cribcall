import 'dart:async';
import 'dart:developer' as developer;
import 'dart:convert';
import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/build_flags.dart';
import '../domain/models.dart';
import '../identity/device_identity.dart';
import '../pairing/pin_pairing_controller.dart';
import '../state/app_state.dart';
import 'control_channel.dart';
import 'control_message.dart';
import 'control_transport.dart';
import 'http_transport.dart';

class ControlTransports {
  const ControlTransports({
    required this.defaultTransport,
    required this.httpClient,
    required this.httpServer,
  });

  final String defaultTransport;
  final ControlClient httpClient;
  final ControlServer httpServer;

  ControlClient? clientFor(String transport) {
    if (transport == kTransportHttpWs) return httpClient;
    return null;
  }

  ControlServer? serverFor(String transport) {
    if (transport == kTransportHttpWs) return httpServer;
    return null;
  }

  factory ControlTransports.create() {
    return ControlTransports(
      defaultTransport: kDefaultControlTransport,
      httpClient: HttpControlClient(),
      httpServer: HttpControlServer(),
    );
  }
}

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
  ControlServerController({ControlTransports? transports})
    : _transports = transports;

  final ControlTransports? _transports;
  ControlTransports? _resolvedTransports;
  ControlServer? _server;
  _ServerConfig? _activeConfig;
  bool _starting = false;
  DeviceIdentity? _identity;

  @override
  ControlServerState build() {
    try {
      _resolvedTransports = _transports ?? ControlTransports.create();
    } catch (e) {
      _server = const UnsupportedControlServer();
      final errorState = ControlServerState.error(
        error: 'Failed to load control transports: $e',
      );
      state = errorState;
      ref.onDispose(() => _shutdown());
      return errorState;
    }
    ref.onDispose(() => _shutdown());
    return const ControlServerState.stopped();
  }

  Future<void> start({
    required DeviceIdentity identity,
    required int port,
    required List<String> trustedFingerprints,
    List<List<int>> trustedClientCertificates = const [],
  }) async {
    if (_starting) return;
    _resolvedTransports ??= _transports ?? ControlTransports.create();
    final transportKey = _resolvedTransports!.defaultTransport;
    final server = _resolvedTransports!.serverFor(transportKey);
    _logControlServer(
      'Starting control server transport=$transportKey port=$port '
      'trusted=${trustedFingerprints.length} '
      'fingerprint=${_shortFingerprint(identity.certFingerprint)}',
    );
    if (server == null || server is UnsupportedControlServer) {
      state = ControlServerState.error(
        error: 'Control transport ($transportKey) not available',
        port: port,
        trustedFingerprints: trustedFingerprints,
        fingerprint: identity.certFingerprint,
      );
      return;
    }
    // Stop any running server without clearing the selected instance.
    if (_server != null) {
      try {
        await _server?.stop();
      } catch (_) {
        // Best-effort stop; ignore errors.
      }
      _activeConfig = null;
    }
    _server = server;
    final config = _ServerConfig(port, trustedFingerprints, transportKey);
    if (_activeConfig == config &&
        state.status == ControlServerStatus.running) {
      return;
    }
    _starting = true;
    _identity = identity;
    state = ControlServerState.starting(
      port: port,
      trustedFingerprints: trustedFingerprints,
      fingerprint: identity.certFingerprint,
    );
    try {
      // Set up pairing message handler before starting
      if (server is HttpControlServer) {
        _logControlServer('Registering pairing message handler');
        server.setPairingMessageHandler(_handlePairingMessage);
      }
      await _server!.start(
        port: port,
        serverIdentity: identity,
        trustedListenerFingerprints: trustedFingerprints,
        trustedClientCertificates: trustedClientCertificates,
      );
      final actualPort = _serverPort(port);
      _activeConfig = config;
      _logControlServer(
        'Control server running on $actualPort '
        'trusted=${trustedFingerprints.length} '
        'fingerprint=${_shortFingerprint(identity.certFingerprint)}',
      );
      state = ControlServerState.running(
        port: actualPort,
        trustedFingerprints: trustedFingerprints,
        fingerprint: identity.certFingerprint,
      );
    } catch (e) {
      _logControlServer('Control server start failed: $e');
      state = ControlServerState.error(
        error: '$e',
        port: _serverPort(port),
        trustedFingerprints: trustedFingerprints,
        fingerprint: identity.certFingerprint,
      );
    } finally {
      _starting = false;
    }
  }

  /// Handles incoming pairing messages from untrusted clients.
  Future<void> _handlePairingMessage(
    ControlMessage message,
    HttpControlConnection connection,
  ) async {
    _logControlServer(
      'Handling pairing message ${message.type.name} '
      'from connId=${connection.connectionId} '
      'peerFp=${_shortFingerprint(connection.peerFingerprint)}',
    );

    if (message is PinPairingInitMessage) {
      _logControlServer(
        'Received PIN_PAIRING_INIT:\n'
        '  listenerId=${message.listenerId}\n'
        '  listenerName=${message.listenerName}\n'
        '  listenerCertFingerprint=${_shortFingerprint(message.listenerCertFingerprint)}',
      );

      // Check if we have an active PIN session
      final pinController = ref.read(pinSessionProvider.notifier);
      final currentSession = ref.read(pinSessionProvider);

      if (currentSession == null) {
        _logControlServer(
          'No active PIN session on monitor - rejecting PIN_PAIRING_INIT\n'
          '  HINT: Monitor user must tap "Start PIN session" first',
        );
        // Send rejection
        await connection.sendMessage(
          PairRejectedMessage(reason: 'No active PIN session on monitor'),
        );
        return;
      }

      if (currentSession.expired) {
        _logControlServer('PIN session expired - rejecting PIN_PAIRING_INIT');
        await connection.sendMessage(
          PairRejectedMessage(reason: 'PIN session expired'),
        );
        return;
      }

      // Send PIN_REQUIRED with session details
      final pinRequired = PinRequiredMessage(
        pairingSessionId: currentSession.sessionId,
        pakeMsgA: currentSession.pakeMsgA,
        expiresInSec: currentSession.expiresAt
            .difference(DateTime.now())
            .inSeconds
            .clamp(0, 60),
        maxAttempts: currentSession.maxAttempts,
      );
      _logControlServer(
        'Sending PIN_REQUIRED response:\n'
        '  sessionId=${pinRequired.pairingSessionId}\n'
        '  expiresInSec=${pinRequired.expiresInSec}',
      );
      await connection.sendMessage(pinRequired);
    } else if (message is PinSubmitMessage) {
      _logControlServer(
        'Received PIN_SUBMIT:\n'
        '  pairingSessionId=${message.pairingSessionId}',
      );
      // TODO: Validate PIN_SUBMIT and respond with PAIR_ACCEPTED/REJECTED
      // For now, just log it
      _logControlServer(
        'PIN_SUBMIT handling not yet implemented - '
        'pairing will complete on listener side only',
      );
    } else if (message is PairRequestMessage) {
      final monitorIdentity = _identity;
      _logControlServer(
        'Received PAIR_REQUEST:\n'
        '  listenerId=${message.listenerId}\n'
        '  listenerName=${message.listenerName}\n'
        '  listenerCertFingerprint=${_shortFingerprint(message.listenerCertFingerprint)}\n'
        '  peerFp=${_shortFingerprint(connection.peerFingerprint)}',
      );
      if (monitorIdentity == null) {
        _logControlServer(
          'Monitor identity unavailable, rejecting PAIR_REQUEST '
          'peerFp=${_shortFingerprint(connection.peerFingerprint)}',
        );
        await connection.sendMessage(
          PairRejectedMessage(reason: 'monitor identity unavailable'),
        );
        return;
      }
      if (message.listenerCertFingerprint != connection.peerFingerprint) {
        _logControlServer(
          'PAIR_REQUEST fingerprint mismatch '
          'msg=${_shortFingerprint(message.listenerCertFingerprint)} '
          'peer=${_shortFingerprint(connection.peerFingerprint)}',
        );
        await connection.sendMessage(
          PairRejectedMessage(reason: 'fingerprint mismatch'),
        );
        return;
      }
      _logControlServer(
        'PAIR_REQUEST accepted; persisting trusted listener '
        'listenerId=${message.listenerId} '
        'listenerName=${message.listenerName} '
        'fingerprint=${_shortFingerprint(message.listenerCertFingerprint)}',
      );
      final peer = TrustedPeer(
        deviceId: message.listenerId,
        name: message.listenerName,
        certFingerprint: message.listenerCertFingerprint,
        addedAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      await ref.read(trustedListenersProvider.notifier).addListener(peer);
      _logControlServer(
        'Trusted listener persisted '
        'count=${ref.read(trustedListenersProvider).value?.length ?? 0}',
      );
      final server = _server;
      if (server is HttpControlServer) {
        server.addTrustedFingerprint(peer.certFingerprint);
      }
      connection.elevateToTrusted();
      await connection.sendMessage(
        PairAcceptedMessage(monitorId: monitorIdentity.deviceId),
      );
      _logControlServer(
        'Trusted listener added from QR pairing '
        'listenerId=${peer.deviceId} '
        'fingerprint=${_shortFingerprint(peer.certFingerprint)}',
      );
    }
  }

  Future<void> stop() => _shutdown();

  Future<void> _shutdown() async {
    _logControlServer('Stopping control server (status=${state.status.name})');
    _activeConfig = null;
    _identity = null;
    try {
      await _server?.stop();
    } catch (_) {
      // Ignore stop errors; stopping should be best-effort.
    }
    _server = null;
    if (state.status != ControlServerStatus.stopped) {
      state = const ControlServerState.stopped();
    }
  }

  int _serverPort(int requested) {
    final server = _server;
    if (server is HttpControlServer) {
      return server.boundPort ?? requested;
    }
    return requested;
  }
}

enum ControlClientStatus { idle, connecting, connected, error }

class ControlClientState {
  const ControlClientState._({
    required this.status,
    this.monitorId,
    this.monitorName,
    this.connectionId,
    this.peerFingerprint,
    this.failure,
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
    required ControlFailure failure,
  }) : this._(
         status: ControlClientStatus.error,
         monitorId: monitorId,
         monitorName: monitorName,
         failure: failure,
       );

  final ControlClientStatus status;
  final String? monitorId;
  final String? monitorName;
  final String? connectionId;
  final String? peerFingerprint;
  final ControlFailure? failure;
}

class ControlClientController extends Notifier<ControlClientState> {
  ControlClientController({ControlTransports? transports})
    : _transports = transports;

  final ControlTransports? _transports;
  ControlTransports? _resolvedTransports;
  ControlChannel? _channel;
  StreamSubscription<ControlChannelState>? _channelSub;

  @override
  ControlClientState build() {
    try {
      _resolvedTransports = _transports ?? ControlTransports.create();
    } catch (e) {
      final errorState = ControlClientState.error(
        monitorId: '',
        monitorName: '',
        failure: ControlFailure(
          ControlFailureType.transport,
          'Failed to load control transports: $e',
        ),
      );
      state = errorState;
      ref.onDispose(() => disconnect());
      return errorState;
    }
    ref.onDispose(() => disconnect());
    return const ControlClientState.idle();
  }

  Future<ControlFailure?> connectToMonitor({
    required MdnsAdvertisement advertisement,
    required TrustedMonitor monitor,
    required DeviceIdentity identity,
  }) async {
    _resolvedTransports ??= _transports ?? ControlTransports.create();
    await disconnect();
    final transportKey = advertisement.transport;
    final client = _resolvedTransports?.clientFor(transportKey);
    if (client == null || client is UnsupportedControlClient) {
      final failure = ControlFailure(
        ControlFailureType.transport,
        'Control transport ($transportKey) not available in this build',
      );
      state = ControlClientState.error(
        monitorId: monitor.monitorId,
        monitorName: monitor.monitorName,
        failure: failure,
      );
      return failure;
    }
    final ip = advertisement.ip;
    if (ip == null) {
      final failure = ControlFailure(
        ControlFailureType.unknown,
        'Monitor is offline or missing IP address',
      );
      state = ControlClientState.error(
        monitorId: monitor.monitorId,
        monitorName: monitor.monitorName,
        failure: failure,
      );
      return failure;
    }
    state = ControlClientState.connecting(
      monitorId: monitor.monitorId,
      monitorName: monitor.monitorName,
      peerFingerprint: monitor.certFingerprint,
    );
    _logControlClient(
      'Connecting to monitor=${monitor.monitorId} '
      'name=${monitor.monitorName} '
      'ip=$ip '
      'port=${advertisement.servicePort} '
      'transport=$transportKey '
      'expectedFp=${_shortFingerprint(monitor.certFingerprint)}',
    );
    try {
      final endpoint = ControlEndpoint(
        host: ip,
        port: advertisement.servicePort,
        expectedServerFingerprint: monitor.certFingerprint,
        transport: transportKey,
      );
      final connection = await client.connect(
        endpoint: endpoint,
        clientIdentity: identity,
      );
      if (connection == null) {
        final failure = ControlFailure(
          ControlFailureType.transport,
          'Control transport unavailable',
        );
        state = ControlClientState.error(
          monitorId: monitor.monitorId,
          monitorName: monitor.monitorName,
          failure: failure,
        );
        return failure;
      }
      _logControlClient(
        'Control transport connected to ${endpoint.host}:${endpoint.port} '
        'fingerprint=${_shortFingerprint(monitor.certFingerprint)}',
      );
      final channel = ControlChannel(connection: connection);
      _channel = channel;
      _channelSub = channel.states.listen((channelState) {
        switch (channelState.status) {
          case ControlChannelStatus.connected:
            _logControlClient(
              'Control channel connected '
              'connectionId=${channelState.connectionId} '
              'peerFp=${_shortFingerprint(channelState.peerFingerprint ?? '')}',
            );
            state = ControlClientState.connected(
              monitorId: monitor.monitorId,
              monitorName: monitor.monitorName,
              connectionId: channelState.connectionId ?? '',
              peerFingerprint: channelState.peerFingerprint ?? '',
            );
            unawaited(
              _sendPairRequest(channel: channel, listenerIdentity: identity),
            );
            break;
          case ControlChannelStatus.error:
            final failure =
                channelState.failure ??
                ControlFailure(
                  ControlFailureType.transport,
                  'Control channel error',
                );
            _logControlClient(
              'Control channel error '
              'connectionId=${channelState.connectionId ?? ''} '
              'peerFp=${_shortFingerprint(channelState.peerFingerprint ?? '')} '
              'failure=${failure.type.name}: ${failure.message}',
            );
            state = ControlClientState.error(
              monitorId: monitor.monitorId,
              monitorName: monitor.monitorName,
              failure: failure,
            );
            break;
          case ControlChannelStatus.closed:
            _logControlClient(
              'Control channel closed '
              'connectionId=${channelState.connectionId ?? ''}',
            );
            state = const ControlClientState.idle();
            break;
          case ControlChannelStatus.connecting:
            break;
        }
      });
      return null;
    } catch (e) {
      _logControlClient('Control client connect failed: $e');
      final failure = ControlFailure(ControlFailureType.transport, '$e');
      state = ControlClientState.error(
        monitorId: monitor.monitorId,
        monitorName: monitor.monitorName,
        failure: failure,
      );
      return failure;
    }
  }

  Future<void> disconnect() async {
    _logControlClient('Disconnecting control client');
    await _channelSub?.cancel();
    _channelSub = null;
    await _channel?.dispose();
    _channel = null;
    if (state.status != ControlClientStatus.idle) {
      state = const ControlClientState.idle();
    }
  }

  Future<void> _sendPairRequest({
    required ControlChannel channel,
    required DeviceIdentity listenerIdentity,
  }) async {
    try {
      final message = PairRequestMessage(
        listenerId: listenerIdentity.deviceId,
        listenerName: 'Listener',
        listenerPublicKey: base64.encode(listenerIdentity.publicKey.bytes),
        listenerCertFingerprint: listenerIdentity.certFingerprint,
      );
      _logControlClient(
        'Sending PAIR_REQUEST listenerId=${message.listenerId} '
        'fingerprint=${_shortFingerprint(message.listenerCertFingerprint)}',
      );
      await channel.send(message);
      _logControlClient(
        'PAIR_REQUEST sent; waiting for PAIR_ACCEPTED '
        'connId=${channel.state.connectionId ?? 'unknown'}',
      );
    } catch (e) {
      _logControlClient('Failed to send PAIR_REQUEST: $e');
    }
  }
}

class _ServerConfig {
  _ServerConfig(this.port, List<String> trusted, this.transport)
    : trustedFingerprints = List.of(trusted)..sort();

  final int port;
  final List<String> trustedFingerprints;
  final String transport;

  @override
  bool operator ==(Object other) {
    return other is _ServerConfig &&
        other.port == port &&
        other.transport == transport &&
        _listsEqual(other.trustedFingerprints, trustedFingerprints);
  }

  @override
  int get hashCode =>
      Object.hash(port, transport, Object.hashAll(trustedFingerprints));
}

bool _listsEqual(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void _logControlServer(String message) {
  developer.log(message, name: 'control_server');
  debugPrint('[control_server] $message');
}

void _logControlClient(String message) {
  developer.log(message, name: 'control_client');
  debugPrint('[control_client] $message');
}

String _shortFingerprint(String fingerprint) {
  if (fingerprint.length <= 12) return fingerprint;
  final prefix = fingerprint.substring(0, 6);
  final suffix = fingerprint.substring(fingerprint.length - 4);
  return '$prefix...$suffix';
}
