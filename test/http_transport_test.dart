import 'dart:convert';
import 'dart:io';

import 'package:cribcall/src/config/build_flags.dart';
import 'package:cribcall/src/control/http_transport.dart';
import 'package:cribcall/src/control/quic_transport.dart';
import 'package:cribcall/src/identity/device_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('health endpoint exposes protocol without lastSeenAt', () async {
    final identity = await DeviceIdentity.generate();
    final server = HttpControlServer(bindAddress: '127.0.0.1', useTls: false);
    final port = await _ephemeralPort();
    await server.start(
      port: port,
      serverIdentity: identity,
      trustedListenerFingerprints: const [],
    );

    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/health'),
    );
    final response = await request.close();
    final body = jsonDecode(await utf8.decodeStream(response));

    expect(response.statusCode, HttpStatus.ok);
    expect(body['protocol'], kTransportHttpWs);
    expect(body.containsKey('lastSeenAt'), isFalse);

    await server.stop();
    client.close(force: true);
  });

  test('http control client connects with challenge handshake', () async {
    final serverIdentity = await DeviceIdentity.generate();
    final listenerIdentity = await DeviceIdentity.generate();
    final server = HttpControlServer(bindAddress: '127.0.0.1', useTls: false);
    final port = await _ephemeralPort();
    await server.start(
      port: port,
      serverIdentity: serverIdentity,
      trustedListenerFingerprints: [listenerIdentity.certFingerprint],
    );

    final client = HttpControlClient(useTls: false);
    final connection = await client.connect(
      endpoint: QuicEndpoint(
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
    await server.stop();
  });
}

Future<int> _ephemeralPort() async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  final port = socket.port;
  await socket.close();
  return port;
}
