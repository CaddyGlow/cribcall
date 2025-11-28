import 'dart:async';

import 'package:cribcall/src/cli/cli_harness.dart';
import 'package:cribcall/src/control/control_messages.dart';
import 'package:cribcall/src/domain/models.dart';
import 'package:cribcall/src/identity/device_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('monitor harness accepts pairing and replies to ping', () async {
    final monitorIdentity = await DeviceIdentity.generate();
    final listenerIdentity = await DeviceIdentity.generate();

    // Track trusted listener added
    TrustedPeer? trustedListener;

    final monitor = MonitorCliHarness(
      identity: monitorIdentity,
      monitorName: 'Test Monitor',
      controlPort: 0, // ephemeral port
      pairingPort: 0, // ephemeral port
      logger: (_) {},
      onTrustedListener: (peer) {
        trustedListener = peer;
      },
      autoConfirmSessions: true,
    );

    await monitor.start();
    final controlPort = monitor.boundControlPort;
    final pairingPort = monitor.boundPairingPort;
    expect(controlPort, isNotNull);
    expect(pairingPort, isNotNull);

    final pongReceived = Completer<void>();
    final listener = ListenerCliHarness(
      identity: listenerIdentity,
      monitorHost: '127.0.0.1',
      monitorControlPort: controlPort!,
      monitorPairingPort: pairingPort!,
      monitorFingerprint: monitorIdentity.certFingerprint,
      listenerName: 'Test Listener',
      logger: (_) {},
      onMessage: (message) {
        if (message is PongMessage && !pongReceived.isCompleted) {
          pongReceived.complete();
        }
      },
    );

    try {
      // Pair using numeric comparison protocol
      // In a real scenario, both devices would show the same code
      // For testing, we just auto-confirm the code
      final result = await listener.pairAndConnect(
        onComparisonCode: (code) async {
          // Auto-confirm the comparison code in test
          expect(code.length, equals(6));
          expect(int.tryParse(code), isNotNull);
          return true;
        },
        sendPingAfterConnect: true,
      );

      if (_ed25519TlsUnsupported(result.error)) {
        return;
      }

      expect(result.ok, isTrue);
      expect(trustedListener, isNotNull);
      expect(
        trustedListener?.certFingerprint,
        equals(listenerIdentity.certFingerprint),
      );

      await pongReceived.future.timeout(const Duration(seconds: 5));
    } finally {
      await listener.stop();
      await monitor.stop();
    }
  });

  test('listener can connect to already-trusted monitor', () async {
    final monitorIdentity = await DeviceIdentity.generate();
    final listenerIdentity = await DeviceIdentity.generate();

    // Pre-trust the listener
    final trustedPeer = TrustedPeer(
      remoteDeviceId: listenerIdentity.deviceId,
      name: 'Test Listener',
      certFingerprint: listenerIdentity.certFingerprint,
      addedAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      certificateDer: listenerIdentity.certificateDer,
    );

    final monitor = MonitorCliHarness(
      identity: monitorIdentity,
      monitorName: 'Test Monitor',
      controlPort: 0,
      pairingPort: 0,
      trustedPeers: [trustedPeer],
      logger: (_) {},
    );

    await monitor.start();
    final controlPort = monitor.boundControlPort;
    expect(controlPort, isNotNull);

    final pongReceived = Completer<void>();
    final listener = ListenerCliHarness(
      identity: listenerIdentity,
      monitorHost: '127.0.0.1',
      monitorControlPort: controlPort!,
      monitorPairingPort: 0, // not used for direct connect
      monitorFingerprint: monitorIdentity.certFingerprint,
      listenerName: 'Test Listener',
      logger: (_) {},
      onMessage: (message) {
        if (message is PongMessage && !pongReceived.isCompleted) {
          pongReceived.complete();
        }
      },
    );

    try {
      final result = await listener.connect(sendPingAfterConnect: true);

      if (_ed25519TlsUnsupported(result.error)) {
        return;
      }

      expect(result.ok, isTrue);
      await pongReceived.future.timeout(const Duration(seconds: 5));
    } finally {
      await listener.stop();
      await monitor.stop();
    }
  });
}

bool _ed25519TlsUnsupported(String? error) {
  final message = error ?? '';
  return message.contains('NO_COMMON_SIGNATURE_ALGORITHMS') ||
      message.contains('signature algorithms');
}
