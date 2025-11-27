import 'dart:convert';

import '../config/build_flags.dart';

enum DeviceRole { monitor, listener }

enum AutoStreamType { none, audio, audioVideo }

enum ListenerDefaultAction { notify, autoOpenStream }

class NoiseSettings {
  static const defaults = NoiseSettings(
    threshold: 50,
    minDurationMs: 800,
    cooldownSeconds: 8,
  );

  const NoiseSettings({
    required this.threshold,
    required this.minDurationMs,
    required this.cooldownSeconds,
  });

  final int threshold; // 0-100 scale
  final int minDurationMs;
  final int cooldownSeconds;

  NoiseSettings copyWith({
    int? threshold,
    int? minDurationMs,
    int? cooldownSeconds,
  }) {
    return NoiseSettings(
      threshold: threshold ?? this.threshold,
      minDurationMs: minDurationMs ?? this.minDurationMs,
      cooldownSeconds: cooldownSeconds ?? this.cooldownSeconds,
    );
  }

  Map<String, dynamic> toJson() => {
    'threshold': threshold,
    'minDurationMs': minDurationMs,
    'cooldownSeconds': cooldownSeconds,
  };

  factory NoiseSettings.fromJson(Map<String, dynamic> json) {
    // Clamp threshold to valid slider range (10-100)
    final rawThreshold = json['threshold'] as int;
    return NoiseSettings(
      threshold: rawThreshold.clamp(10, 100),
      minDurationMs: json['minDurationMs'] as int,
      cooldownSeconds: json['cooldownSeconds'] as int,
    );
  }
}

class MonitorSettings {
  static const defaults = MonitorSettings(
    noise: NoiseSettings.defaults,
    autoStreamType: AutoStreamType.audio,
    autoStreamDurationSec: 15,
  );

  const MonitorSettings({
    required this.noise,
    required this.autoStreamType,
    required this.autoStreamDurationSec,
  });

  final NoiseSettings noise;
  final AutoStreamType autoStreamType;
  final int autoStreamDurationSec;

  MonitorSettings copyWith({
    NoiseSettings? noise,
    AutoStreamType? autoStreamType,
    int? autoStreamDurationSec,
  }) {
    return MonitorSettings(
      noise: noise ?? this.noise,
      autoStreamType: autoStreamType ?? this.autoStreamType,
      autoStreamDurationSec:
          autoStreamDurationSec ?? this.autoStreamDurationSec,
    );
  }

  Map<String, dynamic> toJson() => {
    'noise': noise.toJson(),
    'autoStreamType': autoStreamType.name,
    'autoStreamDurationSec': autoStreamDurationSec,
  };

  factory MonitorSettings.fromJson(Map<String, dynamic> json) {
    return MonitorSettings(
      noise: NoiseSettings.fromJson(
        (json['noise'] as Map).cast<String, dynamic>(),
      ),
      autoStreamType: AutoStreamType.values.byName(
        json['autoStreamType'] as String,
      ),
      autoStreamDurationSec: json['autoStreamDurationSec'] as int,
    );
  }
}

class ListenerSettings {
  static const defaults = ListenerSettings(
    notificationsEnabled: true,
    defaultAction: ListenerDefaultAction.notify,
  );

  const ListenerSettings({
    required this.notificationsEnabled,
    required this.defaultAction,
  });

  final bool notificationsEnabled;
  final ListenerDefaultAction defaultAction;

  ListenerSettings copyWith({
    bool? notificationsEnabled,
    ListenerDefaultAction? defaultAction,
  }) {
    return ListenerSettings(
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      defaultAction: defaultAction ?? this.defaultAction,
    );
  }

  Map<String, dynamic> toJson() => {
    'notificationsEnabled': notificationsEnabled,
    'defaultAction': defaultAction.name,
  };

  factory ListenerSettings.fromJson(Map<String, dynamic> json) {
    return ListenerSettings(
      notificationsEnabled: json['notificationsEnabled'] as bool,
      defaultAction: ListenerDefaultAction.values.byName(
        json['defaultAction'] as String,
      ),
    );
  }
}

class TrustedPeer {
  const TrustedPeer({
    required this.deviceId,
    required this.name,
    required this.certFingerprint,
    required this.addedAtEpochSec,
    this.certificateDer,
    this.fcmToken,
  });

  final String deviceId;
  final String name;
  final String certFingerprint;
  final int addedAtEpochSec;
  /// Full certificate DER bytes for TLS-level mTLS validation.
  /// Optional for backward compatibility with existing stored peers.
  final List<int>? certificateDer;
  /// FCM token for push notifications.
  /// Listener sends this after connecting so Monitor can send noise events via FCM.
  final String? fcmToken;

  TrustedPeer copyWith({
    String? deviceId,
    String? name,
    String? certFingerprint,
    int? addedAtEpochSec,
    List<int>? certificateDer,
    String? fcmToken,
  }) {
    return TrustedPeer(
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
      certFingerprint: certFingerprint ?? this.certFingerprint,
      addedAtEpochSec: addedAtEpochSec ?? this.addedAtEpochSec,
      certificateDer: certificateDer ?? this.certificateDer,
      fcmToken: fcmToken ?? this.fcmToken,
    );
  }

  /// Returns a copy with fcmToken explicitly cleared (set to null).
  TrustedPeer clearFcmToken() {
    return TrustedPeer(
      deviceId: deviceId,
      name: name,
      certFingerprint: certFingerprint,
      addedAtEpochSec: addedAtEpochSec,
      certificateDer: certificateDer,
      fcmToken: null,
    );
  }

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'name': name,
    'certFingerprint': certFingerprint,
    'addedAtEpochSec': addedAtEpochSec,
    if (certificateDer != null) 'certificateDer': base64Encode(certificateDer!),
    if (fcmToken != null) 'fcmToken': fcmToken,
  };

  factory TrustedPeer.fromJson(Map<String, dynamic> json) {
    final certDerB64 = json['certificateDer'] as String?;
    return TrustedPeer(
      deviceId: json['deviceId'] as String,
      name: json['name'] as String,
      certFingerprint: json['certFingerprint'] as String,
      addedAtEpochSec: json['addedAtEpochSec'] as int,
      certificateDer: certDerB64 != null ? base64Decode(certDerB64) : null,
      fcmToken: json['fcmToken'] as String?,
    );
  }
}

class TrustedMonitor {
  const TrustedMonitor({
    required this.monitorId,
    required this.monitorName,
    required this.certFingerprint,
    this.controlPort = kControlDefaultPort,
    this.pairingPort = kPairingDefaultPort,
    this.serviceVersion = 1,
    this.transport = kTransportHttpWs,
    this.lastKnownIp,
    this.knownIps,
    this.lastNoiseEpochMs,
    this.lastSeenEpochMs,
    required this.addedAtEpochSec,
    this.certificateDer,
  });

  final String monitorId;
  final String monitorName;
  final String certFingerprint;
  /// Port for mTLS WebSocket control connections.
  final int controlPort;
  /// Port for TLS HTTP pairing server.
  final int pairingPort;
  final int serviceVersion;
  final String transport;
  /// The last IP address where we successfully connected to this monitor.
  final String? lastKnownIp;
  /// List of IP addresses from the QR code pairing payload.
  final List<String>? knownIps;
  final int? lastNoiseEpochMs;
  /// Timestamp (ms since epoch) when the monitor was last seen online via mDNS.
  final int? lastSeenEpochMs;
  final int addedAtEpochSec;
  /// Full certificate DER bytes for TLS-level mTLS validation.
  /// Optional for backward compatibility with existing stored monitors.
  final List<int>? certificateDer;

  TrustedMonitor copyWith({
    String? monitorId,
    String? monitorName,
    String? certFingerprint,
    int? controlPort,
    int? pairingPort,
    int? serviceVersion,
    String? transport,
    String? lastKnownIp,
    List<String>? knownIps,
    int? lastNoiseEpochMs,
    int? lastSeenEpochMs,
    int? addedAtEpochSec,
    List<int>? certificateDer,
  }) {
    return TrustedMonitor(
      monitorId: monitorId ?? this.monitorId,
      monitorName: monitorName ?? this.monitorName,
      certFingerprint: certFingerprint ?? this.certFingerprint,
      controlPort: controlPort ?? this.controlPort,
      pairingPort: pairingPort ?? this.pairingPort,
      serviceVersion: serviceVersion ?? this.serviceVersion,
      transport: transport ?? this.transport,
      lastKnownIp: lastKnownIp ?? this.lastKnownIp,
      knownIps: knownIps ?? this.knownIps,
      lastNoiseEpochMs: lastNoiseEpochMs ?? this.lastNoiseEpochMs,
      lastSeenEpochMs: lastSeenEpochMs ?? this.lastSeenEpochMs,
      addedAtEpochSec: addedAtEpochSec ?? this.addedAtEpochSec,
      certificateDer: certificateDer ?? this.certificateDer,
    );
  }

  Map<String, dynamic> toJson() => {
    'monitorId': monitorId,
    'monitorName': monitorName,
    'certFingerprint': certFingerprint,
    'controlPort': controlPort,
    'pairingPort': pairingPort,
    'serviceVersion': serviceVersion,
    'transport': transport,
    if (lastKnownIp != null) 'lastKnownIp': lastKnownIp,
    if (knownIps != null && knownIps!.isNotEmpty) 'knownIps': knownIps,
    if (lastNoiseEpochMs != null) 'lastNoiseEpochMs': lastNoiseEpochMs,
    if (lastSeenEpochMs != null) 'lastSeenEpochMs': lastSeenEpochMs,
    'addedAtEpochSec': addedAtEpochSec,
    if (certificateDer != null) 'certificateDer': base64Encode(certificateDer!),
  };

  factory TrustedMonitor.fromJson(Map<String, dynamic> json) {
    final certDerB64 = json['certificateDer'] as String?;
    return TrustedMonitor(
      monitorId: json['monitorId'] as String,
      monitorName: json['monitorName'] as String,
      certFingerprint: json['certFingerprint'] as String,
      // Support old 'servicePort' field for backward compatibility
      controlPort: json['controlPort'] as int? ?? json['servicePort'] as int? ?? kControlDefaultPort,
      pairingPort: json['pairingPort'] as int? ?? kPairingDefaultPort,
      serviceVersion: json['serviceVersion'] as int? ?? 1,
      transport: json['transport'] as String? ?? kTransportHttpWs,
      lastKnownIp: json['lastKnownIp'] as String?,
      knownIps: (json['knownIps'] as List<dynamic>?)?.cast<String>(),
      lastNoiseEpochMs: json['lastNoiseEpochMs'] as int?,
      lastSeenEpochMs: json['lastSeenEpochMs'] as int?,
      addedAtEpochSec: json['addedAtEpochSec'] as int,
      certificateDer: certDerB64 != null ? base64Decode(certDerB64) : null,
    );
  }
}

class QrServiceInfo {
  const QrServiceInfo({
    required this.protocol,
    required this.version,
    required this.controlPort,
    required this.pairingPort,
    this.transport = kTransportHttpWs,
  });

  final String protocol;
  final int version;
  /// Port for mTLS WebSocket control connections.
  final int controlPort;
  /// Port for TLS HTTP pairing server.
  final int pairingPort;
  final String transport;

  Map<String, dynamic> toJson() => {
    'protocol': protocol,
    'version': version,
    'controlPort': controlPort,
    'pairingPort': pairingPort,
    'transport': transport,
  };

  factory QrServiceInfo.fromJson(Map<String, dynamic> json) {
    return QrServiceInfo(
      protocol: json['protocol'] as String,
      version: json['version'] as int,
      // Support old 'defaultPort' field for backward compatibility
      controlPort: json['controlPort'] as int? ?? json['defaultPort'] as int? ?? kControlDefaultPort,
      pairingPort: json['pairingPort'] as int? ?? kPairingDefaultPort,
      transport: json['transport'] as String? ?? kTransportHttpWs,
    );
  }
}

class MonitorQrPayload {
  const MonitorQrPayload({
    required this.monitorId,
    required this.monitorName,
    required this.monitorCertFingerprint,
    required this.service,
    this.monitorPublicKey,
    this.ips,
    this.pairingToken,
  });

  final String monitorId;
  final String monitorName;
  final String monitorCertFingerprint;
  final String? monitorPublicKey;
  final QrServiceInfo service;
  /// List of IP addresses where the monitor can be reached.
  final List<String>? ips;
  /// One-time pairing token for QR code pairing (bypasses PIN verification).
  /// Base64url encoded 32-byte random token.
  final String? pairingToken;

  static const String payloadType = 'monitor_pair_v1';

  /// Returns true if this payload contains a one-time pairing token.
  bool get hasToken => pairingToken != null && pairingToken!.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'type': payloadType,
    'monitorId': monitorId,
    'monitorName': monitorName,
    'monitorCertFingerprint': monitorCertFingerprint,
    if (monitorPublicKey != null) 'monitorPublicKey': monitorPublicKey,
    if (ips != null && ips!.isNotEmpty) 'ips': ips,
    if (pairingToken != null) 'pairingToken': pairingToken,
    'service': service.toJson(),
  };

  factory MonitorQrPayload.fromJson(Map<String, dynamic> json) {
    if (json['type'] != payloadType) {
      throw ArgumentError('Unexpected QR payload type: ${json['type']}');
    }
    return MonitorQrPayload(
      monitorId: json['monitorId'] as String,
      monitorName: json['monitorName'] as String,
      monitorCertFingerprint: json['monitorCertFingerprint'] as String,
      monitorPublicKey: json['monitorPublicKey'] as String?,
      ips: (json['ips'] as List<dynamic>?)?.cast<String>(),
      pairingToken: json['pairingToken'] as String?,
      service: QrServiceInfo.fromJson(
        (json['service'] as Map).cast<String, dynamic>(),
      ),
    );
  }
}

class MdnsAdvertisement {
  const MdnsAdvertisement({
    required this.monitorId,
    required this.monitorName,
    required this.monitorCertFingerprint,
    required this.controlPort,
    required this.pairingPort,
    required this.version,
    this.transport = kTransportHttpWs,
    this.ip,
  });

  final String monitorId;
  final String monitorName;
  final String monitorCertFingerprint;
  /// Port for mTLS WebSocket control connections.
  final int controlPort;
  /// Port for TLS HTTP pairing server.
  final int pairingPort;
  final int version;
  final String transport;
  final String? ip;

  Map<String, dynamic> toJson() => {
    'monitorId': monitorId,
    'monitorName': monitorName,
    'monitorCertFingerprint': monitorCertFingerprint,
    'controlPort': controlPort,
    'pairingPort': pairingPort,
    'version': version,
    'transport': transport,
    if (ip != null) 'ip': ip,
  };

  factory MdnsAdvertisement.fromJson(Map<String, dynamic> json) {
    return MdnsAdvertisement(
      monitorId: json['monitorId'] as String,
      monitorName: json['monitorName'] as String,
      monitorCertFingerprint: json['monitorCertFingerprint'] as String,
      // Support old 'servicePort' field for backward compatibility
      controlPort: json['controlPort'] as int? ?? json['servicePort'] as int? ?? kControlDefaultPort,
      pairingPort: json['pairingPort'] as int? ?? kPairingDefaultPort,
      version: json['version'] as int,
      transport: json['transport'] as String? ?? kTransportHttpWs,
      ip: json['ip'] as String?,
    );
  }
}
