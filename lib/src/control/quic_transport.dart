import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_quic/flutter_quic.dart';
import 'package:cryptography/cryptography.dart';
import '../identity/device_identity.dart';
import '../identity/pkcs8.dart';
import 'control_frame_codec.dart';
import 'control_message.dart';

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

/// Simple interface to represent a QUIC control connection.
/// Real implementations should use platform-native stacks (quiche/Cronet/etc.)
/// and enforce certificate pinning before sending any control traffic.
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
  });

  Future<void> stop();
}

class QuicControlConnection {
  QuicControlConnection({
    required this.connection,
    required this.sendStream,
    required this.recvStream,
    required this.decoder,
    required this.remoteDescription,
  });

  final QuicConnection connection;
  QuicSendStream sendStream;
  QuicRecvStream recvStream;
  final ControlFrameDecoder decoder;
  final QuicEndpoint remoteDescription;

  Stream<ControlMessage> receiveMessages() async* {
    var stream = recvStream;
    while (true) {
      final (updatedStream, chunk) = await recvStreamRead(
        stream: stream,
        maxLength: BigInt.from(ControlFrameCodec.maxFrameLength + 4),
      );
      stream = updatedStream;
      if (chunk == null) break;
      final frames = decoder.addChunkAndDecodeJson(chunk);
      for (final json in frames) {
        try {
          yield ControlMessageFactory.fromWireJson(json);
        } catch (_) {
          // Ignore malformed frames; production code should close with PROTOCOL_ERROR.
        }
      }
    }
    recvStream = stream;
  }

  Future<void> sendMessage(ControlMessage message) async {
    final frame = ControlFrameCodec.encodeJson(message.toWireJson());
    sendStream = await sendStreamWriteAll(stream: sendStream, data: frame);
  }

  Future<void> finish() async {
    sendStream = await sendStreamFinish(stream: sendStream);
  }

  Future<void> close() async {
    await finish();
  }
}

class FlutterQuicControlClient implements QuicControlClient {
  FlutterQuicControlClient({this.serverNameOverride});

  final String? serverNameOverride;

  @override
  Future<QuicControlConnection> connect({
    required QuicEndpoint endpoint,
    required DeviceIdentity clientIdentity,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('flutter_quic is unavailable on web');
    }
    await _FlutterQuicRuntime.ensureInitialized();
    // Client identity will be used for mTLS once flutter_quic exposes client auth.
    final _ = clientIdentity;
    final clientEndpoint = await createClientEndpoint();
    final addr = '${endpoint.host}:${endpoint.port}';
    final (_, connection) = await endpointConnect(
      endpoint: clientEndpoint,
      addr: addr,
      serverName: serverNameOverride ?? endpoint.host,
    );
    final (quicConnection, sendStream, recvStream) = await connectionOpenBi(
      connection: connection,
    );
    return QuicControlConnection(
      connection: quicConnection,
      sendStream: sendStream,
      recvStream: recvStream,
      decoder: ControlFrameDecoder(),
      remoteDescription: endpoint,
    );
  }
}

class FlutterQuicControlServer implements QuicControlServer {
  FlutterQuicControlServer({this.bindAddress = '0.0.0.0'});

  final String bindAddress;
  QuicEndpoint? _endpoint;

  @override
  Future<void> start({
    required int port,
    required DeviceIdentity serverIdentity,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('flutter_quic is unavailable on web');
    }
    await _FlutterQuicRuntime.ensureInitialized();
    final keyData = await serverIdentity.keyPair.extract() as SimpleKeyPairData;
    final pkcs8 = ed25519PrivateKeyPkcs8(keyData.bytes);
    final serverConfig = await serverConfigWithSingleCert(
      certChain: [Uint8List.fromList(serverIdentity.certificateDer)],
      key: pkcs8,
    );
    _endpoint = await createServerEndpoint(
      config: serverConfig,
      addr: '$bindAddress:$port',
    );
    // flutter_quic does not currently expose an accept loop; connections
    // must be handled once the plugin surfaces that API.
  }

  @override
  Future<void> stop() async {
    _endpoint = null;
  }
}

class _FlutterQuicRuntime {
  static Future<void>? _initialized;

  static Future<void> ensureInitialized() {
    return _initialized ??= RustLib.init();
  }
}
