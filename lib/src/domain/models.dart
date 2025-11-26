import 'dart:convert';

import '../config/build_flags.dart';

enum DeviceRole { monitor, listener }

enum AutoStreamType { none, audio, audioVideo }

enum ListenerDefaultAction { notify, autoOpenStream }

class NoiseSettings {
  static const defaults = NoiseSettings(
    threshold: 60,
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
    return NoiseSettings(
      threshold: json['threshold'] as int,
      minDurationMs: json['minDurationMs'] as int,
      cooldownSeconds: json['cooldownSeconds'] as int,
    );
  }
}

class MonitorSettings {
  static const defaults = MonitorSettings(
    name: 'Nursery',
    noise: NoiseSettings.defaults,
    autoStreamType: AutoStreamType.audio,
    autoStreamDurationSec: 15,
  );

  const MonitorSettings({
    required this.name,
    required this.noise,
    required this.autoStreamType,
    required this.autoStreamDurationSec,
  });

  final String name;
  final NoiseSettings noise;
  final AutoStreamType autoStreamType;
  final int autoStreamDurationSec;

  MonitorSettings copyWith({
    String? name,
    NoiseSettings? noise,
    AutoStreamType? autoStreamType,
    int? autoStreamDurationSec,
  }) {
    return MonitorSettings(
      name: name ?? this.name,
      noise: noise ?? this.noise,
      autoStreamType: autoStreamType ?? this.autoStreamType,
      autoStreamDurationSec:
          autoStreamDurationSec ?? this.autoStreamDurationSec,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'noise': noise.toJson(),
    'autoStreamType': autoStreamType.name,
    'autoStreamDurationSec': autoStreamDurationSec,
  };

  factory MonitorSettings.fromJson(Map<String, dynamic> json) {
    return MonitorSettings(
      name: json['name'] as String,
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
    this.lastNoiseEpochMs,
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
  final String? lastKnownIp;
  final int? lastNoiseEpochMs;
  final int addedAtEpochSec;
  /// Full certificate DER bytes for TLS-level mTLS validation.
  /// Optional for backward compatibility with existing stored monitors.
  final List<int>? certificateDer;

  Map<String, dynamic> toJson() => {
    'monitorId': monitorId,
    'monitorName': monitorName,
    'certFingerprint': certFingerprint,
    'controlPort': controlPort,
    'pairingPort': pairingPort,
    'serviceVersion': serviceVersion,
    'transport': transport,
    if (lastKnownIp != null) 'lastKnownIp': lastKnownIp,
    if (lastNoiseEpochMs != null) 'lastNoiseEpochMs': lastNoiseEpochMs,
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
      lastNoiseEpochMs: json['lastNoiseEpochMs'] as int?,
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
  });

  final String monitorId;
  final String monitorName;
  final String monitorCertFingerprint;
  final String? monitorPublicKey;
  final QrServiceInfo service;

  static const String payloadType = 'monitor_pair_v1';

  Map<String, dynamic> toJson() => {
    'type': payloadType,
    'monitorId': monitorId,
    'monitorName': monitorName,
    'monitorCertFingerprint': monitorCertFingerprint,
    if (monitorPublicKey != null) 'monitorPublicKey': monitorPublicKey,
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
