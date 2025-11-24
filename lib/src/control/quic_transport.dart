import 'dart:async';
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
    final resources = await _quiche.startClient(
      host: endpoint.host,
      port: endpoint.port,
      expectedServerFingerprint: endpoint.expectedServerFingerprint,
      identity: clientIdentity,
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
    final resources = await _quiche.startServer(
      port: port,
      identity: serverIdentity,
      bindAddress: bindAddress,
      trustedFingerprints: trustedListenerFingerprints,
    );
    _nativeConnection = resources.native;
    _cleanupDir = resources.identityDir;
  }

  @override
  Future<void> stop() async {
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

  Future<void> sendMessage(ControlMessage message) =>
      Future.error(_unsupportedQuicError());

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
  StreamSubscription<QuicEvent>? _subscription;

  @override
  Stream<ControlMessage> receiveMessages() => _messages.stream;

  void _handleEvent(QuicEvent event) {
    if (event is QuicMessage) {
      final frames = _decoder.addChunkAndDecodeJson(event.data);
      for (final frame in frames) {
        try {
          _messages.add(ControlMessageFactory.fromWireJson(frame));
        } on FormatException {
          // Ignore malformed messages; protocol layer will enforce framing rules.
        }
      }
    } else if (event is QuicClosed || event is QuicError) {
      _messages.close();
      _subscription?.cancel();
      native.close();
      _maybeCleanup();
    }
  }

  @override
  Future<void> sendMessage(ControlMessage message) async {
    final frame = ControlFrameCodec.encodeJson(message.toWireJson());
    native.send(frame);
  }

  @override
  Future<void> finish() async {
    native.close();
    await _messages.close();
    await _subscription?.cancel();
    _maybeCleanup();
  }

  void _maybeCleanup() {
    () async {
      if (await cleanupDir.exists()) {
        await cleanupDir.delete(recursive: true);
      }
    }();
  }
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
