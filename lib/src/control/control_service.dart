import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../identity/device_identity.dart';
import 'control_channel.dart';
import 'native/quiche_library.dart';
import 'quic_transport.dart';

class ControlTransports {
  const ControlTransports({required this.client, required this.server});

  final QuicControlClient client;
  final QuicControlServer server;

  factory ControlTransports.create() {
    final quiche = QuicheLibrary();
    return ControlTransports(
      client: NativeQuicControlClient(quiche: quiche),
      server: NativeQuicControlServer(quiche: quiche),
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
  QuicControlServer? _server;
  _ServerConfig? _activeConfig;
  bool _starting = false;

  @override
  ControlServerState build() {
    try {
      _server = (_transports ?? ControlTransports.create()).server;
    } catch (e) {
      _server = const UnsupportedQuicControlServer();
      final errorState = ControlServerState.error(
        error: 'Failed to load QUIC transport: $e',
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
  }) async {
    if (_starting) return;
    if (_server is UnsupportedQuicControlServer) {
      state = ControlServerState.error(
        error: 'QUIC transport not available on this platform/build',
        port: port,
        trustedFingerprints: trustedFingerprints,
        fingerprint: identity.certFingerprint,
      );
      return;
    }
    final config = _ServerConfig(port, trustedFingerprints);
    if (_activeConfig == config &&
        state.status == ControlServerStatus.running) {
      return;
    }
    _starting = true;
    await _shutdown();
    state = ControlServerState.starting(
      port: port,
      trustedFingerprints: trustedFingerprints,
      fingerprint: identity.certFingerprint,
    );
    try {
      await _server?.start(
        port: port,
        serverIdentity: identity,
        trustedListenerFingerprints: trustedFingerprints,
      );
      _activeConfig = config;
      state = ControlServerState.running(
        port: port,
        trustedFingerprints: trustedFingerprints,
        fingerprint: identity.certFingerprint,
      );
    } catch (e) {
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

  Future<void> stop() => _shutdown();

  Future<void> _shutdown() async {
    _activeConfig = null;
    try {
      await _server?.stop();
    } catch (_) {
      // Ignore stop errors; stopping should be best-effort.
    }
    if (state.status != ControlServerStatus.stopped) {
      state = const ControlServerState.stopped();
    }
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
  QuicControlClient? _client;
  ControlChannel? _channel;
  StreamSubscription<ControlChannelState>? _channelSub;

  @override
  ControlClientState build() {
    try {
      _client = (_transports ?? ControlTransports.create()).client;
    } catch (e) {
      _client = const UnsupportedQuicControlClient();
      final errorState = ControlClientState.error(
        monitorId: '',
        monitorName: '',
        failure: ControlFailure(
          ControlFailureType.transport,
          'Failed to load QUIC transport: $e',
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
    if (_client is UnsupportedQuicControlClient) {
      final failure = ControlFailure(
        ControlFailureType.transport,
        'QUIC transport not available on this platform/build',
      );
      state = ControlClientState.error(
        monitorId: monitor.monitorId,
        monitorName: monitor.monitorName,
        failure: failure,
      );
      return failure;
    }
    await disconnect();
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
    try {
      final endpoint = QuicEndpoint(
        host: ip,
        port: advertisement.servicePort,
        expectedServerFingerprint: monitor.certFingerprint,
      );
      final connection = await _client?.connect(
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
      final channel = ControlChannel(connection: connection);
      _channel = channel;
      _channelSub = channel.states.listen((channelState) {
        switch (channelState.status) {
          case ControlChannelStatus.connected:
            state = ControlClientState.connected(
              monitorId: monitor.monitorId,
              monitorName: monitor.monitorName,
              connectionId: channelState.connectionId ?? '',
              peerFingerprint: channelState.peerFingerprint ?? '',
            );
            break;
          case ControlChannelStatus.error:
            final failure =
                channelState.failure ??
                ControlFailure(
                  ControlFailureType.transport,
                  'Control channel error',
                );
            state = ControlClientState.error(
              monitorId: monitor.monitorId,
              monitorName: monitor.monitorName,
              failure: failure,
            );
            break;
          case ControlChannelStatus.closed:
            state = const ControlClientState.idle();
            break;
          case ControlChannelStatus.connecting:
            break;
        }
      });
      return null;
    } catch (e) {
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
    await _channelSub?.cancel();
    _channelSub = null;
    await _channel?.dispose();
    _channel = null;
    if (state.status != ControlClientStatus.idle) {
      state = const ControlClientState.idle();
    }
  }
}

class _ServerConfig {
  _ServerConfig(this.port, List<String> trusted)
    : trustedFingerprints = List.of(trusted)..sort();

  final int port;
  final List<String> trustedFingerprints;

  @override
  bool operator ==(Object other) {
    return other is _ServerConfig &&
        other.port == port &&
        _listsEqual(other.trustedFingerprints, trustedFingerprints);
  }

  @override
  int get hashCode => Object.hash(port, Object.hashAll(trustedFingerprints));
}

bool _listsEqual(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
