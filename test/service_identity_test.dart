import 'package:cribcall/src/config/build_flags.dart';
import 'package:cribcall/src/identity/device_identity.dart';
import 'package:cribcall/src/identity/service_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds QR payload and mDNS advertisement from identity', () async {
    final identity = await DeviceIdentity.generate(deviceId: 'device-123');
    const builder = ServiceIdentityBuilder(
      serviceProtocol: 'baby-monitor',
      serviceVersion: 1,
      defaultPort: 48080,
      transport: kTransportHttpWs,
    );

    final qr = builder.buildQrPayload(
      identity: identity,
      monitorName: 'Nursery',
    );
    expect(qr.monitorId, 'device-123');
    expect(qr.monitorCertFingerprint, identity.certFingerprint);
    expect(qr.service.defaultPort, 48080);
    expect(qr.service.transport, kTransportHttpWs);

    final mdns = builder.buildMdnsAdvertisement(
      identity: identity,
      monitorName: 'Nursery',
      servicePort: 48080,
    );
    expect(mdns.monitorCertFingerprint, identity.certFingerprint);
    expect(mdns.servicePort, 48080);
    expect(mdns.transport, kTransportHttpWs);
  });

  test('QR payload string is canonical JSON with fingerprint', () async {
    final identity = await DeviceIdentity.generate(deviceId: 'device-abc');
    const builder = ServiceIdentityBuilder(
      serviceProtocol: 'baby-monitor',
      serviceVersion: 1,
      defaultPort: 48080,
      transport: kTransportHttpWs,
    );

    final jsonString = builder.qrPayloadString(
      identity: identity,
      monitorName: 'Room',
    );
    expect(jsonString.contains(identity.certFingerprint), isTrue);
    expect(jsonString.trim().startsWith('{'), isTrue);
    expect(jsonString.contains('"transport":"$kTransportHttpWs"'), isTrue);
  });
}
