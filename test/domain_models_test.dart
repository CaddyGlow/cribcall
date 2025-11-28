import 'package:flutter_test/flutter_test.dart';

import 'package:cribcall/src/config/build_flags.dart';
import 'package:cribcall/src/domain/models.dart';

void main() {
  test('monitor QR payload round-trips with type enforcement', () {
    const service = QrServiceInfo(
      protocol: 'baby-monitor',
      version: 1,
      controlPort: kControlDefaultPort,
      pairingPort: kPairingDefaultPort,
      transport: kTransportHttpWs,
    );
    const payload = MonitorQrPayload(
      remoteDeviceId: 'M1-UUID',
      monitorName: 'Nursery',
      certFingerprint: 'hex-sha256',
      service: service,
    );

    final json = payload.toJson();
    expect(json['type'], equals(MonitorQrPayload.payloadType));

    final decoded = MonitorQrPayload.fromJson(json);
    expect(decoded.remoteDeviceId, equals(payload.remoteDeviceId));
    expect(decoded.certFingerprint, equals(payload.certFingerprint));
    expect(decoded.service.controlPort, equals(kControlDefaultPort));
    expect(decoded.service.pairingPort, equals(kPairingDefaultPort));
    expect(decoded.service.transport, equals(kTransportHttpWs));

    expect(
      () => MonitorQrPayload.fromJson({...json, 'type': 'unexpected'}),
      throwsArgumentError,
    );
  });

  test('monitor QR payload round-trips with IPs', () {
    const service = QrServiceInfo(
      protocol: 'baby-monitor',
      version: 1,
      controlPort: kControlDefaultPort,
      pairingPort: kPairingDefaultPort,
      transport: kTransportHttpWs,
    );
    const payload = MonitorQrPayload(
      remoteDeviceId: 'M1-UUID',
      monitorName: 'Nursery',
      certFingerprint: 'hex-sha256',
      ips: ['192.168.1.100', '10.0.0.5'],
      service: service,
    );

    final json = payload.toJson();
    expect(json['ips'], equals(['192.168.1.100', '10.0.0.5']));

    final decoded = MonitorQrPayload.fromJson(json);
    expect(decoded.ips, equals(['192.168.1.100', '10.0.0.5']));
  });

  test('monitor QR payload without IPs omits field in JSON', () {
    const service = QrServiceInfo(
      protocol: 'baby-monitor',
      version: 1,
      controlPort: kControlDefaultPort,
      pairingPort: kPairingDefaultPort,
      transport: kTransportHttpWs,
    );
    const payload = MonitorQrPayload(
      remoteDeviceId: 'M1-UUID',
      monitorName: 'Nursery',
      certFingerprint: 'hex-sha256',
      service: service,
    );

    final json = payload.toJson();
    expect(json.containsKey('ips'), isFalse);

    final decoded = MonitorQrPayload.fromJson(json);
    expect(decoded.ips, isNull);
  });

  test('monitor settings serialize and deserialize', () {
    const settings = MonitorSettings(
      noise: NoiseSettings(
        threshold: 55,
        minDurationMs: 700,
        cooldownSeconds: 6,
      ),
      autoStreamType: AutoStreamType.audioVideo,
      autoStreamDurationSec: 20,
      audioInputGain: 100,
      audioInputDeviceId: 'alsa_input.test',
    );

    final json = settings.toJson();
    final parsed = MonitorSettings.fromJson(json);

    expect(parsed.noise.threshold, 55);
    expect(parsed.autoStreamType, AutoStreamType.audioVideo);
    expect(parsed.autoStreamDurationSec, 20);
    expect(parsed.audioInputDeviceId, 'alsa_input.test');
  });

  test('mDNS advertisement round-trips', () {
    const ad = MdnsAdvertisement(
      remoteDeviceId: 'monitor-1',
      monitorName: 'Nursery',
      certFingerprint: 'fp',
      controlPort: kControlDefaultPort,
      pairingPort: kPairingDefaultPort,
      version: 1,
      transport: kTransportHttpWs,
    );

    final parsed = MdnsAdvertisement.fromJson(ad.toJson());
    expect(parsed.monitorName, 'Nursery');
    expect(parsed.controlPort, kControlDefaultPort);
    expect(parsed.pairingPort, kPairingDefaultPort);
    expect(parsed.transport, kTransportHttpWs);
  });

  test('TrustedMonitor round-trips with knownIps', () {
    final monitor = TrustedMonitor(
      remoteDeviceId: 'monitor-1',
      monitorName: 'Nursery',
      certFingerprint: 'sha256:abc123',
      controlPort: kControlDefaultPort,
      pairingPort: kPairingDefaultPort,
      serviceVersion: 1,
      transport: kTransportHttpWs,
      lastKnownIp: '192.168.1.100',
      knownIps: ['192.168.1.100', '10.0.0.5'],
      addedAtEpochSec: 1700000000,
    );

    final json = monitor.toJson();
    expect(json['knownIps'], equals(['192.168.1.100', '10.0.0.5']));
    expect(json['lastKnownIp'], equals('192.168.1.100'));

    final parsed = TrustedMonitor.fromJson(json);
    expect(parsed.remoteDeviceId, 'monitor-1');
    expect(parsed.monitorName, 'Nursery');
    expect(parsed.knownIps, equals(['192.168.1.100', '10.0.0.5']));
    expect(parsed.lastKnownIp, '192.168.1.100');
  });

  test('TrustedMonitor without knownIps omits field in JSON', () {
    final monitor = TrustedMonitor(
      remoteDeviceId: 'monitor-1',
      monitorName: 'Nursery',
      certFingerprint: 'sha256:abc123',
      addedAtEpochSec: 1700000000,
    );

    final json = monitor.toJson();
    expect(json.containsKey('knownIps'), isFalse);

    final parsed = TrustedMonitor.fromJson(json);
    expect(parsed.knownIps, isNull);
  });

  test('TrustedMonitor copyWith preserves and updates fields', () {
    final monitor = TrustedMonitor(
      remoteDeviceId: 'monitor-1',
      monitorName: 'Nursery',
      certFingerprint: 'sha256:abc123',
      knownIps: ['192.168.1.100'],
      addedAtEpochSec: 1700000000,
    );

    final updated = monitor.copyWith(
      lastKnownIp: '10.0.0.5',
      knownIps: ['192.168.1.100', '10.0.0.5'],
    );

    expect(updated.remoteDeviceId, 'monitor-1');
    expect(updated.monitorName, 'Nursery');
    expect(updated.lastKnownIp, '10.0.0.5');
    expect(updated.knownIps, equals(['192.168.1.100', '10.0.0.5']));
  });
}
