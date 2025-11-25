import 'dart:async';

import '../config/build_flags.dart';
import '../identity/device_identity.dart';
import 'control_message.dart';

class ControlEndpoint {
  ControlEndpoint({
    required this.host,
    required this.port,
    required this.expectedServerFingerprint,
    this.transport = kTransportHttpWs,
  });

  final String host;
  final int port;
  final String expectedServerFingerprint;
  final String transport;
}

/// Simple interface to represent a control connection.
abstract class ControlClient {
  /// Connects to a control endpoint.
  /// Set [allowUnpinned] to true for pairing mode where the server fingerprint
  /// isn't known yet. The PAKE exchange will verify trust cryptographically.
  Future<ControlConnection> connect({
    required ControlEndpoint endpoint,
    required DeviceIdentity clientIdentity,
    bool allowUnpinned = false,
  });
}

abstract class ControlServer {
  Future<void> start({
    required int port,
    required DeviceIdentity serverIdentity,
    List<String> trustedListenerFingerprints = const [],
    List<List<int>> trustedClientCertificates = const [],
  });

  Future<void> stop();
}

class ControlConnection {
  ControlConnection({required this.remoteDescription});

  final ControlEndpoint remoteDescription;

  Stream<ControlMessage> receiveMessages() =>
      Stream.error(_unsupportedControlError());

  Future<void> sendMessage(ControlMessage message, {String? connectionId}) =>
      Future.error(_unsupportedControlError());

  Stream<ControlConnectionEvent> connectionEvents() =>
      const Stream<ControlConnectionEvent>.empty();

  Future<void> finish() async {}

  Future<void> close() async {
    await finish();
  }
}

sealed class ControlConnectionEvent {
  const ControlConnectionEvent({this.connectionId});

  final String? connectionId;
}

class ControlConnected extends ControlConnectionEvent {
  const ControlConnected({
    required super.connectionId,
    required this.peerFingerprint,
  });

  final String peerFingerprint;
}

class ControlConnectionClosed extends ControlConnectionEvent {
  const ControlConnectionClosed({required super.connectionId, this.reason});

  final String? reason;
}

class ControlConnectionError extends ControlConnectionEvent {
  const ControlConnectionError({super.connectionId, required this.message});

  final String message;
}

class UnsupportedControlClient implements ControlClient {
  const UnsupportedControlClient();

  @override
  Future<ControlConnection> connect({
    required ControlEndpoint endpoint,
    required DeviceIdentity clientIdentity,
    bool allowUnpinned = false,
  }) {
    final _ = clientIdentity;
    return Future.error(_unsupportedControlError(endpoint: endpoint));
  }
}

class UnsupportedControlServer implements ControlServer {
  const UnsupportedControlServer();

  @override
  Future<void> start({
    required int port,
    required DeviceIdentity serverIdentity,
    List<String> trustedListenerFingerprints = const [],
    List<List<int>> trustedClientCertificates = const [],
  }) {
    final _ = serverIdentity;
    return Future.error(
      _unsupportedControlError(
        endpoint: ControlEndpoint(
          host: 'localhost',
          port: port,
          expectedServerFingerprint: '',
        ),
      ),
    );
  }

  @override
  Future<void> stop() async {}
}

UnsupportedError _unsupportedControlError({ControlEndpoint? endpoint}) {
  final description = endpoint != null
      ? '${endpoint.host}:${endpoint.port} (${endpoint.transport})'
      : 'requested control endpoint';
  return UnsupportedError(
    'Control transport is unavailable for $description (HTTP+WS only)',
  );
}
