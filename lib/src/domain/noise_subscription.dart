import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';

const kWebsocketOnlyNoiseTokenPrefix = 'ws-only:';

class NoiseSubscription {
  const NoiseSubscription({
    required this.deviceId,
    required this.certFingerprint,
    required this.fcmToken,
    required this.platform,
    required this.expiresAtEpochSec,
    required this.subscriptionId,
    required this.createdAtEpochSec,
    this.threshold,
    this.cooldownSeconds,
    this.autoStreamType,
    this.autoStreamDurationSec,
  });

  final String deviceId;
  final String certFingerprint;
  final String fcmToken;
  final String platform;
  final int expiresAtEpochSec;
  final int createdAtEpochSec;
  final String subscriptionId;

  /// Listener's noise threshold preference (0-100). Null means use monitor default.
  final int? threshold;

  /// Listener's cooldown preference in seconds. Null means use monitor default.
  final int? cooldownSeconds;

  /// Listener's auto-stream type preference. Null means use monitor default.
  final AutoStreamType? autoStreamType;

  /// Listener's auto-stream duration preference. Null means use monitor default.
  final int? autoStreamDurationSec;

  /// Whether this subscription can only receive events over WebSocket.
  bool get isWebsocketOnly => isWebsocketOnlyNoiseToken(fcmToken);

  /// Get effective threshold, with fallback to default.
  int get effectiveThreshold =>
      threshold ?? NoisePreferences.defaults.threshold;

  /// Get effective cooldown, with fallback to default.
  int get effectiveCooldownSeconds =>
      cooldownSeconds ?? NoisePreferences.defaults.cooldownSeconds;

  /// Get effective auto-stream type, with fallback to default.
  AutoStreamType get effectiveAutoStreamType =>
      autoStreamType ?? NoisePreferences.defaults.autoStreamType;

  /// Get effective auto-stream duration, with fallback to default.
  int get effectiveAutoStreamDurationSec =>
      autoStreamDurationSec ?? NoisePreferences.defaults.autoStreamDurationSec;

  NoiseSubscription copyWith({
    String? fcmToken,
    String? platform,
    int? expiresAtEpochSec,
    int? createdAtEpochSec,
    int? threshold,
    int? cooldownSeconds,
    AutoStreamType? autoStreamType,
    int? autoStreamDurationSec,
  }) {
    return NoiseSubscription(
      deviceId: deviceId,
      certFingerprint: certFingerprint,
      fcmToken: fcmToken ?? this.fcmToken,
      platform: platform ?? this.platform,
      expiresAtEpochSec: expiresAtEpochSec ?? this.expiresAtEpochSec,
      createdAtEpochSec: createdAtEpochSec ?? this.createdAtEpochSec,
      subscriptionId: subscriptionId,
      threshold: threshold ?? this.threshold,
      cooldownSeconds: cooldownSeconds ?? this.cooldownSeconds,
      autoStreamType: autoStreamType ?? this.autoStreamType,
      autoStreamDurationSec:
          autoStreamDurationSec ?? this.autoStreamDurationSec,
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
    if (threshold != null) 'threshold': threshold,
    if (cooldownSeconds != null) 'cooldownSeconds': cooldownSeconds,
    if (autoStreamType != null) 'autoStreamType': autoStreamType!.name,
    if (autoStreamDurationSec != null)
      'autoStreamDurationSec': autoStreamDurationSec,
  };

  factory NoiseSubscription.fromJson(Map<String, dynamic> json) {
    final autoStreamTypeName = json['autoStreamType'] as String?;
    return NoiseSubscription(
      deviceId: json['deviceId'] as String,
      certFingerprint: json['certFingerprint'] as String,
      fcmToken: json['fcmToken'] as String,
      platform: json['platform'] as String,
      expiresAtEpochSec: json['expiresAtEpochSec'] as int,
      createdAtEpochSec: json['createdAtEpochSec'] as int,
      subscriptionId: json['subscriptionId'] as String,
      threshold: json['threshold'] as int?,
      cooldownSeconds: json['cooldownSeconds'] as int?,
      autoStreamType: autoStreamTypeName != null
          ? AutoStreamType.values.byName(autoStreamTypeName)
          : null,
      autoStreamDurationSec: json['autoStreamDurationSec'] as int?,
    );
  }
}

String noiseSubscriptionId(String deviceId, String fcmToken) {
  final digest = sha256.convert(utf8.encode('$deviceId|$fcmToken'));
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String websocketOnlyNoiseToken(String deviceId) =>
    '$kWebsocketOnlyNoiseTokenPrefix$deviceId';

bool isWebsocketOnlyNoiseToken(String token) =>
    token.startsWith(kWebsocketOnlyNoiseTokenPrefix);
