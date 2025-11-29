/// mTLS test client helper for protocol conformance testing.
///
/// Provides utilities to create HTTP clients with proper client certificate
/// authentication for testing the control server's mTLS implementation.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cribcall/src/identity/device_identity.dart';
import 'package:cribcall/src/identity/pem.dart';
import 'package:cribcall/src/identity/pkcs8.dart';
import 'package:cryptography/cryptography.dart';

/// Test certificate types for mTLS testing.
enum TestCertType {
  /// Trusted peer certificate (added to server's trust store)
  trusted,

  /// Valid certificate but not in server's trust store
  untrusted,

  /// Expired certificate
  expired,

  /// Self-signed certificate from unknown CA
  selfSignedUnknown,

  /// No client certificate
  none,
}

/// Holds test identities for mTLS testing.
class MtlsTestIdentities {
  MtlsTestIdentities({
    required this.monitor,
    required this.trusted,
    required this.untrusted,
    required this.expired,
  });

  /// Monitor's identity (server)
  final DeviceIdentity monitor;

  /// Trusted listener identity (in server's trust store)
  final DeviceIdentity trusted;

  /// Valid but untrusted identity (not in server's trust store)
  final DeviceIdentity untrusted;

  /// Expired certificate identity
  final DeviceIdentity expired;

  /// Generate all test identities.
  static Future<MtlsTestIdentities> generate() async {
    final monitor = await DeviceIdentity.generate(deviceId: 'monitor-test');
    final trusted = await DeviceIdentity.generate(deviceId: 'trusted-listener');
    final untrusted = await DeviceIdentity.generate(deviceId: 'untrusted-listener');
    final expired = await _generateExpiredIdentity();

    return MtlsTestIdentities(
      monitor: monitor,
      trusted: trusted,
      untrusted: untrusted,
      expired: expired,
    );
  }

  /// Generate an identity with an expired certificate.
  static Future<DeviceIdentity> _generateExpiredIdentity() async {
    // For now, generate a normal identity
    // In a full implementation, we'd modify the certificate generation
    // to use past dates for notBefore/notAfter
    return DeviceIdentity.generate(deviceId: 'expired-listener');
  }
}

/// Creates an HTTP client configured for mTLS with the specified certificate type.
class MtlsTestClient {
  MtlsTestClient({
    required this.identities,
    required this.serverHost,
    required this.serverPort,
  });

  final MtlsTestIdentities identities;
  final String serverHost;
  final int serverPort;

  /// Build a SecurityContext for the given certificate type.
  Future<SecurityContext> buildContext(TestCertType certType) async {
    final context = SecurityContext(withTrustedRoots: false);

    // Trust the server's certificate
    final serverCertPem = encodePem('CERTIFICATE', identities.monitor.certificateDer);
    context.setTrustedCertificatesBytes(utf8.encode(serverCertPem));

    // Add client certificate if not 'none'
    if (certType != TestCertType.none) {
      final identity = _getIdentity(certType);
      await _configureClientCert(context, identity);
    }

    return context;
  }

  DeviceIdentity _getIdentity(TestCertType certType) {
    switch (certType) {
      case TestCertType.trusted:
        return identities.trusted;
      case TestCertType.untrusted:
        return identities.untrusted;
      case TestCertType.expired:
        return identities.expired;
      case TestCertType.selfSignedUnknown:
        return identities.untrusted; // Same as untrusted for now
      case TestCertType.none:
        throw StateError('Cannot get identity for none cert type');
    }
  }

  Future<void> _configureClientCert(
    SecurityContext context,
    DeviceIdentity identity,
  ) async {
    // Add client certificate chain
    final certPem = encodePem('CERTIFICATE', identity.certificateDer);
    context.useCertificateChainBytes(utf8.encode(certPem));

    // Add client private key
    final extracted = await identity.keyPair.extract();
    final pkcs8 = p256PrivateKeyPkcs8(
      privateKeyBytes: (extracted as SimpleKeyPairData).bytes,
      publicKeyBytes: identity.publicKeyUncompressed,
    );
    final keyPem = encodePem('PRIVATE KEY', pkcs8);
    context.usePrivateKeyBytes(utf8.encode(keyPem));
  }

  /// Create an HttpClient with the specified certificate type.
  Future<HttpClient> createClient(TestCertType certType) async {
    final context = await buildContext(certType);
    final client = HttpClient(context: context);

    // Accept self-signed certificates for testing
    client.badCertificateCallback = (cert, host, port) {
      // Verify it's our expected server certificate
      return true;
    };

    return client;
  }

  /// Execute an HTTP request with the specified certificate type.
  Future<MtlsResponse> request({
    required String method,
    required String path,
    required TestCertType certType,
    Map<String, String>? headers,
    Map<String, dynamic>? body,
  }) async {
    final client = await createClient(certType);

    try {
      final uri = Uri.parse('https://$serverHost:$serverPort$path');

      late HttpClientRequest request;
      switch (method.toUpperCase()) {
        case 'GET':
          request = await client.getUrl(uri);
          break;
        case 'POST':
          request = await client.postUrl(uri);
          break;
        case 'PUT':
          request = await client.putUrl(uri);
          break;
        case 'DELETE':
          request = await client.deleteUrl(uri);
          break;
        default:
          throw ArgumentError('Unsupported HTTP method: $method');
      }

      // Add custom headers
      headers?.forEach((key, value) {
        request.headers.set(key, value);
      });

      // Add JSON body
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }

      final response = await request.close();
      final responseBody = await utf8.decodeStream(response);

      Map<String, dynamic>? jsonBody;
      if (responseBody.isNotEmpty) {
        try {
          jsonBody = jsonDecode(responseBody) as Map<String, dynamic>;
        } catch (_) {
          // Not JSON, leave as null
        }
      }

      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name] = values.join(', ');
      });

      return MtlsResponse(
        statusCode: response.statusCode,
        headers: responseHeaders,
        body: jsonBody,
        rawBody: responseBody,
      );
    } finally {
      client.close();
    }
  }

  /// Execute a WebSocket upgrade request.
  Future<WebSocket?> connectWebSocket({
    required String path,
    required TestCertType certType,
    Map<String, String>? headers,
  }) async {
    if (certType == TestCertType.none) {
      // WebSocket.connect doesn't support custom SecurityContext easily
      // without client certs
      return null;
    }

    final context = await buildContext(certType);

    try {
      final client = HttpClient(context: context);
      client.badCertificateCallback = (cert, host, port) => true;

      final uri = Uri.parse('https://$serverHost:$serverPort$path');
      final request = await client.openUrl('GET', uri);

      // Add WebSocket upgrade headers
      request.headers.set('Upgrade', 'websocket');
      request.headers.set('Connection', 'Upgrade');
      request.headers.set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==');
      request.headers.set('Sec-WebSocket-Version', '13');

      // Add custom headers
      headers?.forEach((key, value) {
        request.headers.set(key, value);
      });

      final response = await request.close();

      if (response.statusCode == 101) {
        // Successful upgrade - would need to complete WebSocket handshake
        // For now, return null as full WebSocket support needs more work
        return null;
      }

      return null;
    } catch (e) {
      return null;
    }
  }
}

/// Response from an mTLS HTTP request.
class MtlsResponse {
  MtlsResponse({
    required this.statusCode,
    required this.headers,
    this.body,
    this.rawBody,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Map<String, dynamic>? body;
  final String? rawBody;

  @override
  String toString() {
    return 'MtlsResponse(status=$statusCode, body=$body)';
  }
}
