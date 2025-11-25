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
  });

  final String deviceId;
  final String name;
  final String certFingerprint;
  final int addedAtEpochSec;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'name': name,
    'certFingerprint': certFingerprint,
    'addedAtEpochSec': addedAtEpochSec,
  };

  factory TrustedPeer.fromJson(Map<String, dynamic> json) {
    return TrustedPeer(
      deviceId: json['deviceId'] as String,
      name: json['name'] as String,
      certFingerprint: json['certFingerprint'] as String,
      addedAtEpochSec: json['addedAtEpochSec'] as int,
    );
  }
}

class TrustedMonitor {
  const TrustedMonitor({
    required this.monitorId,
    required this.monitorName,
    required this.certFingerprint,
    this.lastKnownIp,
    required this.addedAtEpochSec,
  });

  final String monitorId;
  final String monitorName;
  final String certFingerprint;
  final String? lastKnownIp;
  final int addedAtEpochSec;

  Map<String, dynamic> toJson() => {
    'monitorId': monitorId,
    'monitorName': monitorName,
    'certFingerprint': certFingerprint,
    if (lastKnownIp != null) 'lastKnownIp': lastKnownIp,
    'addedAtEpochSec': addedAtEpochSec,
  };

  factory TrustedMonitor.fromJson(Map<String, dynamic> json) {
    return TrustedMonitor(
      monitorId: json['monitorId'] as String,
      monitorName: json['monitorName'] as String,
      certFingerprint: json['certFingerprint'] as String,
      lastKnownIp: json['lastKnownIp'] as String?,
      addedAtEpochSec: json['addedAtEpochSec'] as int,
    );
  }
}

class QrServiceInfo {
  const QrServiceInfo({
    required this.protocol,
    required this.version,
    required this.defaultPort,
    this.transport = kTransportHttpWs,
  });

  final String protocol;
  final int version;
  final int defaultPort;
  final String transport;

  Map<String, dynamic> toJson() => {
    'protocol': protocol,
    'version': version,
    'defaultPort': defaultPort,
    'transport': transport,
  };

  factory QrServiceInfo.fromJson(Map<String, dynamic> json) {
    return QrServiceInfo(
      protocol: json['protocol'] as String,
      version: json['version'] as int,
      defaultPort: json['defaultPort'] as int,
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
    required this.servicePort,
    required this.version,
    this.transport = kTransportHttpWs,
    this.ip,
  });

  final String monitorId;
  final String monitorName;
  final String monitorCertFingerprint;
  final int servicePort;
  final int version;
  final String transport;
  final String? ip;

  Map<String, dynamic> toJson() => {
    'monitorId': monitorId,
    'monitorName': monitorName,
    'monitorCertFingerprint': monitorCertFingerprint,
    'servicePort': servicePort,
    'version': version,
    'transport': transport,
    if (ip != null) 'ip': ip,
  };

  factory MdnsAdvertisement.fromJson(Map<String, dynamic> json) {
    return MdnsAdvertisement(
      monitorId: json['monitorId'] as String,
      monitorName: json['monitorName'] as String,
      monitorCertFingerprint: json['monitorCertFingerprint'] as String,
      servicePort: json['servicePort'] as int,
      version: json['version'] as int,
      transport: json['transport'] as String? ?? kTransportHttpWs,
      ip: json['ip'] as String?,
    );
  }
}
