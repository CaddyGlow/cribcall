import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../utils/canonical_json.dart';

class PairingTranscript {
  const PairingTranscript({
    required this.monitorId,
    required this.listenerId,
    required this.listenerPublicKey,
    required this.listenerCertFingerprint,
    required this.monitorCertFingerprint,
    required this.pairingSessionId,
  });

  final String monitorId;
  final String listenerId;
  final String listenerPublicKey;
  final String listenerCertFingerprint;
  final String monitorCertFingerprint;
  final String pairingSessionId;

  Map<String, dynamic> toJson() => {
    'monitorId': monitorId,
    'listenerId': listenerId,
    'listenerPublicKey': listenerPublicKey,
    'listenerCertFingerprint': listenerCertFingerprint,
    'monitorCertFingerprint': monitorCertFingerprint,
    'pairingSessionId': pairingSessionId,
  };

  factory PairingTranscript.fromJson(Map<String, dynamic> json) {
    return PairingTranscript(
      monitorId: json['monitorId'] as String,
      listenerId: json['listenerId'] as String,
      listenerPublicKey: json['listenerPublicKey'] as String,
      listenerCertFingerprint: json['listenerCertFingerprint'] as String,
      monitorCertFingerprint: json['monitorCertFingerprint'] as String,
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
