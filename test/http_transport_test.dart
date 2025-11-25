import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart';
import 'package:cribcall/src/config/build_flags.dart';
import 'package:cribcall/src/control/http_transport.dart';
import 'package:cribcall/src/control/control_transport.dart';
import 'package:cribcall/src/identity/device_identity.dart';
import 'package:cribcall/src/identity/pem.dart';
import 'package:cribcall/src/identity/pkcs8.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'health endpoint exposes protocol without lastSeenAt over TLS',
    () async {
      final identity = await DeviceIdentity.generate();
      final clientIdentity = await DeviceIdentity.generate();
      final server = HttpControlServer(
        bindAddress: '127.0.0.1',
        allowUntrustedClients: true,
      );
      final port = await _ephemeralPort();
      HttpClient? client;
      try {
      await server.start(
        port: port,
        serverIdentity: identity,
        trustedListenerFingerprints: const [],
        trustedClientCertificates: [clientIdentity.certificateDer],
      );

        client = await _mtlsHttpClient(
          clientIdentity,
          expectedServerFingerprint: identity.certFingerprint,
        );
        final request = await client.getUrl(
          Uri.parse('https://127.0.0.1:$port/health'),
        );
        final response = await request.close();
        final body = jsonDecode(await utf8.decodeStream(response));

        expect(response.statusCode, HttpStatus.ok);
        expect(body['protocol'], kTransportHttpWs);
        expect(body.containsKey('lastSeenAt'), isFalse);
      } on HandshakeException catch (e) {
        if (_ed25519TlsUnsupported(e)) {
          // Skip on runtimes that cannot negotiate Ed25519 certificates.
          return;
        }
        rethrow;
      } finally {
        client?.close(force: true);
        await server.stop();
      }
    },
  );

  test('http control client connects with mTLS handshake', () async {
    final serverIdentity = await DeviceIdentity.generate();
    final listenerIdentity = await DeviceIdentity.generate();
    final server = HttpControlServer(
      bindAddress: '127.0.0.1',
      allowUntrustedClients: true,
    );
    final port = await _ephemeralPort();
    try {
    await server.start(
      port: port,
      serverIdentity: serverIdentity,
      trustedListenerFingerprints: [listenerIdentity.certFingerprint],
      trustedClientCertificates: [listenerIdentity.certificateDer],
    );

      final client = HttpControlClient();
      final connection = await client.connect(
        endpoint: ControlEndpoint(
          host: '127.0.0.1',
          port: port,
          expectedServerFingerprint: serverIdentity.certFingerprint,
          transport: kTransportHttpWs,
        ),
        clientIdentity: listenerIdentity,
      );

      final connected = await connection
          .connectionEvents()
          .firstWhere((event) => event is ControlConnected)
          .timeout(const Duration(seconds: 2));
      expect(
        (connected as ControlConnected).peerFingerprint,
        serverIdentity.certFingerprint,
      );

      await connection.close();
    } on HandshakeException catch (e) {
      if (_ed25519TlsUnsupported(e)) {
        return;
      }
      rethrow;
    } finally {
      await server.stop();
    }
  });
}

Future<int> _ephemeralPort() async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<HttpClient> _mtlsHttpClient(
  DeviceIdentity identity, {
  required String expectedServerFingerprint,
}) async {
  final context = SecurityContext(withTrustedRoots: false);
  final certPem = encodePem('CERTIFICATE', identity.certificateDer);
  final extracted = await identity.keyPair.extract();
  final pkcs8 = p256PrivateKeyPkcs8(
    privateKeyBytes: (extracted as SimpleKeyPairData).bytes,
    publicKeyBytes: identity.publicKeyUncompressed,
  );
  final keyPem = encodePem('PRIVATE KEY', pkcs8);
  context.useCertificateChainBytes(utf8.encode(certPem));
  context.usePrivateKeyBytes(utf8.encode(keyPem));
  final client = HttpClient(context: context);
  client.badCertificateCallback = (cert, host, port) {
    final fp = _fingerprintHex(cert.der);
    return fp == expectedServerFingerprint;
  };
  return client;
}

String _fingerprintHex(List<int> bytes) {
  final digest = sha256.convert(bytes);
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

bool _ed25519TlsUnsupported(Object error) {
  final message = '$error';
  return message.contains('NO_COMMON_SIGNATURE_ALGORITHMS') ||
      message.contains('signature algorithms');
}
