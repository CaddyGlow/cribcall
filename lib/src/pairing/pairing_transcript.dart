import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../utils/canonical_json.dart';

class PairingTranscript {
  const PairingTranscript({
    required this.remoteDeviceId,
    required this.deviceId,
    required this.publicKey,
    required this.certFingerprint,
    required this.remoteCertFingerprint,
    required this.pairingSessionId,
  });

  final String remoteDeviceId;
  final String deviceId;
  final String publicKey;
  final String certFingerprint;
  final String remoteCertFingerprint;
  final String pairingSessionId;

  Map<String, dynamic> toJson() => {
    'remoteDeviceId': remoteDeviceId,
    'deviceId': deviceId,
    'publicKey': publicKey,
    'certFingerprint': certFingerprint,
    'remoteCertFingerprint': remoteCertFingerprint,
    'pairingSessionId': pairingSessionId,
  };

  factory PairingTranscript.fromJson(Map<String, dynamic> json) {
    return PairingTranscript(
      remoteDeviceId: json['remoteDeviceId'] as String,
      deviceId: json['deviceId'] as String,
      publicKey: json['publicKey'] as String,
      certFingerprint: json['certFingerprint'] as String,
      remoteCertFingerprint: json['remoteCertFingerprint'] as String,
      pairingSessionId: json['pairingSessionId'] as String,
    );
  }

  String canonicalForm() => canonicalizeJson(toJson());

  List<int> authTag(List<int> pairingKey) {
    final hmac = Hmac(sha256, pairingKey);
    return hmac.convert(utf8.encode(canonicalForm())).bytes;
  }

  String authTagBase64(List<int> pairingKey) =>
      base64Encode(authTag(pairingKey));
}
