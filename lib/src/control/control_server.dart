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
import '../util/format_utils.dart';
import '../utils/canonical_json.dart';
import 'control_connection.dart';

typedef UnpairRequestHandler =
    Future<bool> Function(String fingerprint, String? deviceId);
typedef NoiseSubscribeResult = ({
  String deviceId,
  String subscriptionId,
  DateTime expiresAt,
  int acceptedLeaseSeconds,
});
typedef NoiseUnsubscribeResult = ({
  String deviceId,
  String? subscriptionId,
  DateTime? expiresAt,
  bool removed,
});
typedef NoiseSubscribeHandler =
    Future<NoiseSubscribeResult> Function({
      required String fingerprint,
      required String fcmToken,
      required String platform,
      required int? leaseSeconds,
      required String remoteAddress,
      int? threshold,
      int? cooldownSeconds,
      AutoStreamType? autoStreamType,
      int? autoStreamDurationSec,
    });
typedef NoiseUnsubscribeHandler =
    Future<NoiseUnsubscribeResult> Function({
      required String fingerprint,
      String? fcmToken,
      String? subscriptionId,
      required String remoteAddress,
    });

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
  ControlServer({
    this.bindAddress,
    this.onUnpairRequest,
    this.onNoiseSubscribe,
    this.onNoiseUnsubscribe,
  });

  /// Optional specific bind address. If null, tries IPv6 first, then IPv4.
  final String? bindAddress;
  final UnpairRequestHandler? onUnpairRequest;
  final NoiseSubscribeHandler? onNoiseSubscribe;
  final NoiseUnsubscribeHandler? onNoiseUnsubscribe;

  HttpServer? _server;
  int? _boundPort;
  String? _boundAddress;
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

    // If explicit bindAddress provided, use only that; otherwise try IPv6 first
    final bindAddresses = bindAddress != null
        ? [bindAddress!]
        : [InternetAddress.anyIPv6.address, InternetAddress.anyIPv4.address];

    for (final address in bindAddresses) {
      try {
        _log(
          'Binding control server on $address:$port '
          'fingerprint=${shortFingerprint(identity.certFingerprint)} '
          'trustedPeers=${_trustedFingerprints.length}',
        );

        _server = await HttpServer.bindSecure(
          address,
          port,
          context,
          requestClientCertificate: true,
          shared: true, // Allow rebind for hot reload
        );
        _boundPort = _server!.port;
        _boundAddress = address;

        _server!.listen(
          _handleRequest,
          onError: (error, stack) {
            _log('Control server error: $error');
          },
        );

        _log(
          'Control server running on $address:${_server!.port} '
          'mTLS enabled, trustedPeers=${_trustedFingerprints.length}',
        );

        // Bind succeeded, no need to try fallback
        break;
      } catch (e) {
        _log('Failed to bind control server on $address:$port: $e');
      }
    }

    if (_server == null) {
      throw StateError('Failed to bind control server on any address');
    }
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
    _boundAddress = null;
    _log('Control server stopped');
  }

  /// Add a trusted peer dynamically.
  /// Triggers graceful server rebind to update TLS trust store.
  Future<void> addTrustedPeer(TrustedPeer peer) async {
    if (_trustedFingerprints.contains(peer.certFingerprint)) {
      _log('Peer already trusted: ${shortFingerprint(peer.certFingerprint)}');
      return;
    }

    _trustedFingerprints.add(peer.certFingerprint);
    if (peer.certificateDer != null) {
      _trustedCertificates.add(peer.certificateDer!);
    }
    _log(
      'Added trusted peer ${shortFingerprint(peer.certFingerprint)}, '
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
      'Removed trusted peer ${shortFingerprint(fingerprint)}, '
      'total=${_trustedFingerprints.length}',
    );

    // Close any existing connections from this peer
    for (final conn in List.of(_connections)) {
      if (conn.peerFingerprint == fingerprint) {
        _log(
          'Closing connection from removed peer ${shortFingerprint(fingerprint)}',
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
        case '/noise/subscribe':
          if (request.method == 'POST') {
            await _handleNoiseSubscribe(request);
            return;
          }
          break;
        case '/noise/unsubscribe':
          if (request.method == 'POST') {
            await _handleNoiseUnsubscribe(request);
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
        'clientFp=${shortFingerprint(clientFp)} trusted=$trusted',
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
      _log('Test rejected: untrusted certificate ${shortFingerprint(fp)}');
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

    _log('Test accepted: ${shortFingerprint(fp)}');
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
      _log('Unpair rejected: untrusted certificate ${shortFingerprint(fp)}');
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

    String? deviceId;
    try {
      final bodyStr = await utf8.decodeStream(request);
      if (bodyStr.trim().isNotEmpty) {
        final payload = jsonDecode(bodyStr);
        if (payload is Map && payload['deviceId'] is String) {
          deviceId = payload['deviceId'] as String;
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
            'message': 'Body must be JSON with optional deviceId',
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

    final unpaired = await handler(fp, deviceId);
    _log(
      'Unpair request from ${request.connectionInfo?.remoteAddress.address} '
      'clientFp=${shortFingerprint(fp)} deviceId=$deviceId '
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
          if (deviceId != null) 'deviceId': deviceId,
          if (!unpaired) 'reason': 'device_not_found',
        }),
      );
    await request.response.close();
  }

  Future<void> _handleNoiseSubscribe(HttpRequest request) async {
    if (onNoiseSubscribe == null) {
      _writeCanonicalJson(request.response, HttpStatus.serviceUnavailable, {
        'error': 'noise_subscribe_not_supported',
        'message': 'Noise subscribe handler not configured on server',
      });
      return;
    }

    final remote = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final clientCert = request.certificate;
    if (clientCert == null) {
      _log('Noise subscribe rejected: no client certificate');
      _writeCanonicalJson(request.response, HttpStatus.unauthorized, {
        'error': 'unauthenticated',
        'message': 'Client certificate required',
      });
      return;
    }

    final fp = _fingerprintHex(clientCert.der);
    if (!_trustedFingerprints.contains(fp)) {
      _log(
        'Noise subscribe rejected: untrusted fingerprint '
        'fp=${shortFingerprint(fp)} remote=$remote',
      );
      _writeCanonicalJson(request.response, HttpStatus.forbidden, {
        'error': 'untrusted',
        'message': 'Certificate not trusted',
      });
      return;
    }

    Map<String, dynamic> body;
    try {
      body = await _decodeJsonBody(request);
    } catch (e) {
      _writeCanonicalJson(request.response, HttpStatus.badRequest, {
        'error': 'invalid_json',
        'message': '$e',
      });
      return;
    }

    final allowedKeys = {
      'fcmToken',
      'platform',
      'leaseSeconds',
      'deviceId',
      'pairingId',
      'subscriptionId',
      'threshold',
      'cooldownSeconds',
      'autoStreamType',
      'autoStreamDurationSec',
    };
    final unknown = body.keys.where((k) => !allowedKeys.contains(k)).toList();
    if (unknown.isNotEmpty) {
      _writeCanonicalJson(request.response, HttpStatus.badRequest, {
        'error': 'unknown_fields',
        'fields': unknown,
      });
      return;
    }

    if (body.containsKey('deviceId') || body.containsKey('pairingId')) {
      _writeCanonicalJson(request.response, HttpStatus.badRequest, {
        'error': 'device_id_forbidden',
        'message': 'Server derives deviceId from certificate',
      });
      return;
    }

    final fcmToken = body['fcmToken'];
    final platform = body['platform'];
    final leaseSeconds = body['leaseSeconds'];
    final threshold = body['threshold'];
    final cooldownSeconds = body['cooldownSeconds'];
    final autoStreamTypeName = body['autoStreamType'];
    final autoStreamDurationSec = body['autoStreamDurationSec'];

    if (fcmToken is! String || fcmToken.isEmpty) {
      _writeCanonicalJson(request.response, HttpStatus.badRequest, {
        'error': 'invalid_fcm_token',
        'message': 'fcmToken is required',
      });
      return;
    }

    if (platform is! String || platform.isEmpty) {
      _writeCanonicalJson(request.response, HttpStatus.badRequest, {
        'error': 'invalid_platform',
        'message': 'platform is required',
      });
      return;
    }

    if (leaseSeconds != null && leaseSeconds is! int) {
      _writeCanonicalJson(request.response, HttpStatus.badRequest, {
        'error': 'invalid_lease',
        'message': 'leaseSeconds must be an integer if provided',
      });
      return;
    }

    if (threshold != null && threshold is! int) {
      _writeCanonicalJson(request.response, HttpStatus.badRequest, {
        'error': 'invalid_threshold',
        'message': 'threshold must be an integer if provided',
      });
      return;
    }

    if (cooldownSeconds != null && cooldownSeconds is! int) {
      _writeCanonicalJson(request.response, HttpStatus.badRequest, {
        'error': 'invalid_cooldown',
        'message': 'cooldownSeconds must be an integer if provided',
      });
      return;
    }

    if (autoStreamDurationSec != null && autoStreamDurationSec is! int) {
      _writeCanonicalJson(request.response, HttpStatus.badRequest, {
        'error': 'invalid_auto_stream_duration',
        'message': 'autoStreamDurationSec must be an integer if provided',
      });
      return;
    }

    AutoStreamType? autoStreamType;
    if (autoStreamTypeName != null) {
      if (autoStreamTypeName is! String) {
        _writeCanonicalJson(request.response, HttpStatus.badRequest, {
          'error': 'invalid_auto_stream_type',
          'message': 'autoStreamType must be a string if provided',
        });
        return;
      }
      try {
        autoStreamType = AutoStreamType.values.byName(autoStreamTypeName);
      } catch (_) {
        _writeCanonicalJson(request.response, HttpStatus.badRequest, {
          'error': 'invalid_auto_stream_type',
          'message': 'autoStreamType must be one of: none, audio, audioVideo',
        });
        return;
      }
    }

    try {
      final result = await onNoiseSubscribe!(
        fingerprint: fp,
        fcmToken: fcmToken,
        platform: platform,
        leaseSeconds: leaseSeconds as int?,
        remoteAddress: remote,
        threshold: threshold as int?,
        cooldownSeconds: cooldownSeconds as int?,
        autoStreamType: autoStreamType,
        autoStreamDurationSec: autoStreamDurationSec as int?,
      );

      _writeCanonicalJson(request.response, HttpStatus.ok, {
        'subscriptionId': result.subscriptionId,
        'deviceId': result.deviceId,
        'expiresAt': result.expiresAt.toUtc().toIso8601String(),
        'acceptedLeaseSeconds': result.acceptedLeaseSeconds,
      });
    } catch (e) {
      _log('Noise subscribe error: $e');
      _writeCanonicalJson(request.response, HttpStatus.internalServerError, {
        'error': 'internal_error',
        'message': '$e',
      });
    }
  }

  Future<void> _handleNoiseUnsubscribe(HttpRequest request) async {
    if (onNoiseUnsubscribe == null) {
      _writeCanonicalJson(request.response, HttpStatus.serviceUnavailable, {
        'error': 'noise_unsubscribe_not_supported',
        'message': 'Noise unsubscribe handler not configured on server',
      });
      return;
    }

    final remote = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final clientCert = request.certificate;
    if (clientCert == null) {
      _log('Noise unsubscribe rejected: no client certificate');
      _writeCanonicalJson(request.response, HttpStatus.unauthorized, {
        'error': 'unauthenticated',
        'message': 'Client certificate required',
      });
      return;
    }

    final fp = _fingerprintHex(clientCert.der);
    if (!_trustedFingerprints.contains(fp)) {
      _log(
        'Noise unsubscribe rejected: untrusted fingerprint '
        'fp=${shortFingerprint(fp)} remote=$remote',
      );
      _writeCanonicalJson(request.response, HttpStatus.forbidden, {
        'error': 'untrusted',
        'message': 'Certificate not trusted',
      });
      return;
    }

    Map<String, dynamic> body;
    try {
      body = await _decodeJsonBody(request);
    } catch (e) {
      _writeCanonicalJson(request.response, HttpStatus.badRequest, {
        'error': 'invalid_json',
        'message': '$e',
      });
      return;
    }

    final allowedKeys = {'fcmToken', 'subscriptionId', 'deviceId', 'pairingId'};
    final unknown = body.keys.where((k) => !allowedKeys.contains(k)).toList();
    if (unknown.isNotEmpty) {
      _writeCanonicalJson(request.response, HttpStatus.badRequest, {
        'error': 'unknown_fields',
        'fields': unknown,
      });
      return;
    }

    if (body.containsKey('deviceId') || body.containsKey('pairingId')) {
      _writeCanonicalJson(request.response, HttpStatus.badRequest, {
        'error': 'device_id_forbidden',
        'message': 'Server derives deviceId from certificate',
      });
      return;
    }

    final fcmToken = body['fcmToken'];
    final subscriptionId = body['subscriptionId'];
    if ((fcmToken == null || fcmToken is String) &&
        (subscriptionId == null || subscriptionId is String)) {
      if (fcmToken == null && subscriptionId == null) {
        _writeCanonicalJson(request.response, HttpStatus.badRequest, {
          'error': 'missing_identifier',
          'message': 'fcmToken or subscriptionId required',
        });
        return;
      }
    } else {
      _writeCanonicalJson(request.response, HttpStatus.badRequest, {
        'error': 'invalid_identifier',
        'message': 'fcmToken/subscriptionId must be strings if provided',
      });
      return;
    }

    try {
      final result = await onNoiseUnsubscribe!(
        fingerprint: fp,
        fcmToken: fcmToken as String?,
        subscriptionId: subscriptionId as String?,
        remoteAddress: remote,
      );

      _writeCanonicalJson(request.response, HttpStatus.ok, {
        'deviceId': result.deviceId,
        'unsubscribed': result.removed,
        if (result.subscriptionId != null)
          'subscriptionId': result.subscriptionId,
        if (result.expiresAt != null)
          'expiresAt': result.expiresAt!.toUtc().toIso8601String(),
      });
    } catch (e) {
      _log('Noise unsubscribe error: $e');
      _writeCanonicalJson(request.response, HttpStatus.internalServerError, {
        'error': 'internal_error',
        'message': '$e',
      });
    }
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
        'untrusted certificate ${shortFingerprint(fp)}',
      );
      request.response
        ..statusCode = HttpStatus.forbidden
        ..write('certificate not trusted');
      await request.response.close();
      return;
    }

    _log(
      'WebSocket accepted from $remoteIp:$remotePort '
      'clientFp=${shortFingerprint(fp)}',
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

Future<Map<String, dynamic>> _decodeJsonBody(HttpRequest request) async {
  final body = await utf8.decodeStream(request);
  final data = jsonDecode(body);
  if (data is! Map) throw const FormatException('Expected JSON object');
  return data.cast<String, dynamic>();
}

void _writeCanonicalJson(
  HttpResponse response,
  int statusCode,
  Map<String, dynamic> body,
) {
  response
    ..statusCode = statusCode
    ..headers.contentType = ContentType.json
    ..headers.set('Cache-Control', 'no-store')
    ..write(canonicalizeJson(body))
    ..close();
}
