import 'dart:convert';

import '../domain/models.dart';
import '../utils/canonical_json.dart';
import 'device_identity.dart';

class ServiceIdentityBuilder {
  const ServiceIdentityBuilder({
    required this.serviceProtocol,
    required this.serviceVersion,
    required this.defaultPort,
  });

  final String serviceProtocol;
  final int serviceVersion;
  final int defaultPort;

  MonitorQrPayload buildQrPayload({
    required DeviceIdentity identity,
    required String monitorName,
  }) {
    return MonitorQrPayload(
      monitorId: identity.deviceId,
      monitorName: monitorName,
      monitorCertFingerprint: identity.certFingerprint,
      monitorPublicKey: base64Encode(identity.publicKey.bytes),
      service: QrServiceInfo(
        protocol: serviceProtocol,
        version: serviceVersion,
        defaultPort: defaultPort,
      ),
    );
  }

  String qrPayloadString({
    required DeviceIdentity identity,
    required String monitorName,
  }) {
    final payload = buildQrPayload(
      identity: identity,
      monitorName: monitorName,
    );
    return canonicalizeJson(payload.toJson());
  }

  MdnsAdvertisement buildMdnsAdvertisement({
    required DeviceIdentity identity,
    required String monitorName,
    required int servicePort,
  }) {
    return MdnsAdvertisement(
      monitorId: identity.deviceId,
      monitorName: monitorName,
      monitorCertFingerprint: identity.certFingerprint,
      servicePort: servicePort,
      version: serviceVersion,
    );
  }
}
