import 'package:flutter_test/flutter_test.dart';

import 'package:cribcall/src/config/build_flags.dart';
import 'package:cribcall/src/domain/models.dart';

void main() {
  test('monitor QR payload round-trips with type enforcement', () {
    const service = QrServiceInfo(
      protocol: 'baby-monitor',
      version: 1,
      defaultPort: kControlDefaultPort,
      transport: kTransportHttpWs,
    );
    const payload = MonitorQrPayload(
      monitorId: 'M1-UUID',
      monitorName: 'Nursery',
      monitorCertFingerprint: 'hex-sha256',
      monitorPublicKey: 'pub',
      service: service,
    );

    final json = payload.toJson();
    expect(json['type'], equals(MonitorQrPayload.payloadType));

    final decoded = MonitorQrPayload.fromJson(json);
    expect(decoded.monitorId, equals(payload.monitorId));
    expect(
      decoded.monitorCertFingerprint,
      equals(payload.monitorCertFingerprint),
    );
    expect(decoded.service.defaultPort, equals(kControlDefaultPort));
    expect(decoded.service.transport, equals(kTransportHttpWs));

    expect(
      () => MonitorQrPayload.fromJson({...json, 'type': 'unexpected'}),
      throwsArgumentError,
    );
  });

  test('monitor settings serialize and deserialize', () {
    const settings = MonitorSettings(
      name: 'Nursery',
      noise: NoiseSettings(
        threshold: 55,
        minDurationMs: 700,
        cooldownSeconds: 6,
      ),
      autoStreamType: AutoStreamType.audioVideo,
      autoStreamDurationSec: 20,
    );

    final json = settings.toJson();
    final parsed = MonitorSettings.fromJson(json);

    expect(parsed.noise.threshold, 55);
    expect(parsed.autoStreamType, AutoStreamType.audioVideo);
    expect(parsed.autoStreamDurationSec, 20);
  });

  test('mDNS advertisement round-trips', () {
    const ad = MdnsAdvertisement(
      monitorId: 'monitor-1',
      monitorName: 'Nursery',
      monitorCertFingerprint: 'fp',
      servicePort: kControlDefaultPort,
      version: 1,
      transport: kTransportHttpWs,
    );

    final parsed = MdnsAdvertisement.fromJson(ad.toJson());
    expect(parsed.monitorName, 'Nursery');
    expect(parsed.transport, kTransportHttpWs);
  });
}
