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
      defaultPort: kControlDefaultPort,
      transport: kTransportHttpWs,
    );

    final qr = builder.buildQrPayload(
      identity: identity,
      monitorName: 'Nursery',
    );
    expect(qr.remoteDeviceId, 'device-123');
    expect(qr.certFingerprint, identity.certFingerprint);
    expect(qr.service.controlPort, kControlDefaultPort);
    expect(qr.service.pairingPort, kPairingDefaultPort);
    expect(qr.service.transport, kTransportHttpWs);
    expect(qr.ips, isNull);

    final mdns = builder.buildMdnsAdvertisement(
      identity: identity,
      monitorName: 'Nursery',
      controlPort: kControlDefaultPort,
      pairingPort: kPairingDefaultPort,
    );
    expect(mdns.certFingerprint, identity.certFingerprint);
    expect(mdns.controlPort, kControlDefaultPort);
    expect(mdns.pairingPort, kPairingDefaultPort);
    expect(mdns.transport, kTransportHttpWs);
  });

  test('builds QR payload with IPs', () async {
    final identity = await DeviceIdentity.generate(deviceId: 'device-123');
    const builder = ServiceIdentityBuilder(
      serviceProtocol: 'baby-monitor',
      serviceVersion: 1,
      defaultPort: kControlDefaultPort,
      transport: kTransportHttpWs,
    );

    final qr = builder.buildQrPayload(
      identity: identity,
      monitorName: 'Nursery',
      ips: ['192.168.1.100', '10.0.0.5'],
    );
    expect(qr.remoteDeviceId, 'device-123');
    expect(qr.ips, equals(['192.168.1.100', '10.0.0.5']));
  });

  test('QR payload string is canonical JSON with fingerprint', () async {
    final identity = await DeviceIdentity.generate(deviceId: 'device-abc');
    const builder = ServiceIdentityBuilder(
      serviceProtocol: 'baby-monitor',
      serviceVersion: 1,
      defaultPort: kControlDefaultPort,
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

  test('QR payload string includes IPs when provided', () async {
    final identity = await DeviceIdentity.generate(deviceId: 'device-abc');
    const builder = ServiceIdentityBuilder(
      serviceProtocol: 'baby-monitor',
      serviceVersion: 1,
      defaultPort: kControlDefaultPort,
      transport: kTransportHttpWs,
    );

    final jsonString = builder.qrPayloadString(
      identity: identity,
      monitorName: 'Room',
      ips: ['192.168.1.100'],
    );
    expect(jsonString.contains('"ips"'), isTrue);
    expect(jsonString.contains('192.168.1.100'), isTrue);
  });
}
