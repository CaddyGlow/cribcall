import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import '../config/build_flags.dart';
import '../identity/device_identity.dart';
import '../identity/pem.dart';
import '../identity/pkcs8.dart';
import 'control_frame_codec.dart';
import 'control_message.dart';
import 'quic_transport.dart';

class HttpControlServer implements QuicControlServer {
  HttpControlServer({this.bindAddress = '0.0.0.0', this.useTls = true});

  final String bindAddress;
  final bool useTls;
  HttpServer? _server;
  final Set<HttpControlConnection> _connections = {};
  final _nonceStore = _NonceStore();
  late DateTime _startedAt;
  String? _fingerprint;
  List<String> _trustedFingerprints = [];

  @override
  Future<void> start({
    required int port,
    required DeviceIdentity serverIdentity,
    List<String> trustedListenerFingerprints = const [],
  }) async {
    await stop();
    _trustedFingerprints = trustedListenerFingerprints;
    _fingerprint = serverIdentity.certFingerprint;
    _startedAt = DateTime.now();
    HttpServer server;
    if (useTls) {
      final context = await _buildSecurityContext(serverIdentity);
      server = await HttpServer.bindSecure(
        bindAddress,
        port,
        context,
        requestClientCertificate: false,
      );
    } else {
      server = await HttpServer.bind(bindAddress, port);
    }
    _server = server;
    server.listen(
      _handleRequest,
      onError: (error, stack) {
        _logHttp('HTTP control server error: $error');
      },
    );
    _logHttp(
      'HTTP control server running on $bindAddress:${_server?.port ?? port} '
      'fingerprint=${_shortFingerprint(_fingerprint ?? '')} '
      'trusted=${_trustedFingerprints.length} '
      'tls=${useTls ? 'enabled' : 'disabled'}',
    );
  }

  @override
  Future<void> stop() async {
    for (final connection in List.of(_connections)) {
      await connection.close();
    }
    _connections.clear();
    await _server?.close(force: true);
    _server = null;
    _nonceStore.clear();
  }

  Future<SecurityContext> _buildSecurityContext(DeviceIdentity identity) async {
    final ctx = SecurityContext();
    final certPem = encodePem('CERTIFICATE', identity.certificateDer);
    final extracted = await identity.keyPair.extract();
    final pkcs8 = ed25519PrivateKeyPkcs8(
      (extracted as SimpleKeyPairData).bytes,
    );
    final keyPem = encodePem('PRIVATE KEY', pkcs8);
    ctx.useCertificateChainBytes(utf8.encode(certPem));
    ctx.usePrivateKeyBytes(utf8.encode(keyPem));
    return ctx;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      switch (request.uri.path) {
        case '/health':
          await _handleHealth(request);
          return;
        case '/control/challenge':
          await _handleChallenge(request);
          return;
        case '/control/ws':
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            await _handleWebSocket(request);
            return;
          }
          break;
      }
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    } catch (e, stack) {
      _logHttp('HTTP request handling failed: $e');
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('internal error')
          ..close();
      } catch (_) {}
    }
  }

  Future<void> _handleHealth(HttpRequest request) async {
    final body = jsonEncode({
      'status': 'ok',
      'role': 'monitor',
      'protocol': kTransportHttpWs,
      'uptimeSec': DateTime.now().difference(_startedAt).inSeconds,
      'activeConnections': _connections.length,
      'lastNoiseEventAt': null,
      'tls': useTls,
      if (_fingerprint != null) 'fingerprint': _fingerprint,
    });
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response
      ..statusCode = HttpStatus.ok
      ..write(body);
    await request.response.close();
  }

  Future<void> _handleChallenge(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..write('method not allowed');
      await request.response.close();
      return;
    }
    final nonce = _nonceStore.issue();
    final body = jsonEncode({
      'nonce': nonce,
      'expiresInSec': _NonceStore.ttl.inSeconds,
    });
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response
      ..statusCode = HttpStatus.ok
      ..write(body);
    await request.response.close();
  }

  Future<void> _handleWebSocket(HttpRequest request) async {
    final nonce = request.headers.value('x-cribcall-nonce');
    final clientCertB64 = request.headers.value('x-cribcall-cert');
    final claimedFingerprint = request.headers.value('x-cribcall-fingerprint');
    final deviceId = request.headers.value('x-cribcall-device-id');
    final signatureB64 = request.headers.value('x-cribcall-signature');
    if (nonce == null ||
        clientCertB64 == null ||
        claimedFingerprint == null ||
        deviceId == null ||
        signatureB64 == null) {
      return _rejectUpgrade(request, 'missing handshake headers');
    }
    if (!_nonceStore.consume(nonce)) {
      return _rejectUpgrade(request, 'nonce expired or unknown');
    }
    List<int> clientCertDer;
    try {
      clientCertDer = base64.decode(clientCertB64);
    } catch (_) {
      return _rejectUpgrade(request, 'invalid client certificate encoding');
    }
    final computedFingerprint = _fingerprintHex(clientCertDer);
    if (computedFingerprint != claimedFingerprint) {
      return _rejectUpgrade(request, 'fingerprint mismatch');
    }
    final publicKey = _extractEd25519PublicKey(clientCertDer);
    if (publicKey == null) {
      return _rejectUpgrade(request, 'unsupported client certificate');
    }
    final verified = await _verifyClientSignature(
      nonce: nonce,
      deviceId: deviceId,
      signatureB64: signatureB64,
      publicKey: publicKey,
    );
    if (!verified) {
      return _rejectUpgrade(request, 'signature verification failed');
    }
    final trusted = _trustedFingerprints.contains(computedFingerprint);
    final socket = await WebSocketTransformer.upgrade(request);
    final connectionId = 'ws-${DateTime.now().microsecondsSinceEpoch}';
    final connection = HttpControlConnection(
      remoteDescription: QuicEndpoint(
        host: request.connectionInfo?.remoteAddress.address ?? 'unknown',
        port: request.connectionInfo?.remotePort ?? 0,
        expectedServerFingerprint: computedFingerprint,
        transport: kTransportHttpWs,
      ),
      socket: socket,
      peerFingerprint: computedFingerprint,
      connectionId: connectionId,
      restrictToPairing: !trusted,
    );
    _connections.add(connection);
    connection.connectionEvents().listen((event) {
      if (event is ControlConnectionClosed || event is ControlConnectionError) {
        _connections.remove(connection);
      }
    });
  }

  Future<void> _rejectUpgrade(HttpRequest request, String reason) async {
    request.response
      ..statusCode = HttpStatus.unauthorized
      ..write(reason);
    await request.response.close();
  }
}

class HttpControlClient implements QuicControlClient {
  HttpControlClient({this.useTls = true});

  final bool useTls;
  @override
  Future<QuicControlConnection> connect({
    required QuicEndpoint endpoint,
    required DeviceIdentity clientIdentity,
  }) async {
    if (endpoint.transport != kTransportHttpWs) {
      return Future.error(
        UnsupportedError('HTTP control transport not selected for endpoint'),
      );
    }
    final client = _httpClient(endpoint.expectedServerFingerprint);
    await _fetchHealth(client, endpoint);
    final nonce = await _fetchNonce(client, endpoint);
    final message = utf8.encode('$nonce:${clientIdentity.deviceId}');
    final signature = await Ed25519().sign(
      message,
      keyPair: clientIdentity.keyPair,
    );
    final uri = Uri(
      scheme: useTls ? 'wss' : 'ws',
      host: endpoint.host,
      port: endpoint.port,
      path: '/control/ws',
    );
    final socket = await WebSocket.connect(
      uri.toString(),
      customClient: client,
      headers: {
        'x-cribcall-nonce': nonce,
        'x-cribcall-cert': base64.encode(clientIdentity.certificateDer),
        'x-cribcall-fingerprint': clientIdentity.certFingerprint,
        'x-cribcall-device-id': clientIdentity.deviceId,
        'x-cribcall-signature': base64.encode(signature.bytes),
      },
    );
    return HttpControlConnection(
      remoteDescription: endpoint,
      socket: socket,
      peerFingerprint: endpoint.expectedServerFingerprint,
      connectionId: 'ws-client-${DateTime.now().microsecondsSinceEpoch}',
    );
  }

  Future<void> _fetchHealth(HttpClient client, QuicEndpoint endpoint) async {
    final uri = Uri(
      scheme: useTls ? 'https' : 'http',
      host: endpoint.host,
      port: endpoint.port,
      path: '/health',
    );
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Health check failed (${response.statusCode})',
        uri: uri,
      );
    }
    final cert = response.certificate;
    if (useTls && cert != null) {
      final fp = _fingerprintHex(cert.der);
      if (fp != endpoint.expectedServerFingerprint) {
        throw HttpException('Health fingerprint mismatch', uri: uri);
      }
    }
    final body = await utf8.decodeStream(response);
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['status'] != 'ok') {
      throw HttpException('Health check returned error', uri: uri);
    }
    final protocol = decoded['protocol'];
    if (protocol != null && protocol != kTransportHttpWs) {
      throw HttpException('Health protocol mismatch: $protocol', uri: uri);
    }
  }

  Future<String> _fetchNonce(HttpClient client, QuicEndpoint endpoint) async {
    final uri = Uri(
      scheme: useTls ? 'https' : 'http',
      host: endpoint.host,
      port: endpoint.port,
      path: '/control/challenge',
    );
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Nonce request failed (${response.statusCode})',
        uri: uri,
      );
    }
    final body = await utf8.decodeStream(response);
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['nonce'] == null) {
      throw HttpException('Nonce missing from server response', uri: uri);
    }
    return decoded['nonce'] as String;
  }

  HttpClient _httpClient(String expectedFingerprint) {
    if (!useTls) return HttpClient();
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    );
    client.badCertificateCallback = (cert, host, port) {
      final fp = _fingerprintHex(cert.der);
      final ok = fp == expectedFingerprint;
      if (!ok) {
        _logHttp(
          'TLS fingerprint mismatch for $host:$port '
          'expected=${_shortFingerprint(expectedFingerprint)} '
          'got=${_shortFingerprint(fp)}',
        );
      }
      return ok;
    };
    return client;
  }
}

class HttpControlConnection extends QuicControlConnection {
  HttpControlConnection({
    required super.remoteDescription,
    required this.socket,
    required this.peerFingerprint,
    required this.connectionId,
    this.restrictToPairing = false,
  }) {
    Future.microtask(() {
      if (_closed) return;
      _connectionEvents.add(
        ControlConnected(
          connectionId: connectionId,
          peerFingerprint: peerFingerprint,
        ),
      );
    });
    _subscription = socket.listen(
      _handleData,
      onError: (error, stack) {
        _connectionEvents.add(
          ControlConnectionError(connectionId: connectionId, message: '$error'),
        );
        _finish();
      },
      onDone: () => _finish(),
    );
  }

  final WebSocket socket;
  final String peerFingerprint;
  final String connectionId;
  final bool restrictToPairing;

  final ControlFrameDecoder _decoder = ControlFrameDecoder();
  final _messages = StreamController<ControlMessage>.broadcast();
  final _connectionEvents =
      StreamController<ControlConnectionEvent>.broadcast();
  StreamSubscription? _subscription;
  bool _closed = false;

  @override
  Stream<ControlMessage> receiveMessages() => _messages.stream;

  @override
  Stream<ControlConnectionEvent> connectionEvents() => _connectionEvents.stream;

  void _handleData(dynamic data) {
    if (_closed) return;
    final bytes = switch (data) {
      List<int> value => Uint8List.fromList(value),
      String text => Uint8List.fromList(utf8.encode(text)),
      _ => null,
    };
    if (bytes == null) return;
    try {
      final frames = _decoder.addChunkAndDecodeJson(bytes);
      for (final frame in frames) {
        final message = ControlMessageFactory.fromWireJson(frame);
        if (restrictToPairing && !_isPairingMessage(message)) {
          _connectionEvents.add(
            ControlConnectionError(
              connectionId: connectionId,
              message: 'Untrusted client attempted non-pairing message',
            ),
          );
          unawaited(close());
          return;
        }
        _messages.add(message);
      }
    } catch (e, stack) {
      _connectionEvents.add(
        ControlConnectionError(connectionId: connectionId, message: '$e'),
      );
      unawaited(close());
    }
  }

  bool _isPairingMessage(ControlMessage message) {
    final type = message.type;
    return type == ControlMessageType.pairRequest ||
        type == ControlMessageType.pinPairingInit ||
        type == ControlMessageType.pinSubmit ||
        type == ControlMessageType.ping ||
        type == ControlMessageType.pong;
  }

  @override
  Future<void> sendMessage(
    ControlMessage message, {
    String? connectionId,
  }) async {
    if (_closed) {
      throw StateError('Connection closed');
    }
    final frame = ControlFrameCodec.encodeJson(message.toWireJson());
    socket.add(frame);
  }

  @override
  Future<void> finish() async {
    await close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await socket.close();
    } catch (_) {}
    await _subscription?.cancel();
    await _messages.close();
    _connectionEvents.add(ControlConnectionClosed(connectionId: connectionId));
    await _connectionEvents.close();
  }

  void _finish() {
    unawaited(close());
  }
}

class _NonceStore {
  static const ttl = Duration(seconds: 60);
  final Map<String, DateTime> _issued = {};
  final _random = Random.secure();

  String issue() {
    _cleanup();
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final nonce = base64.encode(bytes);
    _issued[nonce] = DateTime.now().add(ttl);
    return nonce;
  }

  bool consume(String nonce) {
    _cleanup();
    final expiresAt = _issued.remove(nonce);
    return expiresAt != null && DateTime.now().isBefore(expiresAt);
  }

  void clear() {
    _issued.clear();
  }

  void _cleanup() {
    final now = DateTime.now();
    _issued.removeWhere((_, expires) => expires.isBefore(now));
  }
}

SimplePublicKey? _extractEd25519PublicKey(List<int> certificateDer) {
  try {
    final parser = ASN1Parser(Uint8List.fromList(certificateDer));
    final certSeq = parser.nextObject() as ASN1Sequence;
    final tbs = certSeq.elements.first as ASN1Sequence;
    final spki = tbs.elements[6] as ASN1Sequence;
    final bitString = spki.elements[1] as ASN1BitString;
    return SimplePublicKey(bitString.contentBytes(), type: KeyPairType.ed25519);
  } catch (_) {
    return null;
  }
}

Future<bool> _verifyClientSignature({
  required String nonce,
  required String deviceId,
  required String signatureB64,
  required SimplePublicKey publicKey,
}) async {
  try {
    final message = utf8.encode('$nonce:$deviceId');
    final signature = Signature(
      base64.decode(signatureB64),
      publicKey: publicKey,
    );
    return Ed25519().verify(message, signature: signature);
  } catch (_) {
    return false;
  }
}

void _logHttp(String message) {
  developer.log(message, name: 'http_control');
}

String _fingerprintHex(List<int> bytes) {
  final digest = sha256.convert(bytes);
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _shortFingerprint(String fingerprint) {
  if (fingerprint.length <= 12) {
    return fingerprint;
  }
  final prefix = fingerprint.substring(0, 6);
  final suffix = fingerprint.substring(fingerprint.length - 4);
  return '$prefix...$suffix';
}
