import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';

import '../config/build_flags.dart';
import '../identity/device_identity.dart';
import '../identity/pem.dart';
import '../identity/pkcs8.dart';
import '../util/format_utils.dart';
import 'control_frame_codec.dart';
import 'control_message.dart';
import 'control_transport.dart';

/// Callback type for handling incoming pairing messages on the server.
/// The callback receives the message and connection, and can send responses.
typedef PairingMessageHandler =
    Future<void> Function(
      ControlMessage message,
      HttpControlConnection connection,
    );

class HttpControlServer implements ControlServer {
  HttpControlServer({
    this.bindAddress = '0.0.0.0',
    this.useTls = true,
    this.allowUntrustedClients = false,
  });

  final String bindAddress;
  final bool useTls;
  final bool allowUntrustedClients;
  HttpServer? _server;
  int? _boundPort;
  final Set<HttpControlConnection> _connections = {};
  late DateTime _startedAt;
  String? _fingerprint;
  List<String> _trustedFingerprints = [];
  PairingMessageHandler? _pairingMessageHandler;

  /// Sets a handler for incoming pairing messages (PIN_PAIRING_INIT, etc.).
  void setPairingMessageHandler(PairingMessageHandler? handler) {
    _pairingMessageHandler = handler;
  }

  @override
  Future<void> start({
    required int port,
    required DeviceIdentity serverIdentity,
    List<String> trustedListenerFingerprints = const [],
    List<List<int>> trustedClientCertificates = const [],
  }) async {
    if (!useTls) {
      _logHttp(
        'Starting HTTP control server without TLS (allowUntrustedClients=$allowUntrustedClients)',
      );
    }
    await stop();
    _trustedFingerprints = [...trustedListenerFingerprints];
    // Compute fingerprints from trusted client certificates for manual validation
    for (final certDer in trustedClientCertificates) {
      final fp = _fingerprintHex(certDer);
      if (!_trustedFingerprints.contains(fp)) {
        _trustedFingerprints.add(fp);
      }
    }
    _fingerprint = serverIdentity.certFingerprint;
    _startedAt = DateTime.now();
    HttpServer server;
    if (useTls) {
      final context = await _buildSecurityContext(serverIdentity);
      // Add trusted client certificates for TLS-level validation.
      // Both setTrustedCertificatesBytes (for validation) and
      // setClientAuthoritiesBytes (advertised to client) are needed.
      for (final certDer in trustedClientCertificates) {
        try {
          final pem = encodePem('CERTIFICATE', certDer);
          context.setTrustedCertificatesBytes(utf8.encode(pem));
          context.setClientAuthoritiesBytes(utf8.encode(pem));
          _logHttp(
            'Added trusted client cert: ${shortFingerprint(_fingerprintHex(certDer))}',
          );
        } catch (e) {
          _logHttp('Failed to add trusted client certificate: $e');
        }
      }
      _logHttp(
        'Binding HTTPS control server on $bindAddress:$port '
        'fingerprint=${shortFingerprint(_fingerprint ?? '')} '
        'trusted=${_trustedFingerprints.length}',
      );
      server = await HttpServer.bindSecure(
        bindAddress,
        port,
        context,
        requestClientCertificate: true,
      );
    } else {
      _logHttp(
        'Binding HTTP (insecure) control server on $bindAddress:$port '
        'trusted=${_trustedFingerprints.length}',
      );
      server = await HttpServer.bind(bindAddress, port);
    }
    _server = server;
    _boundPort = server.port;
    _logHttp(
      'HTTP control server bound at ${server.address.address}:${server.port} '
      'tls=${useTls ? 'enabled' : 'disabled'}',
    );
    server.listen(
      _handleRequest,
      onError: (error, stack) {
        _logHttp('HTTP control server error: $error');
      },
    );
    _logHttp(
      'HTTP control server running on $bindAddress:${_server?.port ?? port} '
      'fingerprint=${shortFingerprint(_fingerprint ?? '')} '
      'trusted=${_trustedFingerprints.length} '
      'tls=${useTls ? 'enabled' : 'disabled'}',
    );
  }

  @override
  Future<void> stop() async {
    _logHttp(
      'Stopping HTTP control server; activeConnections=${_connections.length}',
    );
    for (final connection in List.of(_connections)) {
      await connection.close();
    }
    _connections.clear();
    await _server?.close(force: true);
    _server = null;
    _boundPort = null;
    _logHttp('HTTP control server stopped');
  }

  int? get boundPort => _boundPort;
  void addTrustedFingerprint(String fingerprint) {
    if (_trustedFingerprints.contains(fingerprint)) return;
    _trustedFingerprints = [..._trustedFingerprints, fingerprint];
    _logHttp(
      'Trusted fingerprint added ${shortFingerprint(fingerprint)} '
      'total=${_trustedFingerprints.length}',
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _logHttp(
      'Incoming request ${request.method} ${request.uri.path} '
      'hasCert=${request.certificate != null}',
    );
    try {
      switch (request.uri.path) {
        case '/health':
          await _handleHealth(request);
          return;
        case '/test':
          await _handleTest(request);
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
      _logHttp('HTTP request handling failed: $e\n$stack');
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('internal error')
          ..close();
      } catch (e2) {
        _logHttp('Failed to send error response: $e2');
      }
    }
  }

  Future<void> _handleHealth(HttpRequest request) async {
    // Health endpoint is always accessible for monitoring purposes,
    // regardless of client certificate presence or allowUntrustedClients setting.
    final remoteIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final remotePort = request.connectionInfo?.remotePort ?? 0;
    try {
      final clientCert = request.certificate;
      if (clientCert != null) {
        final fp = _fingerprintHex(clientCert.der);
        final trusted = _trustedFingerprints.contains(fp);
        _logHttp(
          'Health probe from $remoteIp:$remotePort '
          'clientCert=${clientCert.subject} '
          'fingerprint=${shortFingerprint(fp)} '
          'trusted=$trusted',
        );
      } else {
        _logHttp('Health probe from $remoteIp:$remotePort (no client cert)');
      }
    } catch (e) {
      // Certificate access may fail if TLS layer rejected it but connection continued
      _logHttp('Health probe from $remoteIp:$remotePort (cert access failed: $e)');
    }
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

  /// Test endpoint that enforces mTLS - requires a valid client certificate
  /// with a fingerprint in the trusted list.
  Future<void> _handleTest(HttpRequest request) async {
    final remoteIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final remotePort = request.connectionInfo?.remotePort ?? 0;

    // Check if client certificate is present
    final clientCert = request.certificate;
    if (clientCert == null) {
      _logHttp('Test endpoint rejected $remoteIp:$remotePort - no client cert');
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'error': 'client_certificate_required',
          'message': 'This endpoint requires mTLS authentication',
        }));
      await request.response.close();
      return;
    }

    // Validate fingerprint against trusted list
    final fp = _fingerprintHex(clientCert.der);
    final trusted = _trustedFingerprints.contains(fp);
    if (!trusted) {
      _logHttp(
        'Test endpoint rejected $remoteIp:$remotePort - '
        'untrusted cert fingerprint=${shortFingerprint(fp)}',
      );
      request.response
        ..statusCode = HttpStatus.forbidden
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'error': 'certificate_not_trusted',
          'message': 'Client certificate fingerprint not in trusted list',
          'fingerprint': fp,
        }));
      await request.response.close();
      return;
    }

    _logHttp(
      'Test endpoint accepted $remoteIp:$remotePort '
      'clientCert=${clientCert.subject} '
      'fingerprint=${shortFingerprint(fp)}',
    );
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({
        'status': 'ok',
        'message': 'mTLS authentication successful',
        'clientSubject': clientCert.subject,
        'clientFingerprint': fp,
        'trusted': true,
      }));
    await request.response.close();
  }

  Future<void> _handleWebSocket(HttpRequest request) async {
    final remoteIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final remotePort = request.connectionInfo?.remotePort ?? 0;
    _logHttp(
      'Incoming WS control request from $remoteIp:$remotePort '
      'tls=${request.certificate != null}',
    );
    final clientCert = request.certificate;
    if (clientCert == null && !allowUntrustedClients) {
      return _rejectUpgrade(request, 'client certificate required');
    }
    String computedFingerprint = '';
    List<int>? clientCertDer;
    if (clientCert != null) {
      clientCertDer = clientCert.der;
      computedFingerprint = _fingerprintHex(clientCertDer);
    }
    final trusted = _trustedFingerprints.contains(computedFingerprint);
    _logHttp(
      'Accepted WS control handshake from $remoteIp:$remotePort '
      'fingerprint=${shortFingerprint(computedFingerprint)} '
      'trusted=$trusted pairingOnly=${!trusted}',
    );
    if (clientCert != null) {
      _logHttp(
        'Client certificate subject=${clientCert.subject} '
        'sha256=${shortFingerprint(computedFingerprint)} '
        'issuer=${clientCert.issuer} '
        'validFrom=${clientCert.startValidity} '
        'validTo=${clientCert.endValidity}',
      );
    } else {
      _logHttp('No client certificate presented (allowUntrustedClients=true)');
    }
    final socket = await WebSocketTransformer.upgrade(request);
    final connectionId = 'ws-${DateTime.now().microsecondsSinceEpoch}';
    final connection = HttpControlConnection(
      remoteDescription: ControlEndpoint(
        host: request.connectionInfo?.remoteAddress.address ?? 'unknown',
        port: request.connectionInfo?.remotePort ?? 0,
        expectedServerFingerprint: computedFingerprint,
        transport: kTransportHttpWs,
      ),
      socket: socket,
      peerFingerprint: computedFingerprint,
      connectionId: connectionId,
      peerCertificateDer: clientCertDer,
      restrictToPairing: !trusted,
    );
    _connections.add(connection);
    connection.connectionEvents().listen((event) {
      if (event is ControlConnectionClosed || event is ControlConnectionError) {
        _connections.remove(connection);
        final reason = event is ControlConnectionClosed
            ? event.reason ?? 'closed'
            : (event as ControlConnectionError).message;
        _logHttp(
          'Control connection $connectionId closed '
          'peerFp=${shortFingerprint(computedFingerprint)} '
          'reason=$reason trusted=$trusted pairingOnly=${!trusted}',
        );
      }
    });

    // Listen for incoming messages and route pairing messages to handler
    connection.receiveMessages().listen((message) async {
      final isPairing =
          message.type == ControlMessageType.pinPairingInit ||
          message.type == ControlMessageType.pinSubmit ||
          message.type == ControlMessageType.pairRequest;
      if (isPairing) {
        final handler = _pairingMessageHandler;
        if (handler != null) {
          _logHttp(
            'Routing pairing message ${message.type.name} to handler '
            'connId=$connectionId',
          );
          try {
            await handler(message, connection);
          } catch (e) {
            _logHttp(
              'Pairing message handler error for ${message.type.name}: $e',
            );
          }
        } else {
          _logHttp(
            'No pairing handler registered for ${message.type.name} '
            'connId=$connectionId - message dropped',
          );
        }
      }
    });
  }

  Future<void> _rejectUpgrade(HttpRequest request, String reason) async {
    final remoteIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final remotePort = request.connectionInfo?.remotePort ?? 0;
    _logHttp('Rejecting WS upgrade from $remoteIp:$remotePort reason=$reason');
    request.response
      ..statusCode = HttpStatus.unauthorized
      ..write(reason);
    await request.response.close();
  }
}

class HttpControlClient implements ControlClient {
  HttpControlClient({this.useTls = true});

  final bool useTls;

  /// Connects to a control endpoint.
  /// Set [allowUnpinned] to true for pairing mode where the server fingerprint
  /// isn't known yet. The PAKE exchange will verify trust cryptographically.
  @override
  Future<ControlConnection> connect({
    required ControlEndpoint endpoint,
    required DeviceIdentity clientIdentity,
    bool allowUnpinned = false,
  }) async {
    if (!useTls) {
      throw UnsupportedError('TLS is required for HTTP control client');
    }
    if (endpoint.transport != kTransportHttpWs) {
      return Future.error(
        UnsupportedError('HTTP control transport not selected for endpoint'),
      );
    }
    _logHttp(
      'Connecting to control ${endpoint.host}:${endpoint.port} '
      'tls=${useTls ? 'on' : 'off'} '
      'expectedFp=${shortFingerprint(endpoint.expectedServerFingerprint)} '
      'allowUnpinned=$allowUnpinned',
    );
    final client = await _httpClient(
      endpoint.expectedServerFingerprint,
      clientIdentity,
      allowUnpinned: allowUnpinned,
    );
    try {
      await _fetchHealth(client, endpoint);
    } on HandshakeException catch (e) {
      _logHttp(
        'Health TLS handshake failed: $e '
        'peer=${endpoint.host}:${endpoint.port} '
        'expectedFp=${shortFingerprint(endpoint.expectedServerFingerprint)}',
      );
      rethrow;
    }
    _logHttp(
      'Health check succeeded for ${endpoint.host}:${endpoint.port} '
      'transport=${endpoint.transport}',
    );
    final uri = Uri(
      scheme: 'wss',
      host: endpoint.host,
      port: endpoint.port,
      path: '/control/ws',
    );
    _logHttp('Upgrading to WebSocket ${uri.toString()}');
    WebSocket socket;
    try {
      socket = await WebSocket.connect(uri.toString(), customClient: client)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              _logHttp(
                'WebSocket upgrade timed out to ${endpoint.host}:${endpoint.port}',
              );
              throw const HttpException('WebSocket upgrade timed out');
            },
          );
    } on HandshakeException catch (e) {
      _logHttp(
        'WebSocket handshake failed: $e '
        'endpoint=${endpoint.host}:${endpoint.port} '
        'expectedFp=${shortFingerprint(endpoint.expectedServerFingerprint)}',
      );
      rethrow;
    } catch (e) {
      _logHttp(
        'WebSocket connect failed: $e '
        'endpoint=${endpoint.host}:${endpoint.port}',
      );
      rethrow;
    }
    return HttpControlConnection(
      remoteDescription: endpoint,
      socket: socket,
      peerFingerprint: endpoint.expectedServerFingerprint,
      connectionId: 'ws-client-${DateTime.now().microsecondsSinceEpoch}',
    );
  }

  Future<void> _fetchHealth(HttpClient client, ControlEndpoint endpoint) async {
    final uri = Uri(
      scheme: 'https',
      host: endpoint.host,
      port: endpoint.port,
      path: '/health',
    );
    final request = await client.getUrl(uri);
    _logHttp('Health request ${uri.toString()}');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      _logHttp(
        'Health check failed (${response.statusCode}) '
        'certSubject=${response.certificate?.subject ?? 'none'}',
      );
      throw HttpException(
        'Health check failed (${response.statusCode})',
        uri: uri,
      );
    }
    final cert = response.certificate;
    if (useTls) {
      if (cert == null) {
        _logHttp('Health response missing certificate');
        throw HttpException('Health missing certificate', uri: uri);
      }
      final fp = _fingerprintHex(cert.der);
      if (fp != endpoint.expectedServerFingerprint) {
        _logHttp(
          'Health fingerprint mismatch '
          'expected=${shortFingerprint(endpoint.expectedServerFingerprint)} '
          'got=${shortFingerprint(fp)}',
        );
        throw HttpException('Health fingerprint mismatch', uri: uri);
      }
      _logHttp(
        'Health TLS peer cert subject=${cert.subject} '
        'fp=${shortFingerprint(fp)}',
      );
    }
    final body = await utf8.decodeStream(response);
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['status'] != 'ok') {
      _logHttp('Health returned non-ok payload: $decoded');
      throw HttpException('Health check returned error', uri: uri);
    }
    final protocol = decoded['protocol'];
    if (protocol != null && protocol != kTransportHttpWs) {
      _logHttp('Health protocol mismatch: $protocol');
      throw HttpException('Health protocol mismatch: $protocol', uri: uri);
    }
  }

  Future<HttpClient> _httpClient(
    String expectedFingerprint,
    DeviceIdentity identity, {
    bool allowUnpinned = false,
  }) async {
    if (!useTls) {
      throw UnsupportedError('TLS is required for HTTP control client');
    }
    final context = await _buildSecurityContext(
      identity,
      withTrustedRoots: false,
    );
    final client = HttpClient(context: context);
    client.badCertificateCallback = (cert, host, port) {
      final fp = _fingerprintHex(cert.der);
      // If expectedFingerprint is empty and allowUnpinned is true, accept any cert
      // This is used for PIN pairing where fingerprint isn't known yet
      if (expectedFingerprint.isEmpty) {
        if (allowUnpinned) {
          _logHttp(
            'TLS accepting unpinned cert for $host:$port '
            'gotFp=${shortFingerprint(fp)} (pairing mode)',
          );
          _lastSeenFingerprint = fp;
          return true;
        } else {
          _logHttp(
            'TLS rejecting cert for $host:$port - no expected fingerprint '
            'gotFp=${shortFingerprint(fp)} (set allowUnpinned=true for pairing)',
          );
          return false;
        }
      }
      final ok = fp == expectedFingerprint;
      if (!ok) {
        _logHttp(
          'TLS fingerprint mismatch for $host:$port '
          'expected=${shortFingerprint(expectedFingerprint)} '
          'got=${shortFingerprint(fp)}',
        );
      } else {
        _lastSeenFingerprint = fp;
      }
      return ok;
    };
    return client;
  }

  /// The fingerprint seen during the last connection (for pairing mode).
  String? _lastSeenFingerprint;

  /// Gets the fingerprint of the server certificate from the last connection.
  /// Useful for pairing mode where the fingerprint wasn't known beforehand.
  String? get lastSeenFingerprint => _lastSeenFingerprint;
}

class HttpControlConnection extends ControlConnection {
  HttpControlConnection({
    required super.remoteDescription,
    required this.socket,
    required this.peerFingerprint,
    required this.connectionId,
    this.peerCertificateDer,
    bool restrictToPairing = false,
  }) {
    _logHttp(
      'HTTP control connection established '
      'connId=$connectionId '
      'peerFp=${shortFingerprint(peerFingerprint)} '
      'hasCertDer=${peerCertificateDer != null} '
      'restrictToPairing=$restrictToPairing '
      'remote=${remoteDescription.host}:${remoteDescription.port}',
    );
    _restrictToPairing = restrictToPairing;
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
  /// Full DER-encoded certificate of the peer, if available.
  /// Used to store and trust the peer's certificate for future mTLS connections.
  final List<int>? peerCertificateDer;
  bool _restrictToPairing = false;

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
        if (_restrictToPairing && !_isPairingMessage(message)) {
          _logHttp(
            'Rejecting non-pairing message ${message.type.name} '
            'on connId=$connectionId (pairing-only)',
          );
          _connectionEvents.add(
            ControlConnectionError(
              connectionId: connectionId,
              message: 'Untrusted client attempted non-pairing message',
            ),
          );
          unawaited(close());
          return;
        }
        _logHttp(
          'Received control message ${message.type.name} on connId=$connectionId',
        );
        _messages.add(message);
      }
    } catch (e, _) {
      _logHttp('Control frame decode failed on connId=$connectionId error=$e');
      _connectionEvents.add(
        ControlConnectionError(connectionId: connectionId, message: '$e'),
      );
      unawaited(close());
    }
  }

  bool _isPairingMessage(ControlMessage message) {
    final type = message.type;
    final isPairing =
        type == ControlMessageType.pairRequest ||
        type == ControlMessageType.pinPairingInit ||
        type == ControlMessageType.pinSubmit ||
        type == ControlMessageType.ping ||
        type == ControlMessageType.pong;
    if (type == ControlMessageType.pinPairingInit) {
      final initMsg = message as PinPairingInitMessage;
      _logHttp(
        'Received PIN_PAIRING_INIT on connId=$connectionId:\n'
        '  deviceId=${initMsg.deviceId}\n'
        '  deviceName=${initMsg.deviceName}\n'
        '  certFingerprint=${shortFingerprint(initMsg.certFingerprint)}\n'
        '  NOTE: Monitor should respond with PIN_REQUIRED containing session details',
      );
    } else if (type == ControlMessageType.pinSubmit) {
      final submitMsg = message as PinSubmitMessage;
      _logHttp(
        'Received PIN_SUBMIT on connId=$connectionId:\n'
        '  pairingSessionId=${submitMsg.pairingSessionId}\n'
        '  NOTE: Monitor should validate PAKE response and send PAIR_ACCEPTED/REJECTED',
      );
    } else if (type == ControlMessageType.pinRequired) {
      final requiredMsg = message as PinRequiredMessage;
      _logHttp(
        'Received PIN_REQUIRED on connId=$connectionId:\n'
        '  pairingSessionId=${requiredMsg.pairingSessionId}\n'
        '  expiresInSec=${requiredMsg.expiresInSec}\n'
        '  maxAttempts=${requiredMsg.maxAttempts}\n'
        '  NOTE: Listener should call acceptPinRequired() to hydrate session',
      );
    }
    return isPairing;
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

  void elevateToTrusted() {
    if (_restrictToPairing) {
      _restrictToPairing = false;
      _logHttp('Connection $connectionId elevated to trusted');
    }
  }
}

Future<SecurityContext> _buildSecurityContext(
  DeviceIdentity identity, {
  bool withTrustedRoots = false,
}) async {
  final ctx = SecurityContext(withTrustedRoots: withTrustedRoots);
  final certPem = encodePem('CERTIFICATE', identity.certificateDer);
  final extracted = await identity.keyPair.extract();
  final pkcs8 = p256PrivateKeyPkcs8(
    privateKeyBytes: (extracted as SimpleKeyPairData).bytes,
    publicKeyBytes: identity.publicKeyUncompressed,
  );
  final keyPem = encodePem('PRIVATE KEY', pkcs8);
  ctx.useCertificateChainBytes(utf8.encode(certPem));
  ctx.usePrivateKeyBytes(utf8.encode(keyPem));
  return ctx;
}

void _logHttp(String message) {
  developer.log(message, name: 'http_control');
  debugPrint('[http_control] $message');
}

String _fingerprintHex(List<int> bytes) {
  final digest = sha256.convert(bytes);
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
