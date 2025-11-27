import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';

import '../identity/device_identity.dart';
import '../identity/pem.dart';
import '../identity/pkcs8.dart';
import '../utils/canonical_json.dart';
import 'control_connection.dart';
import 'pairing_messages.dart';

/// Result of initiating pairing - contains comparison code for user verification.
class PairInitResult {
  const PairInitResult({
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

/// Result of a successful pairing.
class PairingResult {
  const PairingResult({
    required this.monitorId,
    required this.monitorName,
    required this.monitorCertFingerprint,
    required this.monitorCertificateDer,
  });

  final String monitorId;
  final String monitorName;
  final String monitorCertFingerprint;
  final List<int> monitorCertificateDer;
}

typedef NoiseSubscribeResponse = ({
  String subscriptionId,
  String deviceId,
  DateTime expiresAt,
  int acceptedLeaseSeconds,
});

typedef NoiseUnsubscribeResponse = ({
  String deviceId,
  String? subscriptionId,
  DateTime? expiresAt,
  bool removed,
});

/// Exception thrown when certificate fingerprint doesn't match expected value.
class CertificateMismatchException implements Exception {
  const CertificateMismatchException({
    required this.expected,
    required this.actual,
  });

  final String expected;
  final String actual;

  @override
  String toString() =>
      'Certificate changed: monitor may have been reinstalled. '
      'Please forget and re-pair this monitor.';
}

/// Client for connecting to control and pairing servers.
class ControlClient {
  ControlClient({required this.identity});

  final DeviceIdentity identity;

  // Track certificate mismatch for better error reporting
  String? _lastMismatchExpected;
  String? _lastMismatchActual;

  /// Connect to the control server (mTLS WebSocket).
  /// Requires that the monitor's certificate is already trusted.
  Future<ControlConnection> connect({
    required String host,
    required int port,
    required String expectedFingerprint,
  }) async {
    _log('Connecting to control server $host:$port');

    // Clear any previous mismatch state
    _lastMismatchExpected = null;
    _lastMismatchActual = null;

    final client = await _buildHttpClient(expectedFingerprint);

    // Health check first - may throw CertificateMismatchException
    try {
      await _healthCheck(client, host, port, expectedFingerprint);
    } on HandshakeException {
      // If we recorded a mismatch, throw a more helpful error
      if (_lastMismatchExpected != null && _lastMismatchActual != null) {
        throw CertificateMismatchException(
          expected: _lastMismatchExpected!,
          actual: _lastMismatchActual!,
        );
      }
      rethrow;
    }

    // Upgrade to WebSocket (Uri constructor needs host without brackets)
    final uri = Uri(scheme: 'wss', host: _stripBrackets(host), port: port, path: '/control/ws');

    _log('Upgrading to WebSocket $uri');
    final socket = await WebSocket.connect(
      uri.toString(),
      customClient: client,
    ).timeout(const Duration(seconds: 10));

    final connectionId = 'client-${DateTime.now().microsecondsSinceEpoch}';
    return ControlConnection(
      socket: socket,
      peerFingerprint: expectedFingerprint,
      connectionId: connectionId,
      remoteHost: host,
      remotePort: port,
    );
  }

  HttpClient? _httpClient;
  String? _lastSeenFingerprint;

  /// The fingerprint of the server certificate from the last request.
  String? get lastSeenFingerprint => _lastSeenFingerprint;

  /// Initiates pairing with a monitor using numeric comparison protocol.
  /// Returns a [PairInitResult] with a comparison code to display.
  /// The user should verify this code matches what the monitor displays.
  Future<PairInitResult> initPairing({
    required String host,
    required int pairingPort,
    required String expectedFingerprint,
    required String listenerName,
    bool allowUnpinned = false,
  }) async {
    _log('Starting pairing with $host:$pairingPort');

    final client = await _buildHttpClient(
      expectedFingerprint,
      allowUnpinned: allowUnpinned,
    );
    _httpClient = client;

    // Step 1: POST /pair/init with our P-256 identity public key
    final initRequest = PairInitRequest(
      listenerId: identity.deviceId,
      listenerName: listenerName,
      listenerCertFingerprint: identity.certFingerprint,
      listenerCertificateDer: identity.certificateDer,
      listenerPublicKey: base64Encode(identity.publicKeyUncompressed),
    );

    final initUri = Uri.https('${_formatHost(host)}:$pairingPort', '/pair/init');
    _log('Sending pair init to $initUri');

    final initHttpRequest = await client.postUrl(initUri);
    initHttpRequest.headers.contentType = ContentType.json;
    initHttpRequest.write(initRequest.toJsonString());
    final initResponse = await initHttpRequest.close();

    // Capture server certificate fingerprint
    final cert = initResponse.certificate;
    if (cert != null) {
      final fp = _fingerprintHex(cert.der);
      _lastSeenFingerprint = fp;
      _log('Server cert fingerprint=${_shortFp(fp)}');
    }

    if (initResponse.statusCode != HttpStatus.ok) {
      final body = await utf8.decodeStream(initResponse);
      throw HttpException(
        'Pair init failed (${initResponse.statusCode}): $body',
      );
    }

    final initBody = await utf8.decodeStream(initResponse);
    final initData = PairInitResponse.fromJson(
      jsonDecode(initBody) as Map<String, dynamic>,
    );

    _log(
      'Received pair init response: session=${initData.pairingSessionId} '
      'expires=${initData.expiresInSec}s',
    );

    // Step 2: Derive comparison code from ECDH shared secret
    final result = await _deriveComparisonCode(
      monitorPublicKeyB64: initData.monitorPublicKey,
      sessionId: initData.pairingSessionId,
      expiresInSec: initData.expiresInSec,
    );

    _log('Derived comparison code: ${result.comparisonCode}');
    return result;
  }

  /// Confirms pairing after user has verified the comparison codes match.
  Future<PairingResult> confirmPairing({
    required String host,
    required int pairingPort,
    required String expectedFingerprint,
    required String sessionId,
    required List<int> pairingKey,
    bool allowUnpinned = false,
  }) async {
    _log('Confirming pairing session=$sessionId');

    // Reuse existing client or create new one
    final client =
        _httpClient ??
        await _buildHttpClient(
          expectedFingerprint,
          allowUnpinned: allowUnpinned,
        );

    // Build transcript
    final transcript = <String, dynamic>{
      'pairingSessionId': sessionId,
      'listenerId': identity.deviceId,
      'listenerCertFingerprint': identity.certFingerprint,
      'monitorCertFingerprint': expectedFingerprint.isNotEmpty
          ? expectedFingerprint
          : (_lastSeenFingerprint ?? ''),
    };

    // Compute auth tag
    final canonicalTranscript = _canonicalJson(transcript);
    final hmacAlgo = Hmac.sha256();
    final mac = await hmacAlgo.calculateMac(
      utf8.encode(canonicalTranscript),
      secretKey: SecretKey(pairingKey),
    );
    final authTag = base64Encode(mac.bytes);

    // POST /pair/confirm
    final confirmRequest = PairConfirmRequest(
      pairingSessionId: sessionId,
      transcript: transcript,
      authTag: authTag,
    );

    final confirmUri = Uri.https('${_formatHost(host)}:$pairingPort', '/pair/confirm');
    _log('Sending pair confirm to $confirmUri');

    final confirmHttpRequest = await client.postUrl(confirmUri);
    confirmHttpRequest.headers.contentType = ContentType.json;
    confirmHttpRequest.write(confirmRequest.toJsonString());
    final confirmResponse = await confirmHttpRequest.close();

    if (confirmResponse.statusCode != HttpStatus.ok) {
      final body = await utf8.decodeStream(confirmResponse);
      throw HttpException(
        'Pair confirm failed (${confirmResponse.statusCode}): $body',
      );
    }

    final confirmBody = await utf8.decodeStream(confirmResponse);
    final confirmData = PairConfirmResponse.fromJson(
      jsonDecode(confirmBody) as Map<String, dynamic>,
    );

    if (!confirmData.accepted) {
      throw HttpException('Pairing rejected: ${confirmData.reason}');
    }

    _log(
      'Pairing successful: monitorId=${confirmData.monitorId} '
      'name=${confirmData.monitorName}',
    );

    return PairingResult(
      monitorId: confirmData.monitorId!,
      monitorName: confirmData.monitorName!,
      monitorCertFingerprint: confirmData.monitorCertFingerprint!,
      monitorCertificateDer: confirmData.monitorCertificateDer!,
    );
  }

  /// Derives the comparison code and pairing key from ECDH shared secret.
  Future<PairInitResult> _deriveComparisonCode({
    required String monitorPublicKeyB64,
    required String sessionId,
    required int expiresInSec,
  }) async {
    // Parse monitor's P-256 public key (uncompressed: 0x04 + x + y)
    final monitorPublicKeyBytes = base64Decode(monitorPublicKeyB64);
    if (monitorPublicKeyBytes.length != 65 ||
        monitorPublicKeyBytes[0] != 0x04) {
      throw const FormatException('Invalid monitor public key format');
    }
    final monitorPublicKey = EcPublicKey(
      type: KeyPairType.p256,
      x: monitorPublicKeyBytes.sublist(1, 33),
      y: monitorPublicKeyBytes.sublist(33, 65),
    );

    // Convert our identity key pair to EcKeyPairData
    final ourKeyPair = await _ecKeyPairFromIdentity();

    // Compute shared secret via P-256 ECDH
    final algorithm = Ecdh.p256(length: 32);
    final sharedSecret = await algorithm.sharedSecretKey(
      keyPair: ourKeyPair,
      remotePublicKey: monitorPublicKey,
    );
    final sharedSecretBytes = await sharedSecret.extractBytes();

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

  /// Converts a DeviceIdentity's key pair to EcKeyPairData for use with ECDH.
  Future<EcKeyPairData> _ecKeyPairFromIdentity() async {
    final pubBytes = identity.publicKeyUncompressed;
    final privateKeyData = await identity.keyPair.extract();

    return EcKeyPairData(
      type: KeyPairType.p256,
      d: (privateKeyData as SimpleKeyPairData).bytes,
      x: pubBytes.sublist(1, 33),
      y: pubBytes.sublist(33, 65),
    );
  }

  /// Closes the HTTP client.
  void close() {
    _httpClient?.close();
    _httpClient = null;
  }

  /// Request the monitor to remove this listener from its trusted list.
  /// Returns true if the monitor acknowledged the unpair action.
  Future<bool> requestUnpair({
    required String host,
    required int port,
    required String expectedFingerprint,
    required String listenerId,
  }) async {
    _log('Requesting unpair from $host:$port listenerId=$listenerId');
    HttpClient? client;
    try {
      client = await _buildHttpClient(expectedFingerprint);
      final uri = Uri.https('${_formatHost(host)}:$port', '/unpair');
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'listenerId': listenerId}));

      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      final body = await utf8.decodeStream(response);

      if (response.statusCode != HttpStatus.ok) {
        _log('Unpair failed: status=${response.statusCode} body=$body');
        return false;
      }

      final data = jsonDecode(body);
      final acknowledged = data is Map && data['unpaired'] == true;
      _log('Unpair response: acknowledged=$acknowledged');
      return acknowledged;
    } catch (e) {
      _log('Unpair request error: $e');
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  /// Subscribe a noise fallback token via local HTTPS endpoint.
  Future<NoiseSubscribeResponse> subscribeNoise({
    required String host,
    required int port,
    required String expectedFingerprint,
    required String fcmToken,
    required String platform,
    int? leaseSeconds,
  }) async {
    HttpClient? client;
    try {
      client = await _buildHttpClient(expectedFingerprint);
      final uri = Uri.https('${_formatHost(host)}:$port', '/noise/subscribe');
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      final payload = <String, dynamic>{
        'fcmToken': fcmToken,
        'platform': platform,
        if (leaseSeconds != null) 'leaseSeconds': leaseSeconds,
      };
      request.write(canonicalizeJson(payload));

      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      final body = await utf8.decodeStream(response);

      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Noise subscribe failed (${response.statusCode}): $body',
          uri: uri,
        );
      }

      final data = jsonDecode(body);
      if (data is! Map) {
        throw const FormatException('Invalid subscribe response');
      }
      final deviceId = data['deviceId'] as String? ?? '';
      final subId = data['subscriptionId'] as String? ?? '';
      final expires = data['expiresAt'] as String?;
      final accepted = data['acceptedLeaseSeconds'] as int? ?? 0;
      if (expires == null || expires.isEmpty) {
        throw const FormatException('Missing expiresAt in subscribe response');
      }
      return (
        subscriptionId: subId,
        deviceId: deviceId,
        expiresAt: DateTime.parse(expires).toUtc(),
        acceptedLeaseSeconds: accepted,
      );
    } finally {
      client?.close(force: true);
    }
  }

  /// Unsubscribe a noise fallback token via local HTTPS endpoint.
  Future<NoiseUnsubscribeResponse> unsubscribeNoise({
    required String host,
    required int port,
    required String expectedFingerprint,
    String? fcmToken,
    String? subscriptionId,
  }) async {
    if (fcmToken == null && subscriptionId == null) {
      throw ArgumentError('fcmToken or subscriptionId required');
    }

    HttpClient? client;
    try {
      client = await _buildHttpClient(expectedFingerprint);
      final uri = Uri.https('${_formatHost(host)}:$port', '/noise/unsubscribe');
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      final payload = <String, dynamic>{
        if (fcmToken != null) 'fcmToken': fcmToken,
        if (subscriptionId != null) 'subscriptionId': subscriptionId,
      };
      request.write(canonicalizeJson(payload));

      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      final body = await utf8.decodeStream(response);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Noise unsubscribe failed (${response.statusCode}): $body',
          uri: uri,
        );
      }

      final data = jsonDecode(body);
      if (data is! Map) {
        throw const FormatException('Invalid unsubscribe response');
      }
      final deviceId = data['deviceId'] as String? ?? '';
      final subId = data['subscriptionId'] as String?;
      final expires = data['expiresAt'] as String?;
      final removed = data['unsubscribed'] == true;
      return (
        deviceId: deviceId,
        subscriptionId: subId,
        expiresAt: expires != null && expires.isNotEmpty
            ? DateTime.parse(expires).toUtc()
            : null,
        removed: removed,
      );
    } finally {
      client?.close(force: true);
    }
  }

  Future<void> _healthCheck(
    HttpClient client,
    String host,
    int port,
    String expectedFingerprint,
  ) async {
    final uri = Uri.https('${_formatHost(host)}:$port', '/health');
    _log('Health check to $uri');

    final request = await client.getUrl(uri);
    final response = await request.close();

    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Health check failed (${response.statusCode})');
    }

    final cert = response.certificate;
    if (cert == null) {
      throw const HttpException('Health response missing certificate');
    }

    final fp = _fingerprintHex(cert.der);
    if (fp != expectedFingerprint) {
      throw HttpException(
        'Certificate fingerprint mismatch: '
        'expected=${_shortFp(expectedFingerprint)} got=${_shortFp(fp)}',
      );
    }

    final body = await utf8.decodeStream(response);
    final data = jsonDecode(body);
    if (data is! Map || data['status'] != 'ok') {
      throw HttpException('Health check returned error: $data');
    }

    _log('Health check passed');
  }

  Future<HttpClient> _buildHttpClient(
    String expectedFingerprint, {
    bool allowUnpinned = false,
  }) async {
    final context = await _buildSecurityContext();
    final client = HttpClient(context: context);

    client.badCertificateCallback = (cert, host, port) {
      final fp = _fingerprintHex(cert.der);

      // If expectedFingerprint is empty and allowUnpinned is true, accept any cert
      if (expectedFingerprint.isEmpty) {
        if (allowUnpinned) {
          _log(
            'TLS accepting unpinned cert for $host:$port '
            'gotFp=${_shortFp(fp)} (pairing mode)',
          );
          _lastSeenFingerprint = fp;
          return true;
        } else {
          _log(
            'TLS rejecting cert for $host:$port - no expected fingerprint '
            'gotFp=${_shortFp(fp)}',
          );
          return false;
        }
      }

      final ok = fp == expectedFingerprint;
      if (!ok) {
        _log(
          'Certificate mismatch for $host:$port: '
          'expected=${_shortFp(expectedFingerprint)} got=${_shortFp(fp)}',
        );
        // Record the mismatch for better error reporting
        _lastMismatchExpected = expectedFingerprint;
        _lastMismatchActual = fp;
      } else {
        _lastSeenFingerprint = fp;
      }
      return ok;
    };

    return client;
  }

  Future<SecurityContext> _buildSecurityContext() async {
    final ctx = SecurityContext(withTrustedRoots: false);

    // Client certificate and key
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

  String _canonicalJson(Map<String, dynamic> map) {
    final sorted = Map.fromEntries(
      map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return jsonEncode(sorted);
  }
}

void _log(String message) {
  developer.log(message, name: 'control_client');
  debugPrint('[control_client] $message');
}

String _fingerprintHex(List<int> bytes) {
  final digest = sha256.convert(bytes);
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _shortFp(String fp) {
  if (fp.length <= 12) return fp;
  return '${fp.substring(0, 6)}...${fp.substring(fp.length - 4)}';
}

/// Converts 3 bytes to a 6-digit comparison code.
String _bytesToComparisonCode(List<int> bytes) {
  final value = (bytes[0] << 16) | (bytes[1] << 8) | bytes[2];
  return (value % 1000000).toString().padLeft(6, '0');
}

/// Wraps IPv6 addresses in brackets for URI authority strings.
/// IPv4 addresses and hostnames are returned unchanged.
String _formatHost(String host) {
  // Already bracketed
  if (host.startsWith('[') && host.endsWith(']')) return host;
  // IPv6 address (contains colon but not a port separator pattern)
  if (host.contains(':')) return '[$host]';
  return host;
}

/// Strips brackets from IPv6 addresses for Uri constructor (which adds them).
String _stripBrackets(String host) {
  if (host.startsWith('[') && host.endsWith(']')) {
    return host.substring(1, host.length - 1);
  }
  return host;
}
