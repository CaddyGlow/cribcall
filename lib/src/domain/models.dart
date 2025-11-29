import 'dart:convert';

import '../config/build_flags.dart';
import 'audio.dart';

enum DeviceRole { monitor, listener }

enum AutoStreamType { none, audio, audioVideo }

/// Notification delivery method for noise events.
enum NotificationType {
  /// Firebase Cloud Messaging (Android/iOS).
  fcm,

  /// HTTP POST to a webhook URL (Linux/desktop).
  webhook,

  /// Apple Push Notification Service (iOS native, future use).
  apns,
}

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
    audioInputGain: 100,
    audioInputDeviceId: kDefaultAudioInputId,
  );

  const MonitorSettings({
    required this.noise,
    required this.autoStreamType,
    required this.autoStreamDurationSec,
    required this.audioInputGain,
    this.audioInputDeviceId,
  });

  final NoiseSettings noise;
  final AutoStreamType autoStreamType;
  final int autoStreamDurationSec;
  /// Software input gain for captured audio (percent, 0-200).
  final int audioInputGain;
  final String? audioInputDeviceId;

  MonitorSettings copyWith({
    NoiseSettings? noise,
    AutoStreamType? autoStreamType,
    int? autoStreamDurationSec,
    int? audioInputGain,
    String? audioInputDeviceId,
  }) {
    return MonitorSettings(
      noise: noise ?? this.noise,
      autoStreamType: autoStreamType ?? this.autoStreamType,
      autoStreamDurationSec:
          autoStreamDurationSec ?? this.autoStreamDurationSec,
      audioInputGain: audioInputGain ?? this.audioInputGain,
      audioInputDeviceId: audioInputDeviceId ?? this.audioInputDeviceId,
    );
  }

  Map<String, dynamic> toJson() => {
    'noise': noise.toJson(),
    'autoStreamType': autoStreamType.name,
    'autoStreamDurationSec': autoStreamDurationSec,
    'audioInputGain': audioInputGain,
    'audioInputDeviceId': audioInputDeviceId,
  };

  factory MonitorSettings.fromJson(Map<String, dynamic> json) {
    final inputGain = (json['audioInputGain'] as int?) ?? 100;
    return MonitorSettings(
      noise: NoiseSettings.fromJson(
        (json['noise'] as Map).cast<String, dynamic>(),
      ),
      autoStreamType: AutoStreamType.values.byName(
        json['autoStreamType'] as String,
      ),
      autoStreamDurationSec: json['autoStreamDurationSec'] as int,
      audioInputGain: inputGain.clamp(0, 200).toInt(),
      audioInputDeviceId:
          (json['audioInputDeviceId'] as String?) ?? kDefaultAudioInputId,
    );
  }
}

/// Noise detection preferences that listeners send to monitors.
/// These control when and how the monitor notifies this listener.
class NoisePreferences {
  static const defaults = NoisePreferences(
    threshold: 50,
    cooldownSeconds: 8,
    autoStreamType: AutoStreamType.audio,
    autoStreamDurationSec: 15,
  );

  const NoisePreferences({
    required this.threshold,
    required this.cooldownSeconds,
    required this.autoStreamType,
    required this.autoStreamDurationSec,
  });

  /// Noise threshold (0-100 scale). Monitor sends noise event when level exceeds this.
  final int threshold;

  /// Minimum seconds between noise events from the same monitor.
  final int cooldownSeconds;

  /// What the monitor should auto-stream when noise is detected.
  final AutoStreamType autoStreamType;

  /// Duration in seconds for auto-stream.
  final int autoStreamDurationSec;

  NoisePreferences copyWith({
    int? threshold,
    int? cooldownSeconds,
    AutoStreamType? autoStreamType,
    int? autoStreamDurationSec,
  }) {
    return NoisePreferences(
      threshold: threshold ?? this.threshold,
      cooldownSeconds: cooldownSeconds ?? this.cooldownSeconds,
      autoStreamType: autoStreamType ?? this.autoStreamType,
      autoStreamDurationSec: autoStreamDurationSec ?? this.autoStreamDurationSec,
    );
  }

  Map<String, dynamic> toJson() => {
    'threshold': threshold,
    'cooldownSeconds': cooldownSeconds,
    'autoStreamType': autoStreamType.name,
    'autoStreamDurationSec': autoStreamDurationSec,
  };

  factory NoisePreferences.fromJson(Map<String, dynamic> json) {
    final rawThreshold = (json['threshold'] as int?) ?? 50;
    return NoisePreferences(
      threshold: rawThreshold.clamp(10, 100),
      cooldownSeconds: (json['cooldownSeconds'] as int?) ?? 8,
      autoStreamType: AutoStreamType.values.byName(
        (json['autoStreamType'] as String?) ?? 'audio',
      ),
      autoStreamDurationSec: (json['autoStreamDurationSec'] as int?) ?? 15,
    );
  }
}

class ListenerSettings {
  static const defaults = ListenerSettings(
    notificationsEnabled: true,
    defaultAction: ListenerDefaultAction.notify,
    playbackVolume: 100,
    noisePreferences: NoisePreferences.defaults,
  );

  const ListenerSettings({
    required this.notificationsEnabled,
    required this.defaultAction,
    required this.playbackVolume,
    required this.noisePreferences,
  });

  final bool notificationsEnabled;
  final ListenerDefaultAction defaultAction;
  /// Playback volume for listener audio (percent, 0-200).
  final int playbackVolume;
  /// Global noise detection preferences sent to monitors.
  final NoisePreferences noisePreferences;

  ListenerSettings copyWith({
    bool? notificationsEnabled,
    ListenerDefaultAction? defaultAction,
    int? playbackVolume,
    NoisePreferences? noisePreferences,
  }) {
    return ListenerSettings(
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      defaultAction: defaultAction ?? this.defaultAction,
      playbackVolume: playbackVolume ?? this.playbackVolume,
      noisePreferences: noisePreferences ?? this.noisePreferences,
    );
  }

  Map<String, dynamic> toJson() => {
    'notificationsEnabled': notificationsEnabled,
    'defaultAction': defaultAction.name,
    'playbackVolume': playbackVolume,
    'noisePreferences': noisePreferences.toJson(),
  };

  factory ListenerSettings.fromJson(Map<String, dynamic> json) {
    final volume = (json['playbackVolume'] as int?) ?? 100;
    final prefsJson = json['noisePreferences'] as Map<String, dynamic>?;
    return ListenerSettings(
      notificationsEnabled: json['notificationsEnabled'] as bool,
      defaultAction: ListenerDefaultAction.values.byName(
        json['defaultAction'] as String,
      ),
      playbackVolume: volume.clamp(0, 200).toInt(),
      noisePreferences: prefsJson != null
          ? NoisePreferences.fromJson(prefsJson)
          : NoisePreferences.defaults,
    );
  }
}

class TrustedPeer {
  const TrustedPeer({
    required this.remoteDeviceId,
    required this.name,
    required this.certFingerprint,
    required this.addedAtEpochSec,
    this.certificateDer,
    this.fcmToken,
  });

  final String remoteDeviceId;
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
    String? remoteDeviceId,
    String? name,
    String? certFingerprint,
    int? addedAtEpochSec,
    List<int>? certificateDer,
    String? fcmToken,
  }) {
    return TrustedPeer(
      remoteDeviceId: remoteDeviceId ?? this.remoteDeviceId,
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
      remoteDeviceId: remoteDeviceId,
      name: name,
      certFingerprint: certFingerprint,
      addedAtEpochSec: addedAtEpochSec,
      certificateDer: certificateDer,
      fcmToken: null,
    );
  }

  Map<String, dynamic> toJson() => {
    'remoteDeviceId': remoteDeviceId,
    'name': name,
    'certFingerprint': certFingerprint,
    'addedAtEpochSec': addedAtEpochSec,
    if (certificateDer != null) 'certificateDer': base64Encode(certificateDer!),
    if (fcmToken != null) 'fcmToken': fcmToken,
  };

  factory TrustedPeer.fromJson(Map<String, dynamic> json) {
    final certDerB64 = json['certificateDer'] as String?;
    return TrustedPeer(
      remoteDeviceId: json['remoteDeviceId'] as String,
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
    required this.remoteDeviceId,
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

  final String remoteDeviceId;
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
    String? remoteDeviceId,
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
      remoteDeviceId: remoteDeviceId ?? this.remoteDeviceId,
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
    'remoteDeviceId': remoteDeviceId,
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
    final remoteId = json['remoteDeviceId'] as String? ?? '';
    return TrustedMonitor(
      remoteDeviceId: remoteId,
      monitorName: json['monitorName'] as String? ?? remoteId,
      certFingerprint: json['certFingerprint'] as String? ?? '',
      // Support old 'servicePort' field for backward compatibility
      controlPort:
          json['controlPort'] as int? ??
          json['servicePort'] as int? ??
          kControlDefaultPort,
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
      controlPort:
          json['controlPort'] as int? ??
          json['defaultPort'] as int? ??
          kControlDefaultPort,
      pairingPort: json['pairingPort'] as int? ?? kPairingDefaultPort,
      transport: json['transport'] as String? ?? kTransportHttpWs,
    );
  }
}

class MonitorQrPayload {
  const MonitorQrPayload({
    required this.remoteDeviceId,
    required this.monitorName,
    required this.certFingerprint,
    required this.service,
    this.monitorPublicKey,
    this.ips,
    this.pairingToken,
  });

  final String remoteDeviceId;
  final String monitorName;
  final String certFingerprint;
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
    'remoteDeviceId': remoteDeviceId,
    'monitorName': monitorName,
    'certFingerprint': certFingerprint,
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
      remoteDeviceId: json['remoteDeviceId'] as String,
      monitorName: json['monitorName'] as String,
      certFingerprint: json['certFingerprint'] as String,
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
    required this.remoteDeviceId,
    required this.monitorName,
    required this.certFingerprint,
    required this.controlPort,
    required this.pairingPort,
    required this.version,
    this.transport = kTransportHttpWs,
    this.ip,
  });

  final String remoteDeviceId;
  final String monitorName;
  final String certFingerprint;

  /// Port for mTLS WebSocket control connections.
  final int controlPort;

  /// Port for TLS HTTP pairing server.
  final int pairingPort;
  final int version;
  final String transport;
  final String? ip;

  Map<String, dynamic> toJson() => {
    'remoteDeviceId': remoteDeviceId,
    'monitorName': monitorName,
    'certFingerprint': certFingerprint,
    'controlPort': controlPort,
    'pairingPort': pairingPort,
    'version': version,
    'transport': transport,
    if (ip != null) 'ip': ip,
  };

  factory MdnsAdvertisement.fromJson(Map<String, dynamic> json) {
    return MdnsAdvertisement(
      remoteDeviceId: json['remoteDeviceId'] as String,
      monitorName: json['monitorName'] as String,
      certFingerprint: json['certFingerprint'] as String? ?? '',
      // Support old 'servicePort' field for backward compatibility
      controlPort:
          json['controlPort'] as int? ??
          json['servicePort'] as int? ??
          kControlDefaultPort,
      pairingPort: json['pairingPort'] as int? ?? kPairingDefaultPort,
      version: json['version'] as int,
      transport: json['transport'] as String? ?? kTransportHttpWs,
      ip: json['ip'] as String?,
    );
  }
}

/// Event emitted by mDNS browse stream indicating service online/offline status.
class MdnsEvent {
  const MdnsEvent({required this.advertisement, required this.isOnline});

  final MdnsAdvertisement advertisement;

  /// True when service is discovered/announced, false when service goes offline
  /// (goodbye packet with TTL=0 or platform service lost callback).
  final bool isOnline;

  /// Convenience constructor for online events.
  const MdnsEvent.online(this.advertisement) : isOnline = true;

  /// Convenience constructor for offline events.
  const MdnsEvent.offline(this.advertisement) : isOnline = false;
}
