import 'dart:convert';

import 'package:crypto/crypto.dart';

class NoiseSubscription {
  const NoiseSubscription({
    required this.deviceId,
    required this.certFingerprint,
    required this.fcmToken,
    required this.platform,
    required this.expiresAtEpochSec,
    required this.subscriptionId,
    required this.createdAtEpochSec,
  });

  final String deviceId;
  final String certFingerprint;
  final String fcmToken;
  final String platform;
  final int expiresAtEpochSec;
  final int createdAtEpochSec;
  final String subscriptionId;

  NoiseSubscription copyWith({
    String? fcmToken,
    String? platform,
    int? expiresAtEpochSec,
    int? createdAtEpochSec,
  }) {
    return NoiseSubscription(
      deviceId: deviceId,
      certFingerprint: certFingerprint,
      fcmToken: fcmToken ?? this.fcmToken,
      platform: platform ?? this.platform,
      expiresAtEpochSec: expiresAtEpochSec ?? this.expiresAtEpochSec,
      createdAtEpochSec: createdAtEpochSec ?? this.createdAtEpochSec,
      subscriptionId: subscriptionId,
    );
  }

  bool isExpired(DateTime now) =>
      expiresAtEpochSec <= now.millisecondsSinceEpoch ~/ 1000;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'certFingerprint': certFingerprint,
    'fcmToken': fcmToken,
    'platform': platform,
    'expiresAtEpochSec': expiresAtEpochSec,
    'createdAtEpochSec': createdAtEpochSec,
    'subscriptionId': subscriptionId,
  };

  factory NoiseSubscription.fromJson(Map<String, dynamic> json) {
    return NoiseSubscription(
      deviceId: json['deviceId'] as String,
      certFingerprint: json['certFingerprint'] as String,
      fcmToken: json['fcmToken'] as String,
      platform: json['platform'] as String,
      expiresAtEpochSec: json['expiresAtEpochSec'] as int,
      createdAtEpochSec: json['createdAtEpochSec'] as int,
      subscriptionId: json['subscriptionId'] as String,
    );
  }
}

String noiseSubscriptionId(String deviceId, String fcmToken) {
  final digest = sha256.convert(utf8.encode('$deviceId|$fcmToken'));
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
