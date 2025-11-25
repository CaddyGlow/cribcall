import 'dart:async';

import 'package:cribcall/src/cli/cli_harness.dart';
import 'package:cribcall/src/control/control_channel.dart';
import 'package:cribcall/src/control/control_message.dart';
import 'package:cribcall/src/control/control_transport.dart';
import 'package:cribcall/src/identity/device_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('monitor harness accepts pairing and replies to ping', () async {
    final monitorIdentity = await DeviceIdentity.generate();
    final listenerIdentity = await DeviceIdentity.generate();

    final monitor = MonitorCliHarness(
      identity: monitorIdentity,
      port: 0, // request ephemeral port for isolation
      trustedClientCertificates: [listenerIdentity.certificateDer],
      allowUntrustedClients: true,
      logger: (_) {},
    );

    await monitor.start();
    final port = monitor.boundPort;
    expect(port, isNotNull);

    final pongReceived = Completer<void>();
    final listener = ListenerCliHarness(
      identity: listenerIdentity,
      endpoint: ControlEndpoint(
        host: '127.0.0.1',
        port: port!,
        expectedServerFingerprint: monitorIdentity.certFingerprint,
      ),
      listenerName: 'Test Listener',
      logger: (_) {},
      onMessage: (message) {
        if (message is PongMessage && !pongReceived.isCompleted) {
          pongReceived.complete();
        }
      },
    );

    try {
      final result = await listener.start(sendPingAfterPair: true);
      if (_ed25519TlsUnsupported(result.failure)) {
        return;
      }
      expect(result.ok, isTrue);
      expect(
        monitor.trustedFingerprints.contains(listenerIdentity.certFingerprint),
        isTrue,
      );
      await pongReceived.future.timeout(const Duration(seconds: 5));
    } finally {
      await listener.stop();
      await monitor.stop();
    }
  });
}

bool _ed25519TlsUnsupported(ControlFailure? failure) {
  final message = failure?.message ?? '';
  return message.contains('NO_COMMON_SIGNATURE_ALGORITHMS') ||
      message.contains('signature algorithms');
}
