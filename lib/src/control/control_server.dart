import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';

import '../config/build_flags.dart';
import '../domain/models.dart';
import '../identity/device_identity.dart';
import '../identity/pem.dart';
import '../identity/pkcs8.dart';
import 'control_connection.dart';

typedef UnpairRequestHandler =
    Future<bool> Function(String fingerprint, String? listenerId);

// -----------------------------------------------------------------------------
// Server Events
// -----------------------------------------------------------------------------

sealed class ControlServerEvent {}

class ClientConnected extends ControlServerEvent {
  ClientConnected({required this.connection});
  final ControlConnection connection;
}

class ClientDisconnected extends ControlServerEvent {
  ClientDisconnected({required this.connectionId, this.reason});
  final String connectionId;
  final String? reason;
}

// -----------------------------------------------------------------------------
// Control Server (mTLS WebSocket)
// -----------------------------------------------------------------------------

/// mTLS WebSocket server for control messages.
/// Requires valid client certificate from trusted peer.
class ControlServer {
  ControlServer({this.bindAddress = '0.0.0.0', this.onUnpairRequest});

  final String bindAddress;
  final UnpairRequestHandler? onUnpairRequest;

  HttpServer? _server;
  int? _boundPort;
  DeviceIdentity? _identity;
  late DateTime _startedAt;

  final Set<String> _trustedFingerprints = {};
  final List<List<int>> _trustedCertificates = [];
  final Set<ControlConnection> _connections = {};
  final _eventsController = StreamController<ControlServerEvent>.broadcast();

  int? get boundPort => _boundPort;
  String? get fingerprint => _identity?.certFingerprint;
  int get connectionCount => _connections.length;
  Stream<ControlServerEvent> get events => _eventsController.stream;

  /// Start the control server.
  Future<void> start({
    required int port,
    required DeviceIdentity identity,
    required List<TrustedPeer> trustedPeers,
  }) async {
    await stop();
    _identity = identity;
    _startedAt = DateTime.now();

    // Initialize trusted peers
    _trustedFingerprints.clear();
    _trustedCertificates.clear();

    for (final peer in trustedPeers) {
      _trustedFingerprints.add(peer.certFingerprint);
      if (peer.certificateDer != null) {
        _trustedCertificates.add(peer.certificateDer!);
      }
    }

    // Also trust our own certificate (for same-device testing)
    _trustedFingerprints.add(identity.certFingerprint);
    _trustedCertificates.add(identity.certificateDer);

    await _bindServer(port, identity);
  }

  Future<void> _bindServer(int port, DeviceIdentity identity) async {
    final context = await _buildSecurityContext(identity);

    _log(
      'Binding control server on $bindAddress:$port '
      'fingerprint=${_shortFingerprint(identity.certFingerprint)} '
      'trustedPeers=${_trustedFingerprints.length}',
    );

    _server = await HttpServer.bindSecure(
      bindAddress,
      port,
      context,
      requestClientCertificate: true,
      shared: true, // Allow rebind for hot reload
    );
    _boundPort = _server!.port;

    _server!.listen(
      _handleRequest,
      onError: (error, stack) {
        _log('Control server error: $error');
      },
    );

    _log(
      'Control server running on $bindAddress:${_server!.port} '
      'mTLS enabled, trustedPeers=${_trustedFingerprints.length}',
    );
  }

  Future<void> stop() async {
    _log('Stopping control server, connections=${_connections.length}');
    for (final conn in List.of(_connections)) {
      await conn.close();
    }
    _connections.clear();
    await _server?.close(force: true);
    _server = null;
    _boundPort = null;
    _log('Control server stopped');
  }

  /// Add a trusted peer dynamically.
  /// Triggers graceful server rebind to update TLS trust store.
  Future<void> addTrustedPeer(TrustedPeer peer) async {
    if (_trustedFingerprints.contains(peer.certFingerprint)) {
      _log('Peer already trusted: ${_shortFingerprint(peer.certFingerprint)}');
      return;
    }

    _trustedFingerprints.add(peer.certFingerprint);
    if (peer.certificateDer != null) {
      _trustedCertificates.add(peer.certificateDer!);
    }
    _log(
      'Added trusted peer ${_shortFingerprint(peer.certFingerprint)}, '
      'total=${_trustedFingerprints.length}',
    );

    // Graceful rebind to update TLS context
    await _rebindWithUpdatedCertificates();
  }

  /// Remove a trusted peer.
  Future<void> removeTrustedPeer(String fingerprint) async {
    if (!_trustedFingerprints.contains(fingerprint)) return;

    _trustedFingerprints.remove(fingerprint);
    _trustedCertificates.removeWhere(
      (cert) => _fingerprintHex(cert) == fingerprint,
    );
    _log(
      'Removed trusted peer ${_shortFingerprint(fingerprint)}, '
      'total=${_trustedFingerprints.length}',
    );

    // Close any existing connections from this peer
    for (final conn in List.of(_connections)) {
      if (conn.peerFingerprint == fingerprint) {
        _log(
          'Closing connection from removed peer ${_shortFingerprint(fingerprint)}',
        );
        await conn.close();
      }
    }

    await _rebindWithUpdatedCertificates();
  }

  Future<void> _rebindWithUpdatedCertificates() async {
    if (_identity == null || _boundPort == null) return;

    final port = _boundPort!;
    final identity = _identity!;

    _log('Rebinding control server with updated certificates');

    // Close old server (existing WebSocket connections stay open)
    final oldServer = _server;
    _server = null;

    // Bind new server with updated TLS context
    await _bindServer(port, identity);

    // Close old server after new one is ready
    await oldServer?.close();

    _log('Control server rebind complete');
  }

  Future<SecurityContext> _buildSecurityContext(DeviceIdentity identity) async {
    final ctx = SecurityContext(withTrustedRoots: false);

    // Server certificate and key
    final certPem = encodePem('CERTIFICATE', identity.certificateDer);
    final extracted = await identity.keyPair.extract();
    final pkcs8 = p256PrivateKeyPkcs8(
      privateKeyBytes: (extracted as SimpleKeyPairData).bytes,
      publicKeyBytes: identity.publicKeyUncompressed,
    );
    final keyPem = encodePem('PRIVATE KEY', pkcs8);
    ctx.useCertificateChainBytes(utf8.encode(certPem));
    ctx.usePrivateKeyBytes(utf8.encode(keyPem));

    // Add trusted client certificates
    for (final certDer in _trustedCertificates) {
      final clientCertPem = encodePem('CERTIFICATE', certDer);
      ctx.setTrustedCertificatesBytes(utf8.encode(clientCertPem));
    }

    return ctx;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final remoteIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final remotePort = request.connectionInfo?.remotePort ?? 0;
    _log(
      'Incoming ${request.method} ${request.uri.path} from $remoteIp:$remotePort',
    );

    try {
      switch (request.uri.path) {
        case '/health':
          await _handleHealth(request);
          return;
        case '/test':
          await _handleTest(request);
          return;
        case '/unpair':
          if (request.method == 'POST') {
            await _handleUnpair(request);
            return;
          }
          break;
        case '/control/ws':
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            await _handleWebSocket(request);
            return;
          }
          break;
      }
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('not found')
        ..close();
    } catch (e, stack) {
      _log('Request handling error: $e\n$stack');
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('internal error')
          ..close();
      } catch (_) {}
    }
  }

  Future<void> _handleHealth(HttpRequest request) async {
    final clientCert = request.certificate;
    String? clientFp;
    bool trusted = false;

    if (clientCert != null) {
      clientFp = _fingerprintHex(clientCert.der);
      trusted = _trustedFingerprints.contains(clientFp);
      _log(
        'Health from ${request.connectionInfo?.remoteAddress.address} '
        'clientFp=${_shortFingerprint(clientFp)} trusted=$trusted',
      );
    } else {
      _log(
        'Health from ${request.connectionInfo?.remoteAddress.address} (no client cert)',
      );
    }

    final body = jsonEncode({
      'status': 'ok',
      'role': 'monitor',
      'protocol': kTransportHttpWs,
      'uptimeSec': DateTime.now().difference(_startedAt).inSeconds,
      'activeConnections': _connections.length,
      'mTLS': clientCert != null,
      'trusted': trusted,
      if (_identity != null) 'fingerprint': _identity!.certFingerprint,
      if (clientFp != null) 'clientFingerprint': clientFp,
    });

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..headers.set('Cache-Control', 'no-store')
      ..write(body);
    await request.response.close();
  }

  Future<void> _handleTest(HttpRequest request) async {
    final clientCert = request.certificate;
    if (clientCert == null) {
      _log('Test rejected: no client certificate');
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'error': 'client_certificate_required',
            'message': 'This endpoint requires mTLS authentication',
          }),
        );
      await request.response.close();
      return;
    }

    final fp = _fingerprintHex(clientCert.der);
    final trusted = _trustedFingerprints.contains(fp);
    if (!trusted) {
      _log('Test rejected: untrusted certificate ${_shortFingerprint(fp)}');
      request.response
        ..statusCode = HttpStatus.forbidden
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'error': 'certificate_not_trusted',
            'message': 'Client certificate not in trusted list',
            'fingerprint': fp,
          }),
        );
      await request.response.close();
      return;
    }

    _log('Test accepted: ${_shortFingerprint(fp)}');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({
          'status': 'ok',
          'message': 'mTLS authentication successful',
          'clientSubject': clientCert.subject,
          'clientFingerprint': fp,
          'trusted': true,
        }),
      );
    await request.response.close();
  }

  Future<void> _handleUnpair(HttpRequest request) async {
    final clientCert = request.certificate;
    if (clientCert == null) {
      _log('Unpair rejected: no client certificate');
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'error': 'client_certificate_required',
            'message': 'This endpoint requires mTLS authentication',
          }),
        );
      await request.response.close();
      return;
    }

    final fp = _fingerprintHex(clientCert.der);
    final trusted = _trustedFingerprints.contains(fp);
    if (!trusted) {
      _log('Unpair rejected: untrusted certificate ${_shortFingerprint(fp)}');
      request.response
        ..statusCode = HttpStatus.forbidden
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'error': 'certificate_not_trusted',
            'message': 'Client certificate not in trusted list',
            'fingerprint': fp,
          }),
        );
      await request.response.close();
      return;
    }

    String? listenerId;
    try {
      final bodyStr = await utf8.decodeStream(request);
      if (bodyStr.trim().isNotEmpty) {
        final payload = jsonDecode(bodyStr);
        if (payload is Map && payload['listenerId'] is String) {
          listenerId = payload['listenerId'] as String;
        }
      }
    } catch (e) {
      _log('Unpair rejected: invalid body ($e)');
      request.response
        ..statusCode = HttpStatus.badRequest
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'error': 'invalid_body',
            'message': 'Body must be JSON with optional listenerId',
          }),
        );
      await request.response.close();
      return;
    }

    final handler = onUnpairRequest;
    if (handler == null) {
      _log('Unpair handler not configured');
      request.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'error': 'unpair_not_supported',
            'message': 'Unpair handler not configured on server',
          }),
        );
      await request.response.close();
      return;
    }

    final unpaired = await handler(fp, listenerId);
    _log(
      'Unpair request from ${request.connectionInfo?.remoteAddress.address} '
      'clientFp=${_shortFingerprint(fp)} listenerId=$listenerId '
      'unpaired=$unpaired',
    );

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..headers.set('Cache-Control', 'no-store')
      ..write(
        jsonEncode({
          'status': 'ok',
          'unpaired': unpaired,
          if (listenerId != null) 'listenerId': listenerId,
          if (!unpaired) 'reason': 'listener_not_found',
        }),
      );
    await request.response.close();
  }

  Future<void> _handleWebSocket(HttpRequest request) async {
    final remoteIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final remotePort = request.connectionInfo?.remotePort ?? 0;

    final clientCert = request.certificate;
    if (clientCert == null) {
      _log(
        'WebSocket rejected from $remoteIp:$remotePort: no client certificate',
      );
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..write('client certificate required');
      await request.response.close();
      return;
    }

    final fp = _fingerprintHex(clientCert.der);
    final trusted = _trustedFingerprints.contains(fp);
    if (!trusted) {
      _log(
        'WebSocket rejected from $remoteIp:$remotePort: '
        'untrusted certificate ${_shortFingerprint(fp)}',
      );
      request.response
        ..statusCode = HttpStatus.forbidden
        ..write('certificate not trusted');
      await request.response.close();
      return;
    }

    _log(
      'WebSocket accepted from $remoteIp:$remotePort '
      'clientFp=${_shortFingerprint(fp)}',
    );

    final socket = await WebSocketTransformer.upgrade(request);
    final connectionId = 'ws-${DateTime.now().microsecondsSinceEpoch}';

    final connection = ControlConnection(
      socket: socket,
      peerFingerprint: fp,
      connectionId: connectionId,
      remoteHost: remoteIp,
      remotePort: remotePort,
    );

    _connections.add(connection);
    _eventsController.add(ClientConnected(connection: connection));

    // Listen for connection close
    connection.messages.listen(
      null,
      onError: (e) {
        _log('Connection error on $connectionId: $e');
      },
      onDone: () {
        _connections.remove(connection);
        _eventsController.add(
          ClientDisconnected(connectionId: connectionId, reason: null),
        );
        _log('Connection closed: $connectionId');
      },
    );
  }
}

void _log(String message) {
  developer.log(message, name: 'control_server');
  debugPrint('[control_server] $message');
}

String _fingerprintHex(List<int> bytes) {
  final digest = sha256.convert(bytes);
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _shortFingerprint(String fingerprint) {
  if (fingerprint.length <= 12) return fingerprint;
  return '${fingerprint.substring(0, 6)}...${fingerprint.substring(fingerprint.length - 4)}';
}
