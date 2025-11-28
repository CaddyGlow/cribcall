import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' as pc;
import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';

import '../identity/device_identity.dart';
import '../identity/pem.dart';
import '../identity/pkcs8.dart';
import 'pairing_messages.dart';

/// Result of initPairing containing the session info and derived comparison code.
class PairInitResult {
  PairInitResult({
    required this.sessionId,
    required this.comparisonCode,
    required this.pairingKey,
    required this.expiresAt,
  });

  final String sessionId;
  /// 6-digit comparison code to display on both devices
  final String comparisonCode;
  /// Derived key for auth tag computation
  final List<int> pairingKey;
  final DateTime expiresAt;
}

/// HTTP RPC client for pairing protocol.
/// Connects to PairingServer endpoints without WebSocket.
///
/// Protocol v2: Uses numeric comparison instead of PIN entry.
/// Both devices derive the same comparison code from ECDH shared secret.
class PairingClient {
  PairingClient();

  HttpClient? _client;
  String? _lastSeenFingerprint;

  /// The fingerprint of the server certificate from the last request.
  String? get lastSeenFingerprint => _lastSeenFingerprint;

  /// Initializes pairing by calling POST /pair/init.
  ///
  /// Returns a [PairInitResult] containing:
  /// - sessionId: for the confirm step
  /// - comparisonCode: 6-digit code to display on both devices
  /// - pairingKey: derived key for auth tag computation
  /// - expiresAt: when the session expires
  Future<PairInitResult> initPairing({
    required String host,
    required int port,
    required String expectedFingerprint,
    required DeviceIdentity listenerIdentity,
    required String listenerName,
    bool allowUnpinned = false,
  }) async {
    _log(
      'Initiating pairing to $host:$port '
      'expectedFp=${_shortFingerprint(expectedFingerprint)} '
      'allowUnpinned=$allowUnpinned',
    );

    final client = await _httpClient(
      expectedFingerprint,
      listenerIdentity,
      allowUnpinned: allowUnpinned,
    );
    _client = client;

    final uri = Uri(
      scheme: 'https',
      host: host,
      port: port,
      path: '/pair/init',
    );

    final requestBody = PairInitRequest(
      deviceId: listenerIdentity.deviceId,
      deviceName: listenerName,
      certFingerprint: listenerIdentity.certFingerprint,
      certificateDer: listenerIdentity.certificateDer,
      publicKey: base64Encode(listenerIdentity.publicKeyUncompressed),
    );

    _log('POST $uri');
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.write(requestBody.toJsonString());
    final response = await request.close();

    // Validate server certificate
    final cert = response.certificate;
    if (cert != null) {
      final fp = _fingerprintHex(cert.der);
      _lastSeenFingerprint = fp;
      _log('Server cert fingerprint=${_shortFingerprint(fp)}');
    }

    if (response.statusCode != HttpStatus.ok) {
      final body = await utf8.decodeStream(response);
      _log('Pair init failed: ${response.statusCode} $body');
      throw HttpException(
        'Pair init failed: ${response.statusCode}',
        uri: uri,
      );
    }

    final body = await utf8.decodeStream(response);
    final json = jsonDecode(body) as Map<String, dynamic>;
    final initResponse = PairInitResponse.fromJson(json);

    _log(
      'Pair init succeeded: session=${initResponse.pairingSessionId} '
      'expiresIn=${initResponse.expiresInSec}s',
    );

    // Derive comparison code and pairing key from ECDH shared secret
    final result = await _deriveComparisonCode(
      listenerIdentity: listenerIdentity,
      monitorPublicKeyB64: initResponse.monitorPublicKey,
      sessionId: initResponse.pairingSessionId,
      expiresInSec: initResponse.expiresInSec,
    );

    _log('Derived comparison code: ${result.comparisonCode}');
    return result;
  }

  /// Confirms pairing by calling POST /pair/confirm.
  ///
  /// This should be called after the user has verified that the comparison
  /// codes on both devices match.
  Future<PairConfirmResponse> confirmPairing({
    required String host,
    required int port,
    required String expectedFingerprint,
    required DeviceIdentity listenerIdentity,
    required String sessionId,
    required List<int> pairingKey,
    bool allowUnpinned = false,
  }) async {
    _log(
      'Confirming pairing to $host:$port session=$sessionId',
    );

    // Reuse existing client or create new one
    final client = _client ??
        await _httpClient(
          expectedFingerprint,
          listenerIdentity,
          allowUnpinned: allowUnpinned,
        );

    final uri = Uri(
      scheme: 'https',
      host: host,
      port: port,
      path: '/pair/confirm',
    );

    // Build transcript
    final transcript = <String, dynamic>{
      'pairingSessionId': sessionId,
      'listenerId': listenerIdentity.deviceId,
      'listenerCertFingerprint': listenerIdentity.certFingerprint,
      'monitorCertFingerprint': expectedFingerprint.isNotEmpty
          ? expectedFingerprint
          : (_lastSeenFingerprint ?? ''),
    };

    // Compute auth tag
    final canonicalTranscript = _canonicalizeJson(transcript);
    final hmacAlgo = Hmac.sha256();
    final mac = await hmacAlgo.calculateMac(
      utf8.encode(canonicalTranscript),
      secretKey: SecretKey(pairingKey),
    );
    final authTag = base64Encode(mac.bytes);

    final confirmRequest = PairConfirmRequest(
      pairingSessionId: sessionId,
      transcript: transcript,
      authTag: authTag,
    );

    _log('POST $uri');
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.write(confirmRequest.toJsonString());
    final response = await request.close();

    if (response.statusCode != HttpStatus.ok) {
      final body = await utf8.decodeStream(response);
      _log('Pair confirm failed: ${response.statusCode} $body');
      throw HttpException(
        'Pair confirm failed: ${response.statusCode}',
        uri: uri,
      );
    }

    final body = await utf8.decodeStream(response);
    final json = jsonDecode(body) as Map<String, dynamic>;
    final result = PairConfirmResponse.fromJson(json);

    _log(
      'Pair confirm result: accepted=${result.accepted} '
      'reason=${result.reason ?? 'none'}',
    );

    return result;
  }

  /// Derives the comparison code and pairing key from ECDH shared secret.
  Future<PairInitResult> _deriveComparisonCode({
    required DeviceIdentity listenerIdentity,
    required String monitorPublicKeyB64,
    required String sessionId,
    required int expiresInSec,
  }) async {
    // Parse monitor's P-256 public key
    final monitorPublicKeyBytes = base64Decode(monitorPublicKeyB64);
    if (monitorPublicKeyBytes.length != 65 || monitorPublicKeyBytes[0] != 0x04) {
      throw FormatException('Invalid monitor public key format');
    }

    // Compute shared secret via P-256 ECDH using pointycastle
    final sharedSecretBytes = await _computeEcdhSharedSecret(
      ourIdentity: listenerIdentity,
      theirPublicKeyUncompressed: monitorPublicKeyBytes,
    );

    // Derive comparison code and pairing key from shared secret
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(sharedSecretBytes),
      info: utf8.encode('cribcall-pairing-v2'),
    );
    final derivedBytes = await derived.extractBytes();

    // First 3 bytes -> 6-digit comparison code
    final comparisonCode = _bytesToComparisonCode(derivedBytes.sublist(0, 3));
    // Remaining bytes -> pairing key
    final pairingKey = derivedBytes.sublist(3);

    return PairInitResult(
      sessionId: sessionId,
      comparisonCode: comparisonCode,
      pairingKey: pairingKey,
      expiresAt: DateTime.now().add(Duration(seconds: expiresInSec)),
    );
  }

  /// Pairs using a one-time token from QR code.
  ///
  /// This is a single-step pairing - no comparison code needed.
  /// If the token is valid, pairing completes immediately.
  Future<PairTokenResponse> pairWithToken({
    required String host,
    required int port,
    required String expectedFingerprint,
    required String pairingToken,
    required DeviceIdentity listenerIdentity,
    required String listenerName,
  }) async {
    _log(
      'Token pairing to $host:$port '
      'expectedFp=${_shortFingerprint(expectedFingerprint)}',
    );

    final client = await _httpClient(
      expectedFingerprint,
      listenerIdentity,
    );
    _client = client;

    final uri = Uri(
      scheme: 'https',
      host: host,
      port: port,
      path: '/pair/token',
    );

    final requestBody = PairTokenRequest(
      pairingToken: pairingToken,
      deviceId: listenerIdentity.deviceId,
      deviceName: listenerName,
      certFingerprint: listenerIdentity.certFingerprint,
      certificateDer: listenerIdentity.certificateDer,
    );

    _log('POST $uri');
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.write(requestBody.toJsonString());
    final response = await request.close();

    // Capture server certificate fingerprint
    final cert = response.certificate;
    if (cert != null) {
      final fp = _fingerprintHex(cert.der);
      _lastSeenFingerprint = fp;
      _log('Server cert fingerprint=${_shortFingerprint(fp)}');
    }

    if (response.statusCode != HttpStatus.ok) {
      final body = await utf8.decodeStream(response);
      _log('Token pairing failed: ${response.statusCode} $body');
      throw HttpException(
        'Token pairing failed: ${response.statusCode}',
        uri: uri,
      );
    }

    final body = await utf8.decodeStream(response);
    final json = jsonDecode(body) as Map<String, dynamic>;
    final result = PairTokenResponse.fromJson(json);

    _log(
      'Token pairing result: accepted=${result.accepted} '
      'reason=${result.reason ?? 'none'}',
    );

    return result;
  }

  /// Confirms pairing by calling POST /pair/confirm with polling support.
  ///
  /// This should be called after the user has verified that the comparison
  /// codes on both devices match and tapped "Codes Match".
  ///
  /// The method will poll until the monitor user accepts, rejects, or timeout.
  /// [pollIntervalMs] - interval between poll attempts (default 1000ms)
  /// [timeoutMs] - total timeout for polling (default 60000ms)
  Future<PairConfirmResponse> confirmPairingWithPolling({
    required String host,
    required int port,
    required String expectedFingerprint,
    required DeviceIdentity listenerIdentity,
    required String sessionId,
    required List<int> pairingKey,
    int pollIntervalMs = 1000,
    int timeoutMs = 60000,
    bool allowUnpinned = false,
  }) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));

    while (DateTime.now().isBefore(deadline)) {
      final response = await confirmPairing(
        host: host,
        port: port,
        expectedFingerprint: expectedFingerprint,
        listenerIdentity: listenerIdentity,
        sessionId: sessionId,
        pairingKey: pairingKey,
        allowUnpinned: allowUnpinned,
      );

      if (response.status != PairConfirmStatus.pending) {
        return response;
      }

      _log('Pairing pending, polling again in ${pollIntervalMs}ms...');
      await Future<void>.delayed(Duration(milliseconds: pollIntervalMs));
    }

    _log('Pairing timed out after ${timeoutMs}ms');
    return PairConfirmResponse.rejected('Pairing timed out waiting for monitor acceptance');
  }

  /// Closes the HTTP client.
  void close() {
    _client?.close();
    _client = null;
    _log('Pairing client closed');
  }

  Future<HttpClient> _httpClient(
    String expectedFingerprint,
    DeviceIdentity identity, {
    bool allowUnpinned = false,
  }) async {
    final context = await _buildSecurityContext(identity);
    final client = HttpClient(context: context);

    client.badCertificateCallback = (cert, host, port) {
      final fp = _fingerprintHex(cert.der);

      // If expectedFingerprint is empty and allowUnpinned is true, accept any cert
      if (expectedFingerprint.isEmpty) {
        if (allowUnpinned) {
          _log(
            'TLS accepting unpinned cert for $host:$port '
            'gotFp=${_shortFingerprint(fp)} (pairing mode)',
          );
          _lastSeenFingerprint = fp;
          return true;
        } else {
          _log(
            'TLS rejecting cert for $host:$port - no expected fingerprint '
            'gotFp=${_shortFingerprint(fp)}',
          );
          return false;
        }
      }

      final ok = fp == expectedFingerprint;
      if (!ok) {
        _log(
          'TLS fingerprint mismatch for $host:$port '
          'expected=${_shortFingerprint(expectedFingerprint)} '
          'got=${_shortFingerprint(fp)}',
        );
      } else {
        _lastSeenFingerprint = fp;
      }
      return ok;
    };

    return client;
  }
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
  developer.log(message, name: 'pairing_client');
  debugPrint('[pairing_client] $message');
}

String _fingerprintHex(List<int> bytes) {
  final digest = sha256.convert(bytes);
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _shortFingerprint(String fingerprint) {
  if (fingerprint.length <= 12) return fingerprint;
  return fingerprint.substring(0, 12);
}

/// Converts 3 bytes to a 6-digit comparison code.
String _bytesToComparisonCode(List<int> bytes) {
  final value = (bytes[0] << 16) | (bytes[1] << 8) | bytes[2];
  return (value % 1000000).toString().padLeft(6, '0');
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

/// Canonicalizes JSON for consistent auth tag computation (RFC 8785).
String _canonicalizeJson(Map<String, dynamic> json) {
  final sortedKeys = json.keys.toList()..sort();
  final buffer = StringBuffer('{');
  for (var i = 0; i < sortedKeys.length; i++) {
    if (i > 0) buffer.write(',');
    final key = sortedKeys[i];
    final value = json[key];
    buffer.write('"$key":');
    if (value is String) {
      buffer.write('"$value"');
    } else if (value is Map) {
      buffer.write(_canonicalizeJson(value.cast<String, dynamic>()));
    } else {
      buffer.write(jsonEncode(value));
    }
  }
  buffer.write('}');
  return buffer.toString();
}
