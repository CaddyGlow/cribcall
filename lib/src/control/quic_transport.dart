import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:cribcall_quic/cribcall_quic.dart';

import '../identity/device_identity.dart';
import 'control_frame_codec.dart';
import 'control_message.dart';
import 'native/quiche_library.dart';

class QuicEndpoint {
  QuicEndpoint({
    required this.host,
    required this.port,
    required this.expectedServerFingerprint,
  });

  final String host;
  final int port;
  final String expectedServerFingerprint;
}

/// QUIC control client backed by the Rust/quiche native plugin.
class NativeQuicControlClient implements QuicControlClient {
  NativeQuicControlClient({QuicheLibrary? quiche})
    : _quiche = quiche ?? QuicheLibrary();

  final QuicheLibrary _quiche;

  @override
  Future<QuicControlConnection> connect({
    required QuicEndpoint endpoint,
    required DeviceIdentity clientIdentity,
  }) async {
    _logQuicTransport(
      'Connecting to ${endpoint.host}:${endpoint.port} '
      '(expected fp ${_shortFingerprint(endpoint.expectedServerFingerprint)})',
    );
    final resources = await _quiche.startClient(
      host: endpoint.host,
      port: endpoint.port,
      expectedServerFingerprint: endpoint.expectedServerFingerprint,
      identity: clientIdentity,
    );
    _logQuicTransport(
      'QUIC control client started for ${endpoint.host}:${endpoint.port} '
      'handle=${resources.native.handle}',
    );
    return NativeQuicControlConnection(
      remoteDescription: endpoint,
      native: resources.native,
      cleanupDir: resources.identityDir,
    );
  }
}

/// QUIC control server backed by the Rust/quiche native plugin.
class NativeQuicControlServer implements QuicControlServer {
  NativeQuicControlServer({QuicheLibrary? quiche, this.bindAddress = '0.0.0.0'})
    : _quiche = quiche ?? QuicheLibrary();

  final QuicheLibrary _quiche;
  final String bindAddress;
  List<String> trustedFingerprints = const [];

  QuicNativeConnection? _nativeConnection;
  Directory? _cleanupDir;

  @override
  Future<void> start({
    required int port,
    required DeviceIdentity serverIdentity,
    List<String> trustedListenerFingerprints = const [],
  }) async {
    trustedFingerprints = trustedListenerFingerprints;
    _logQuicTransport(
      'Starting QUIC control server on $bindAddress:$port '
      '(trusted=${trustedListenerFingerprints.length})',
    );
    final resources = await _quiche.startServer(
      port: port,
      identity: serverIdentity,
      bindAddress: bindAddress,
      trustedFingerprints: trustedListenerFingerprints,
    );
    _nativeConnection = resources.native;
    _cleanupDir = resources.identityDir;
    _logQuicTransport(
      'QUIC control server running on $bindAddress:$port handle=${_nativeConnection?.handle}',
    );
  }

  @override
  Future<void> stop() async {
    _logQuicTransport('Stopping QUIC control server');
    _nativeConnection?.close();
    _nativeConnection = null;
    final dir = _cleanupDir;
    _cleanupDir = null;
    if (dir != null && await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}

/// Simple interface to represent a QUIC control connection.
/// Real implementations should use platform-native stacks and enforce
/// certificate pinning before sending any control traffic.
abstract class QuicControlClient {
  Future<QuicControlConnection> connect({
    required QuicEndpoint endpoint,
    required DeviceIdentity clientIdentity,
  });
}

abstract class QuicControlServer {
  Future<void> start({
    required int port,
    required DeviceIdentity serverIdentity,
    List<String> trustedListenerFingerprints = const [],
  });

  Future<void> stop();
}

class QuicControlConnection {
  QuicControlConnection({required this.remoteDescription});

  final QuicEndpoint remoteDescription;

  Stream<ControlMessage> receiveMessages() =>
      Stream.error(_unsupportedQuicError());

  Future<void> sendMessage(ControlMessage message, {String? connectionId}) =>
      Future.error(_unsupportedQuicError());

  Stream<ControlConnectionEvent> connectionEvents() =>
      const Stream<ControlConnectionEvent>.empty();

  Future<void> finish() async {}

  Future<void> close() async {
    await finish();
  }
}

class NativeQuicControlConnection extends QuicControlConnection {
  NativeQuicControlConnection({
    required super.remoteDescription,
    required this.native,
    required this.cleanupDir,
  }) {
    _subscription = native.events.listen(_handleEvent);
  }

  final QuicNativeConnection native;
  final Directory cleanupDir;

  final ControlFrameDecoder _decoder = ControlFrameDecoder();
  final _messages = StreamController<ControlMessage>.broadcast();
  final _connectionEvents =
      StreamController<ControlConnectionEvent>.broadcast();
  bool _closed = false;
  StreamSubscription<QuicEvent>? _subscription;

  @override
  Stream<ControlMessage> receiveMessages() => _messages.stream;

  @override
  Stream<ControlConnectionEvent> connectionEvents() => _connectionEvents.stream;

  void _handleEvent(QuicEvent event) {
    if (_closed) return;
    if (event is QuicMessage) {
      _logQuicTransport(
        'Received QUIC control chunk bytes=${event.data.length} '
        'conn=${event.connectionId ?? 'unknown'}',
      );
      final frames = _decoder.addChunkAndDecodeJson(event.data);
      for (final frame in frames) {
        try {
          _messages.add(ControlMessageFactory.fromWireJson(frame));
        } on FormatException {
          // Ignore malformed messages; protocol layer will enforce framing rules.
        }
      }
    } else if (event is QuicConnected) {
      _logQuicTransport(
        'QUIC connected conn=${event.connectionId ?? 'unknown'} '
        'peer_fp=${_shortFingerprint(event.peerFingerprint)}',
      );
      if (event.connectionId != null) {
        _connectionEvents.add(
          ControlConnected(
            connectionId: event.connectionId!,
            peerFingerprint: event.peerFingerprint,
          ),
        );
      }
    } else if (event is QuicClosed) {
      _logQuicTransport(
        'QUIC closed conn=${event.connectionId ?? 'unknown'} '
        'reason=${event.reason ?? 'none'}',
      );
      if (event.connectionId != null) {
        _connectionEvents.add(
          ControlConnectionClosed(
            connectionId: event.connectionId!,
            reason: event.reason,
          ),
        );
      }
      _finishFromNative();
    } else if (event is QuicError) {
      _logQuicTransport(
        'QUIC error conn=${event.connectionId ?? 'unknown'} '
        'message=${event.message}',
      );
      _connectionEvents.add(
        ControlConnectionError(
          connectionId: event.connectionId,
          message: event.message,
        ),
      );
      _finishFromNative();
    }
  }

  @override
  Future<void> sendMessage(
    ControlMessage message, {
    String? connectionId,
  }) async {
    _logQuicTransport(
      'Sending ${message.runtimeType} over QUIC conn=${connectionId ?? 'auto'}',
    );
    final frame = ControlFrameCodec.encodeJson(message.toWireJson());
    native.send(frame, connectionId: connectionId);
  }

  @override
  Future<void> finish() async {
    await _teardown();
  }

  void _maybeCleanup() {
    () async {
      if (await cleanupDir.exists()) {
        await cleanupDir.delete(recursive: true);
      }
    }();
  }

  void _finishFromNative() {
    unawaited(_teardown());
  }

  Future<void> _teardown() async {
    if (_closed) return;
    _logQuicTransport('Tearing down QUIC control connection');
    _closed = true;
    native.close();
    await _messages.close();
    await _connectionEvents.close();
    await _subscription?.cancel();
    _maybeCleanup();
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

class UnsupportedQuicControlClient implements QuicControlClient {
  const UnsupportedQuicControlClient();

  @override
  Future<QuicControlConnection> connect({
    required QuicEndpoint endpoint,
    required DeviceIdentity clientIdentity,
  }) {
    final _ = clientIdentity;
    return Future.error(_unsupportedQuicError(endpoint: endpoint));
  }
}

class UnsupportedQuicControlServer implements QuicControlServer {
  const UnsupportedQuicControlServer();

  @override
  Future<void> start({
    required int port,
    required DeviceIdentity serverIdentity,
    List<String> trustedListenerFingerprints = const [],
  }) {
    final _ = serverIdentity;
    return Future.error(
      _unsupportedQuicError(
        endpoint: QuicEndpoint(
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

UnsupportedError _unsupportedQuicError({QuicEndpoint? endpoint}) {
  final description = endpoint != null
      ? '${endpoint.host}:${endpoint.port}'
      : 'requested QUIC endpoint';
  return UnsupportedError(
    'QUIC control transport is unavailable for $description',
  );
}

void _logQuicTransport(String message) {
  developer.log(message, name: 'quic_transport');
}

String _shortFingerprint(String fingerprint) {
  if (fingerprint.length <= 12) {
    return fingerprint;
  }
  final prefix = fingerprint.substring(0, 6);
  final suffix = fingerprint.substring(fingerprint.length - 4);
  return '$prefix...$suffix';
}
