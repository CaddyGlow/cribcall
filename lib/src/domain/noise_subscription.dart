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
    this.notificationType,
    this.webhookUrl,
    this.threshold,
    this.cooldownSeconds,
    this.autoStreamType,
    this.autoStreamDurationSec,
    this.lastNoiseEventMs,
  });

  final String deviceId;
  final String certFingerprint;

  /// Push token (FCM token, or placeholder for webhook/ws-only).
  final String fcmToken;
  final String platform;
  final int expiresAtEpochSec;
  final int createdAtEpochSec;
  final String subscriptionId;

  /// Notification delivery method. Null defaults to FCM for backward compat.
  final NotificationType? notificationType;

  /// Webhook URL for HTTP POST delivery (required when notificationType=webhook).
  final String? webhookUrl;

  /// Listener's noise threshold preference (0-100). Null means use monitor default.
  final int? threshold;

  /// Listener's cooldown preference in seconds. Null means use monitor default.
  final int? cooldownSeconds;

  /// Listener's auto-stream type preference. Null means use monitor default.
  final AutoStreamType? autoStreamType;

  /// Listener's auto-stream duration preference. Null means use monitor default.
  final int? autoStreamDurationSec;

  /// Timestamp of last noise event sent to this subscriber (for per-listener cooldown).
  /// Persisted to disk to survive restarts.
  final int? lastNoiseEventMs;

  /// Effective notification type with backward-compatible default.
  NotificationType get effectiveNotificationType =>
      notificationType ?? NotificationType.fcm;

  /// Whether this subscription uses webhook delivery.
  bool get isWebhook => effectiveNotificationType == NotificationType.webhook;

  /// Whether this subscription can only receive events over WebSocket.
  /// WebSocket-only tokens without webhook URLs cannot receive push.
  bool get isWebsocketOnly =>
      isWebsocketOnlyNoiseToken(fcmToken) && !isWebhook;

  /// Get effective threshold, with fallback to monitor default.
  int get effectiveThreshold =>
      threshold ?? MonitorSettings.defaults.noise.threshold;

  /// Get effective cooldown, with fallback to monitor default.
  int get effectiveCooldownSeconds =>
      cooldownSeconds ?? MonitorSettings.defaults.noise.cooldownSeconds;

  /// Get effective auto-stream type, with fallback to monitor default.
  AutoStreamType get effectiveAutoStreamType =>
      autoStreamType ?? MonitorSettings.defaults.autoStreamType;

  /// Get effective auto-stream duration, with fallback to monitor default.
  int get effectiveAutoStreamDurationSec =>
      autoStreamDurationSec ?? MonitorSettings.defaults.autoStreamDurationSec;

  NoiseSubscription copyWith({
    String? fcmToken,
    String? platform,
    int? expiresAtEpochSec,
    int? createdAtEpochSec,
    NotificationType? notificationType,
    String? webhookUrl,
    int? threshold,
    int? cooldownSeconds,
    AutoStreamType? autoStreamType,
    int? autoStreamDurationSec,
    int? lastNoiseEventMs,
  }) {
    return NoiseSubscription(
      deviceId: deviceId,
      certFingerprint: certFingerprint,
      fcmToken: fcmToken ?? this.fcmToken,
      platform: platform ?? this.platform,
      expiresAtEpochSec: expiresAtEpochSec ?? this.expiresAtEpochSec,
      createdAtEpochSec: createdAtEpochSec ?? this.createdAtEpochSec,
      subscriptionId: subscriptionId,
      notificationType: notificationType ?? this.notificationType,
      webhookUrl: webhookUrl ?? this.webhookUrl,
      threshold: threshold ?? this.threshold,
      cooldownSeconds: cooldownSeconds ?? this.cooldownSeconds,
      autoStreamType: autoStreamType ?? this.autoStreamType,
      autoStreamDurationSec:
          autoStreamDurationSec ?? this.autoStreamDurationSec,
      lastNoiseEventMs: lastNoiseEventMs ?? this.lastNoiseEventMs,
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
    if (notificationType != null) 'notificationType': notificationType!.name,
    if (webhookUrl != null) 'webhookUrl': webhookUrl,
    if (threshold != null) 'threshold': threshold,
    if (cooldownSeconds != null) 'cooldownSeconds': cooldownSeconds,
    if (autoStreamType != null) 'autoStreamType': autoStreamType!.name,
    if (autoStreamDurationSec != null)
      'autoStreamDurationSec': autoStreamDurationSec,
    if (lastNoiseEventMs != null) 'lastNoiseEventMs': lastNoiseEventMs,
  };

  factory NoiseSubscription.fromJson(Map<String, dynamic> json) {
    final notificationTypeName = json['notificationType'] as String?;
    final autoStreamTypeName = json['autoStreamType'] as String?;
    return NoiseSubscription(
      deviceId: json['deviceId'] as String,
      certFingerprint: json['certFingerprint'] as String,
      fcmToken: json['fcmToken'] as String,
      platform: json['platform'] as String,
      expiresAtEpochSec: json['expiresAtEpochSec'] as int,
      createdAtEpochSec: json['createdAtEpochSec'] as int,
      subscriptionId: json['subscriptionId'] as String,
      notificationType: notificationTypeName != null
          ? NotificationType.values.byName(notificationTypeName)
          : null,
      webhookUrl: json['webhookUrl'] as String?,
      threshold: json['threshold'] as int?,
      cooldownSeconds: json['cooldownSeconds'] as int?,
      autoStreamType: autoStreamTypeName != null
          ? AutoStreamType.values.byName(autoStreamTypeName)
          : null,
      autoStreamDurationSec: json['autoStreamDurationSec'] as int?,
      lastNoiseEventMs: json['lastNoiseEventMs'] as int?,
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

/// Validates a webhook URL. Returns null if valid, error message if invalid.
String? validateWebhookUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return 'Invalid URL format';
  if (uri.scheme != 'https') return 'Webhook URL must use HTTPS';
  if (uri.host.isEmpty) return 'Webhook URL must have a host';
  return null;
}

/// Returns true if the URL is a valid HTTPS webhook URL.
bool isValidWebhookUrl(String url) => validateWebhookUrl(url) == null;
