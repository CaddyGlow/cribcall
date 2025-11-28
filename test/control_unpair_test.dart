import 'package:cribcall/src/control/control_client.dart';
import 'package:cribcall/src/control/control_server.dart' as server;
import 'package:cribcall/src/domain/models.dart';
import 'package:cribcall/src/identity/device_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('control server unpairs trusted listener via /unpair', () async {
    final monitorIdentity = await DeviceIdentity.generate();
    final listenerIdentity = await DeviceIdentity.generate();
    final trustedPeer = TrustedPeer(
      remoteDeviceId: listenerIdentity.deviceId,
      name: 'Listener',
      certFingerprint: listenerIdentity.certFingerprint,
      addedAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      certificateDer: listenerIdentity.certificateDer,
    );

    String? handledFingerprint;
    String? handledDeviceId;

    final srv = server.ControlServer(
      bindAddress: '127.0.0.1',
      onUnpairRequest: (fingerprint, deviceId) async {
        handledFingerprint = fingerprint;
        handledDeviceId = deviceId;
        return true;
      },
    );

    await srv.start(
      port: 0, // ephemeral
      identity: monitorIdentity,
      trustedPeers: [trustedPeer],
    );

    try {
      final client = ControlClient(identity: listenerIdentity);
      final port = srv.boundPort;
      expect(port, isNotNull);
      final result = await client.requestUnpair(
        host: '127.0.0.1',
        port: port!,
        expectedFingerprint: monitorIdentity.certFingerprint,
        deviceId: listenerIdentity.deviceId,
      );

      expect(result, isTrue);
      expect(handledFingerprint, listenerIdentity.certFingerprint);
      expect(handledDeviceId, listenerIdentity.deviceId);
    } finally {
      await srv.stop();
    }
  });

  test('unpair returns false when monitor rejects the request', () async {
    final monitorIdentity = await DeviceIdentity.generate();
    final listenerIdentity = await DeviceIdentity.generate();
    final trustedPeer = TrustedPeer(
      remoteDeviceId: listenerIdentity.deviceId,
      name: 'Listener',
      certFingerprint: listenerIdentity.certFingerprint,
      addedAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      certificateDer: listenerIdentity.certificateDer,
    );

    var handled = false;

    final srv = server.ControlServer(
      bindAddress: '127.0.0.1',
      onUnpairRequest: (_, __) async {
        handled = true;
        return false;
      },
    );

    await srv.start(
      port: 0,
      identity: monitorIdentity,
      trustedPeers: [trustedPeer],
    );

    try {
      final client = ControlClient(identity: listenerIdentity);
      final port = srv.boundPort;
      expect(port, isNotNull);
      final result = await client.requestUnpair(
        host: '127.0.0.1',
        port: port!,
        expectedFingerprint: monitorIdentity.certFingerprint,
        deviceId: listenerIdentity.deviceId,
      );

      expect(handled, isTrue);
      expect(result, isFalse);
    } finally {
      await srv.stop();
    }
  });
}
