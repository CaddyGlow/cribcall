import 'dart:convert';

import 'package:cribcall/src/config/build_flags.dart';
import 'package:cribcall/src/domain/models.dart';
import 'package:cribcall/src/pairing/qr_payload_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = QrServiceInfo(
    protocol: 'baby-monitor',
    version: 1,
    controlPort: kControlDefaultPort,
    pairingPort: kPairingDefaultPort,
    transport: kTransportHttpWs,
  );

  final payloadJson = jsonEncode({
    'type': MonitorQrPayload.payloadType,
    'remoteDeviceId': 'M1-UUID',
    'monitorName': 'Nursery',
    'certFingerprint': 'hex-sha256',
    'service': service.toJson(),
  });

  test('parses monitor QR payload from JSON string', () {
    final parsed = parseMonitorQrPayload(payloadJson);

    expect(parsed.remoteDeviceId, equals('M1-UUID'));
    expect(parsed.monitorName, equals('Nursery'));
    expect(parsed.certFingerprint, equals('hex-sha256'));
    expect(parsed.service.controlPort, equals(kControlDefaultPort));
    expect(parsed.service.pairingPort, equals(kPairingDefaultPort));
    expect(parsed.service.protocol, equals('baby-monitor'));
    expect(parsed.ips, isNull);
  });

  test('parses monitor QR payload with IPs', () {
    final payloadWithIps = jsonEncode({
      'type': MonitorQrPayload.payloadType,
      'remoteDeviceId': 'M1-UUID',
      'monitorName': 'Nursery',
      'certFingerprint': 'hex-sha256',
      'ips': ['192.168.1.100', '10.0.0.5'],
      'service': service.toJson(),
    });

    final parsed = parseMonitorQrPayload(payloadWithIps);

    expect(parsed.remoteDeviceId, equals('M1-UUID'));
    expect(parsed.ips, equals(['192.168.1.100', '10.0.0.5']));
  });

  test('rejects non-object QR payload strings', () {
    expect(() => parseMonitorQrPayload('[]'), throwsA(isA<FormatException>()));
  });

  test('enforces payload type when parsing string', () {
    final wrongTypePayload = jsonEncode({
      'type': 'wrong',
      'remoteDeviceId': 'M1-UUID',
      'monitorName': 'Nursery',
      'certFingerprint': 'hex-sha256',
      'service': service.toJson(),
    });

    expect(() => parseMonitorQrPayload(wrongTypePayload), throwsArgumentError);
  });
}
