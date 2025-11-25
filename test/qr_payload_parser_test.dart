import 'dart:convert';

import 'package:cribcall/src/config/build_flags.dart';
import 'package:cribcall/src/domain/models.dart';
import 'package:cribcall/src/pairing/qr_payload_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = QrServiceInfo(
    protocol: 'baby-monitor',
    version: 1,
    defaultPort: kControlDefaultPort,
    transport: kTransportHttpWs,
  );

  final payloadJson = jsonEncode({
    'type': MonitorQrPayload.payloadType,
    'monitorId': 'M1-UUID',
    'monitorName': 'Nursery',
    'monitorCertFingerprint': 'hex-sha256',
    'service': service.toJson(),
  });

  test('parses monitor QR payload from JSON string', () {
    final parsed = parseMonitorQrPayload(payloadJson);

    expect(parsed.monitorId, equals('M1-UUID'));
    expect(parsed.monitorName, equals('Nursery'));
    expect(parsed.monitorCertFingerprint, equals('hex-sha256'));
    expect(parsed.service.defaultPort, equals(kControlDefaultPort));
    expect(parsed.service.protocol, equals('baby-monitor'));
  });

  test('rejects non-object QR payload strings', () {
    expect(() => parseMonitorQrPayload('[]'), throwsA(isA<FormatException>()));
  });

  test('enforces payload type when parsing string', () {
    final wrongTypePayload = jsonEncode({
      'type': 'wrong',
      'monitorId': 'M1-UUID',
      'monitorName': 'Nursery',
      'monitorCertFingerprint': 'hex-sha256',
      'service': service.toJson(),
    });

    expect(() => parseMonitorQrPayload(wrongTypePayload), throwsArgumentError);
  });
}
