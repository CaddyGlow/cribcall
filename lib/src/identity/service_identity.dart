import 'dart:convert';

import '../config/build_flags.dart';
import '../domain/models.dart';
import '../utils/canonical_json.dart';
import 'device_identity.dart';

class ServiceIdentityBuilder {
  const ServiceIdentityBuilder({
    required this.serviceProtocol,
    required this.serviceVersion,
    required this.defaultPort,
    required this.transport,
    this.defaultPairingPort = kPairingDefaultPort,
  });

  final String serviceProtocol;
  final int serviceVersion;
  final int defaultPort;
  final int defaultPairingPort;
  final String transport;

  MonitorQrPayload buildQrPayload({
    required DeviceIdentity identity,
    required String monitorName,
    List<String>? ips,
    String? pairingToken,
  }) {
    return MonitorQrPayload(
      monitorId: identity.deviceId,
      monitorName: monitorName,
      monitorCertFingerprint: identity.certFingerprint,
      monitorPublicKey: base64Encode(identity.publicKey.bytes),
      ips: ips,
      pairingToken: pairingToken,
      service: QrServiceInfo(
        protocol: serviceProtocol,
        version: serviceVersion,
        controlPort: defaultPort,
        pairingPort: defaultPairingPort,
        transport: transport,
      ),
    );
  }

  String qrPayloadString({
    required DeviceIdentity identity,
    required String monitorName,
    List<String>? ips,
    String? pairingToken,
  }) {
    final payload = buildQrPayload(
      identity: identity,
      monitorName: monitorName,
      ips: ips,
      pairingToken: pairingToken,
    );
    return canonicalizeJson(payload.toJson());
  }

  MdnsAdvertisement buildMdnsAdvertisement({
    required DeviceIdentity identity,
    required String monitorName,
    required int controlPort,
    required int pairingPort,
  }) {
    return MdnsAdvertisement(
      monitorId: identity.deviceId,
      monitorName: monitorName,
      monitorCertFingerprint: identity.certFingerprint,
      controlPort: controlPort,
      pairingPort: pairingPort,
      version: serviceVersion,
      transport: transport,
    );
  }
}
