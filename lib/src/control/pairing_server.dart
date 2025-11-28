import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' as pc;
import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';

import '../config/build_flags.dart';
import '../domain/models.dart';
import '../identity/device_identity.dart';
import '../identity/pem.dart';
import '../identity/pkcs8.dart';
import '../util/format_utils.dart';
import '../utils/canonical_json.dart';
import 'pairing_messages.dart';

/// Callback when pairing is successfully completed.
typedef PairingCompleteCallback = void Function(TrustedPeer peer);

/// Callback when a new pairing session is created, providing the comparison code.
/// The UI should display this code for the user to verify it matches the listener.
typedef PairingSessionCreatedCallback = void Function(
  String sessionId,
  String deviceName,
  String comparisonCode,
  DateTime expiresAt,
);

/// Callback when a pairing session is rejected by the monitor user.
typedef PairingSessionRejectedCallback = void Function(String sessionId);

/// Callback when a pairing session is confirmed by the monitor user.
typedef PairingSessionConfirmedCallback = void Function(String sessionId);

/// TLS HTTP server for pairing only.
/// Uses server-side TLS (client validates server fingerprint from QR/mDNS).
/// No client certificate required.
/// Binds to both IPv4 and IPv6 addresses.
class PairingServer {
  PairingServer({
    required this.onPairingComplete,
    this.onSessionCreated,
    this.onSessionRejected,
    this.onSessionConfirmed,
  });

  final PairingCompleteCallback onPairingComplete;
  final PairingSessionCreatedCallback? onSessionCreated;
  final PairingSessionRejectedCallback? onSessionRejected;
  final PairingSessionConfirmedCallback? onSessionConfirmed;

  final List<HttpServer> _servers = [];
  int? _boundPort;
  DeviceIdentity? _identity;
  String? _monitorName;
  late DateTime _startedAt;

  /// Active pairing sessions, keyed by session ID.
  final Map<String, _PairingSession> _sessions = {};

  /// One-time pairing token for QR code flow.
  String? _activePairingToken;
  DateTime? _tokenExpiresAt;

  int? get boundPort => _boundPort;
  String? get fingerprint => _identity?.certFingerprint;

  /// Generate a new one-time pairing token for QR code flow.
  /// Invalidates any previous token.
  /// Returns base64url encoded 32-byte token.
  String generatePairingToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    _activePairingToken = base64Url.encode(bytes);
    _tokenExpiresAt = DateTime.now().add(const Duration(minutes: 5));
    _log('Generated new pairing token, expires at $_tokenExpiresAt');
    return _activePairingToken!;
  }

  /// Invalidate the current pairing token.
  void invalidateToken() {
    _activePairingToken = null;
    _tokenExpiresAt = null;
    _log('Pairing token invalidated');
  }

  /// Check if a token is currently valid.
  bool get hasValidToken =>
      _activePairingToken != null &&
      _tokenExpiresAt != null &&
      DateTime.now().isBefore(_tokenExpiresAt!);

  Future<void> start({
    required int port,
    required DeviceIdentity identity,
    required String monitorName,
  }) async {
    await stop();
    _identity = identity;
    _monitorName = monitorName;
    _startedAt = DateTime.now();

    final context = await _buildSecurityContext(identity);

    // Try IPv6 first (dual-stack handles IPv4 on most systems), fall back to IPv4
    final bindAddresses = [
      InternetAddress.anyIPv6,
      InternetAddress.anyIPv4,
    ];

    for (final address in bindAddresses) {
      try {
        _log(
          'Binding pairing server on ${address.address}:$port '
          'fingerprint=${shortFingerprint(identity.certFingerprint)}',
        );

        // TLS with server cert only - no client cert required
        final server = await HttpServer.bindSecure(
          address,
          port,
          context,
          requestClientCertificate: false,
        );
        _servers.add(server);
        _boundPort ??= server.port;

        server.listen(
          _handleRequest,
          onError: (error, stack) {
            _log('Pairing server error (${address.address}): $error');
          },
        );

        _log(
          'Pairing server running on ${address.address}:${server.port} '
          'fingerprint=${shortFingerprint(identity.certFingerprint)}',
        );

        // IPv6 dual-stack succeeded, no need to try IPv4
        break;
      } catch (e) {
        _log('Failed to bind pairing server on ${address.address}:$port: $e');
      }
    }

    if (_servers.isEmpty) {
      throw StateError('Failed to bind pairing server on any address');
    }
  }

  Future<void> stop() async {
    _sessions.clear();
    for (final server in _servers) {
      await server.close(force: true);
    }
    _servers.clear();
    _boundPort = null;
    _identity = null;
    _log('Pairing server stopped');
  }

  /// Monitor user confirms the pairing request.
  /// This must be called before the listener's /pair/confirm request will succeed.
  bool confirmSession(String sessionId) {
    final session = _sessions[sessionId];
    if (session == null) {
      _log('Cannot confirm unknown session=$sessionId');
      return false;
    }
    if (DateTime.now().isAfter(session.expiresAt)) {
      _sessions.remove(sessionId);
      _log('Cannot confirm expired session=$sessionId');
      return false;
    }
    if (session.monitorRejected) {
      _log('Cannot confirm already rejected session=$sessionId');
      return false;
    }
    session.monitorConfirmed = true;
    _log('Monitor confirmed session=$sessionId');
    onSessionConfirmed?.call(sessionId);
    return true;
  }

  /// Monitor user rejects the pairing request.
  bool rejectSession(String sessionId) {
    final session = _sessions[sessionId];
    if (session == null) {
      _log('Cannot reject unknown session=$sessionId');
      return false;
    }
    session.monitorRejected = true;
    _log('Monitor rejected session=$sessionId');
    onSessionRejected?.call(sessionId);
    // Remove the session so listener gets "Session not found" on confirm
    _sessions.remove(sessionId);
    return true;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final remoteIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final remotePort = request.connectionInfo?.remotePort ?? 0;
    _log('Incoming ${request.method} ${request.uri.path} from $remoteIp:$remotePort');

    try {
      switch (request.uri.path) {
        case '/health':
          await _handleHealth(request);
          return;
        case '/pair/init':
          if (request.method == 'POST') {
            await _handlePairInit(request);
            return;
          }
          break;
        case '/pair/confirm':
          if (request.method == 'POST') {
            await _handlePairConfirm(request);
            return;
          }
          break;
        case '/pair/token':
          if (request.method == 'POST') {
            await _handlePairToken(request);
            return;
          }
          break;
      }
      _sendError(request, HttpStatus.notFound, 'not_found', 'Endpoint not found');
    } catch (e, stack) {
      _log('Request handling error: $e\n$stack');
      try {
        _sendError(request, HttpStatus.internalServerError, 'internal_error', 'Internal server error');
      } catch (_) {}
    }
  }

  Future<void> _handleHealth(HttpRequest request) async {
    final body = jsonEncode({
      'status': 'ok',
      'role': 'pairing',
      'protocol': kTransportHttpWs,
      'uptimeSec': DateTime.now().difference(_startedAt).inSeconds,
      'activeSessions': _sessions.length,
      if (_identity != null) 'fingerprint': _identity!.certFingerprint,
    });
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..headers.set('Cache-Control', 'no-store')
      ..write(body);
    await request.response.close();
  }

  Future<void> _handlePairInit(HttpRequest request) async {
    final bodyStr = await utf8.decodeStream(request);
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(bodyStr) as Map<String, dynamic>;
    } catch (e) {
      _sendError(request, HttpStatus.badRequest, 'invalid_json', 'Invalid JSON body');
      return;
    }

    final PairInitRequest initRequest;
    try {
      initRequest = PairInitRequest.fromJson(body);
    } catch (e) {
      _sendError(request, HttpStatus.badRequest, 'invalid_request', 'Invalid request format: $e');
      return;
    }

    _log(
      'Pair init from device=${initRequest.deviceId} '
      'name=${initRequest.deviceName} '
      'fingerprint=${shortFingerprint(initRequest.certFingerprint)}',
    );

    // Parse listener's P-256 identity public key (uncompressed format: 0x04 + x + y)
    final listenerPublicKeyBytes = base64Decode(initRequest.publicKey);
    if (listenerPublicKeyBytes.length != 65 || listenerPublicKeyBytes[0] != 0x04) {
      _sendError(request, HttpStatus.badRequest, 'invalid_key', 'Invalid public key format');
      return;
    }

    // Compute shared secret via P-256 ECDH using pointycastle
    final sharedSecretBytes = await _computeEcdhSharedSecret(
      ourIdentity: _identity!,
      theirPublicKeyUncompressed: listenerPublicKeyBytes,
    );

    // Derive comparison code and pairing key from shared secret
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(sharedSecretBytes),
      info: utf8.encode('cribcall-pairing-v2'),
    );
    final derivedBytes = await derived.extractBytes();

    // First 3 bytes -> 6-digit comparison code (displayed on both devices)
    final comparisonCode = _bytesToComparisonCode(derivedBytes.sublist(0, 3));
    // Remaining bytes -> pairing key for auth tag verification
    final pairingKey = derivedBytes.sublist(3);

    final sessionId = _generateSessionId();
    final expiresAt = DateTime.now().add(const Duration(seconds: 60));

    final session = _PairingSession(
      sessionId: sessionId,
      remoteDeviceId: initRequest.deviceId,
      deviceName: initRequest.deviceName,
      certFingerprint: initRequest.certFingerprint,
      certificateDer: initRequest.certificateDer,
      publicKey: listenerPublicKeyBytes,
      comparisonCode: comparisonCode,
      pairingKey: pairingKey,
      expiresAt: expiresAt,
    );
    _sessions[sessionId] = session;

    _log(
      'Created pairing session=$sessionId comparisonCode=$comparisonCode '
      'for device=${initRequest.deviceId}',
    );

    // Notify UI to display comparison code
    onSessionCreated?.call(
      sessionId,
      initRequest.deviceName,
      comparisonCode,
      expiresAt,
    );

    final response = PairInitResponse(
      pairingSessionId: sessionId,
      monitorPublicKey: base64Encode(_identity!.publicKeyUncompressed),
      expiresInSec: 60,
    );

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(response.toJsonString());
    await request.response.close();
  }

  /// Converts 3 bytes to a 6-digit comparison code.
  String _bytesToComparisonCode(List<int> bytes) {
    // Combine 3 bytes into a 24-bit number, mod 1000000 for 6 digits
    final value = (bytes[0] << 16) | (bytes[1] << 8) | bytes[2];
    return (value % 1000000).toString().padLeft(6, '0');
  }

  Future<void> _handlePairConfirm(HttpRequest request) async {
    final bodyStr = await utf8.decodeStream(request);
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(bodyStr) as Map<String, dynamic>;
    } catch (e) {
      _sendError(request, HttpStatus.badRequest, 'invalid_json', 'Invalid JSON body');
      return;
    }

    final PairConfirmRequest confirmRequest;
    try {
      confirmRequest = PairConfirmRequest.fromJson(body);
    } catch (e) {
      _sendError(request, HttpStatus.badRequest, 'invalid_request', 'Invalid request format: $e');
      return;
    }

    final session = _sessions[confirmRequest.pairingSessionId];
    if (session == null) {
      _log('Pair confirm with unknown session=${confirmRequest.pairingSessionId}');
      _sendConfirmResponse(request, PairConfirmResponse.rejected('Session not found'));
      return;
    }

    if (DateTime.now().isAfter(session.expiresAt)) {
      _sessions.remove(session.sessionId);
      _log('Pair confirm with expired session=${session.sessionId}');
      _sendConfirmResponse(request, PairConfirmResponse.rejected('Session expired'));
      return;
    }

    // Return pending if monitor user hasn't confirmed yet (listener will poll)
    if (!session.monitorConfirmed) {
      _log('Pair confirm pending: monitor has not confirmed session=${session.sessionId}');
      _sendConfirmResponse(request, PairConfirmResponse.pending());
      return;
    }

    // Validate auth tag using pre-computed pairing key
    final valid = await _validateAuthTag(session, confirmRequest);
    if (!valid) {
      _sessions.remove(session.sessionId);
      _log('Pair confirm auth validation failed session=${session.sessionId}');
      _sendConfirmResponse(request, PairConfirmResponse.rejected('Auth validation failed'));
      return;
    }

    // Pairing successful
    _sessions.remove(session.sessionId);
    _log(
      'Pairing successful session=${session.sessionId} '
      'device=${session.remoteDeviceId}',
    );

    final peer = TrustedPeer(
      remoteDeviceId: session.remoteDeviceId,
      name: session.deviceName,
      certFingerprint: session.certFingerprint,
      addedAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      certificateDer: session.certificateDer,
    );

    // Notify callback
    onPairingComplete(peer);

    // Send success response with monitor's certificate
    final response = PairConfirmResponse.accepted(
      remoteDeviceId: _identity!.deviceId,
      monitorName: _monitorName!,
      certFingerprint: _identity!.certFingerprint,
      certificateDer: _identity!.certificateDer,
    );

    _sendConfirmResponse(request, response);
  }

  /// Handle POST /pair/token - QR code token-based pairing.
  /// If the token is valid, pairing completes immediately without user confirmation.
  Future<void> _handlePairToken(HttpRequest request) async {
    final bodyStr = await utf8.decodeStream(request);
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(bodyStr) as Map<String, dynamic>;
    } catch (e) {
      _sendError(request, HttpStatus.badRequest, 'invalid_json', 'Invalid JSON body');
      return;
    }

    final PairTokenRequest tokenRequest;
    try {
      tokenRequest = PairTokenRequest.fromJson(body);
    } catch (e) {
      _sendError(request, HttpStatus.badRequest, 'invalid_request', 'Invalid request format: $e');
      return;
    }

    _log(
      'Pair token from device=${tokenRequest.deviceId} '
      'name=${tokenRequest.deviceName} '
      'fingerprint=${shortFingerprint(tokenRequest.certFingerprint)}',
    );

    // Validate token
    if (_activePairingToken == null || _tokenExpiresAt == null) {
      _log('Pair token rejected: no active token');
      _sendTokenResponse(request, PairTokenResponse.rejected('No active pairing token'));
      return;
    }

    if (DateTime.now().isAfter(_tokenExpiresAt!)) {
      _activePairingToken = null;
      _tokenExpiresAt = null;
      _log('Pair token rejected: token expired');
      _sendTokenResponse(request, PairTokenResponse.rejected('Pairing token expired'));
      return;
    }

    if (tokenRequest.pairingToken != _activePairingToken) {
      _log('Pair token rejected: invalid token');
      _sendTokenResponse(request, PairTokenResponse.rejected('Invalid pairing token'));
      return;
    }

    // Token valid - immediately invalidate (single use)
    _activePairingToken = null;
    _tokenExpiresAt = null;

    // Pairing successful
    _log(
      'Token pairing successful device=${tokenRequest.deviceId} '
      'name=${tokenRequest.deviceName}',
    );

    final peer = TrustedPeer(
      remoteDeviceId: tokenRequest.deviceId,
      name: tokenRequest.deviceName,
      certFingerprint: tokenRequest.certFingerprint,
      addedAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      certificateDer: tokenRequest.certificateDer,
    );

    // Notify callback
    onPairingComplete(peer);

    // Send success response with monitor's certificate
    final response = PairTokenResponse.accepted(
      remoteDeviceId: _identity!.deviceId,
      monitorName: _monitorName!,
      certFingerprint: _identity!.certFingerprint,
      certificateDer: _identity!.certificateDer,
    );

    _sendTokenResponse(request, response);
  }

  void _sendTokenResponse(HttpRequest request, PairTokenResponse response) {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(response.toJsonString());
    request.response.close();
  }

  Future<bool> _validateAuthTag(
    _PairingSession session,
    PairConfirmRequest confirmRequest,
  ) async {
    try {
      // Compute expected auth tag using pre-computed pairing key
      final canonicalTranscript = canonicalizeJson(confirmRequest.transcript);
      final hmacAlgo = Hmac.sha256();
      final mac = await hmacAlgo.calculateMac(
        utf8.encode(canonicalTranscript),
        secretKey: SecretKey(session.pairingKey),
      );
      final expectedAuthTag = base64Encode(mac.bytes);

      // Compare auth tags
      final valid = expectedAuthTag == confirmRequest.authTag;
      _log(
        'Auth validation: expected=${shortFingerprint(expectedAuthTag)} '
        'got=${shortFingerprint(confirmRequest.authTag)} valid=$valid',
      );
      return valid;
    } catch (e) {
      _log('Auth validation error: $e');
      return false;
    }
  }

  void _sendConfirmResponse(HttpRequest request, PairConfirmResponse response) {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(response.toJsonString());
    request.response.close();
  }

  void _sendError(HttpRequest request, int status, String code, String message) {
    final error = PairErrorResponse(error: message, code: code);
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(error.toJsonString());
    request.response.close();
  }

  String _generateSessionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

class _PairingSession {
  _PairingSession({
    required this.sessionId,
    required this.remoteDeviceId,
    required this.deviceName,
    required this.certFingerprint,
    required this.certificateDer,
    required this.publicKey,
    required this.comparisonCode,
    required this.pairingKey,
    required this.expiresAt,
  });

  final String sessionId;
  final String remoteDeviceId;
  final String deviceName;
  final String certFingerprint;
  final List<int> certificateDer;
  final List<int> publicKey;
  /// 6-digit comparison code displayed on both devices
  final String comparisonCode;
  /// Derived key for auth tag verification
  final List<int> pairingKey;
  final DateTime expiresAt;

  /// Whether the monitor user has confirmed this pairing request.
  bool monitorConfirmed = false;

  /// Whether the monitor user has rejected this pairing request.
  bool monitorRejected = false;
}

Future<SecurityContext> _buildSecurityContext(DeviceIdentity identity) async {
  final ctx = SecurityContext(withTrustedRoots: false);
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

void _log(String message) {
  developer.log(message, name: 'pairing_server');
  debugPrint('[pairing_server] $message');
}

/// Computes ECDH shared secret using P-256 curve via pointycastle.
Future<List<int>> _computeEcdhSharedSecret({
  required DeviceIdentity ourIdentity,
  required List<int> theirPublicKeyUncompressed,
}) async {
  final domainParams = pc.ECDomainParameters('secp256r1');

  // Parse their public key (uncompressed: 0x04 + x + y)
  final theirPoint = domainParams.curve.decodePoint(
    Uint8List.fromList(theirPublicKeyUncompressed),
  );
  final theirPublicKey = pc.ECPublicKey(theirPoint, domainParams);

  // Extract our private key
  final privateKeyData = await ourIdentity.keyPair.extract();
  final dBytes = (privateKeyData as SimpleKeyPairData).bytes;
  final d = _bytesToBigInt(dBytes);
  final ourPrivateKey = pc.ECPrivateKey(d, domainParams);

  // Compute shared secret
  final agreement = pc.ECDHBasicAgreement();
  agreement.init(ourPrivateKey);
  final sharedSecretBigInt = agreement.calculateAgreement(theirPublicKey);

  // Convert to 32 bytes (P-256 field size)
  return _bigIntToBytes(sharedSecretBigInt, 32);
}

/// Converts bytes to BigInt (big-endian unsigned).
BigInt _bytesToBigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

/// Converts BigInt to fixed-length bytes (big-endian unsigned).
List<int> _bigIntToBytes(BigInt value, int length) {
  final bytes = <int>[];
  var v = value;
  while (v > BigInt.zero) {
    bytes.insert(0, (v & BigInt.from(0xff)).toInt());
    v = v >> 8;
  }
  // Pad to required length
  while (bytes.length < length) {
    bytes.insert(0, 0);
  }
  return bytes;
}
