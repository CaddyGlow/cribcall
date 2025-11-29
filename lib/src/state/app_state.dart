import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';
import 'dart:io';

import '../config/build_flags.dart';
import '../domain/models.dart';
import '../domain/noise_subscription.dart';
import '../discovery/mdns_service.dart';
import '../identity/device_identity.dart';
import '../identity/identity_repository.dart';
import '../identity/identity_store.dart';
import '../identity/service_identity.dart';
import '../pairing/pake_engine.dart';
import '../pairing/pin_pairing_controller.dart';
import '../background/background_service.dart';
import '../sound/audio_capture.dart';
import '../storage/app_session_repository.dart';
export '../storage/app_session_repository.dart' show AppSessionState;
import '../storage/settings_repository.dart';
import '../storage/noise_subscriptions_repository.dart';
import '../storage/trusted_listeners_repository.dart';
import '../storage/trusted_monitors_repository.dart';
import '../control/control_service.dart';
import '../fcm/fcm_service.dart';
import '../util/format_utils.dart';
import '../webrtc/monitor_streaming_controller.dart';

/// Provider for the app session repository.
final appSessionRepoProvider = Provider<AppSessionRepository>((ref) {
  return AppSessionRepository();
});

/// Provider for the persisted app session state.
final appSessionProvider =
    AsyncNotifierProvider<AppSessionController, AppSessionState>(
      AppSessionController.new,
    );

const kNoiseSubscriptionDefaultLease = Duration(hours: 24);
const kNoiseSubscriptionMaxLease = Duration(days: 7);

/// Controller for app session state with persistence.
class AppSessionController extends AsyncNotifier<AppSessionState> {
  @override
  Future<AppSessionState> build() async {
    final repo = ref.read(appSessionRepoProvider);
    return repo.load();
  }

  Future<void> setRole(DeviceRole role) async {
    final current = state.asData?.value ?? AppSessionState.defaults;
    final updated = current.copyWith(lastRole: role);
    state = AsyncData(updated);
    await ref.read(appSessionRepoProvider).save(updated);
  }

  Future<void> setMonitoringEnabled(bool enabled) async {
    final current = state.asData?.value ?? AppSessionState.defaults;
    final updated = current.copyWith(monitoringEnabled: enabled);
    state = AsyncData(updated);
    await ref.read(appSessionRepoProvider).save(updated);
  }

  Future<void> setLastConnectedRemoteDeviceId(String? remoteDeviceId) async {
    final current = state.asData?.value ?? AppSessionState.defaults;
    final updated = remoteDeviceId == null
        ? current.copyWith(clearLastConnectedMonitorId: true)
        : current.copyWith(lastConnectedMonitorId: remoteDeviceId);
    state = AsyncData(updated);
    await ref.read(appSessionRepoProvider).save(updated);
  }

  Future<void> setDeviceName(String name) async {
    final current = state.asData?.value ?? AppSessionState.defaults;
    final updated = current.copyWith(deviceName: name);
    state = AsyncData(updated);
    await ref.read(appSessionRepoProvider).save(updated);
  }
}

class RoleController extends Notifier<DeviceRole?> {
  @override
  DeviceRole? build() => null;

  void select(DeviceRole role) {
    state = role;
    // Persist to session
    ref.read(appSessionProvider.notifier).setRole(role);
  }

  void reset() => state = null;

  /// Initialize from persisted session state.
  void restoreFromSession(DeviceRole? role) {
    if (role != null) {
      state = role;
    }
  }
}

class MonitoringStatusController extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle(bool value) {
    state = value;
    // Persist to session
    ref.read(appSessionProvider.notifier).setMonitoringEnabled(value);
  }

  /// Initialize from persisted session state.
  void restoreFromSession(bool enabled) {
    state = enabled;
  }
}

class MonitorSettingsController extends AsyncNotifier<MonitorSettings> {
  @override
  Future<MonitorSettings> build() async {
    final repo = ref.read(monitorSettingsRepoProvider);
    return repo.load();
  }

  Future<void> setNoise(NoiseSettings noise) =>
      _updateAndPersist((current) => current.copyWith(noise: noise));

  Future<void> setAutoStreamDuration(int seconds) => _updateAndPersist(
    (current) => current.copyWith(autoStreamDurationSec: seconds),
  );

  Future<void> setAutoStreamType(AutoStreamType type) =>
      _updateAndPersist((current) => current.copyWith(autoStreamType: type));

  Future<void> setAudioInputDeviceId(String deviceId) => _updateAndPersist(
    (current) => current.copyWith(audioInputDeviceId: deviceId),
  );

  Future<void> setThreshold(int threshold) => _updateAndPersist(
    (current) =>
        current.copyWith(noise: current.noise.copyWith(threshold: threshold)),
  );

  Future<void> setMinDurationMs(int durationMs) => _updateAndPersist(
    (current) => current.copyWith(
      noise: current.noise.copyWith(minDurationMs: durationMs),
    ),
  );

  Future<void> setCooldownSeconds(int seconds) => _updateAndPersist(
    (current) => current.copyWith(
      noise: current.noise.copyWith(cooldownSeconds: seconds),
    ),
  );

  Future<void> setAudioInputGain(int gain) => _updateAndPersist(
    (current) => current.copyWith(
      audioInputGain: gain.clamp(0, 200).toInt(),
    ),
  );

  Future<void> toggleAutoStreamType() {
    return _updateAndPersist((current) {
      final next = switch (current.autoStreamType) {
        AutoStreamType.none => AutoStreamType.audio,
        AutoStreamType.audio => AutoStreamType.audioVideo,
        AutoStreamType.audioVideo => AutoStreamType.none,
      };
      return current.copyWith(autoStreamType: next);
    });
  }

  Future<MonitorSettings> _ensureValue() async {
    final current = state.asData?.value;
    if (current != null) return current;
    final repo = ref.read(monitorSettingsRepoProvider);
    final loaded = await repo.load();
    state = AsyncData(loaded);
    return loaded;
  }

  Future<void> _updateAndPersist(
    MonitorSettings Function(MonitorSettings current) update,
  ) async {
    final current = await _ensureValue();
    final updated = update(current);
    state = AsyncData(updated);
    await ref.read(monitorSettingsRepoProvider).save(updated);
  }
}

class ListenerSettingsController extends AsyncNotifier<ListenerSettings> {
  @override
  Future<ListenerSettings> build() async {
    final repo = ref.read(listenerSettingsRepoProvider);
    return repo.load();
  }

  Future<void> toggleNotifications() => _updateAndPersist(
    (current) =>
        current.copyWith(notificationsEnabled: !current.notificationsEnabled),
  );

  Future<void> setDefaultAction(ListenerDefaultAction action) =>
      _updateAndPersist((current) => current.copyWith(defaultAction: action));

  Future<void> setPlaybackVolume(int volume) =>
      _updateAndPersist((current) => current.copyWith(
        playbackVolume: volume.clamp(0, 200).toInt(),
      ));

  /// Set the global noise threshold preference.
  Future<void> setNoiseThreshold(int threshold) => _updateAndPersist(
        (current) => current.copyWith(
          noisePreferences: current.noisePreferences.copyWith(
            threshold: threshold.clamp(10, 100),
          ),
        ),
      );

  /// Set the global cooldown preference.
  Future<void> setCooldownSeconds(int cooldownSeconds) => _updateAndPersist(
        (current) => current.copyWith(
          noisePreferences: current.noisePreferences.copyWith(
            cooldownSeconds: cooldownSeconds.clamp(1, 120),
          ),
        ),
      );

  /// Set the global auto-stream type preference.
  Future<void> setAutoStreamType(AutoStreamType type) => _updateAndPersist(
        (current) => current.copyWith(
          noisePreferences: current.noisePreferences.copyWith(
            autoStreamType: type,
          ),
        ),
      );

  /// Set the global auto-stream duration preference.
  Future<void> setAutoStreamDurationSec(int durationSec) => _updateAndPersist(
        (current) => current.copyWith(
          noisePreferences: current.noisePreferences.copyWith(
            autoStreamDurationSec: durationSec.clamp(5, 120),
          ),
        ),
      );

  Future<ListenerSettings> _ensureValue() async {
    final current = state.asData?.value;
    if (current != null) return current;
    final repo = ref.read(listenerSettingsRepoProvider);
    final loaded = await repo.load();
    state = AsyncData(loaded);
    return loaded;
  }

  Future<void> _updateAndPersist(
    ListenerSettings Function(ListenerSettings current) update,
  ) async {
    final current = await _ensureValue();
    final updated = update(current);
    state = AsyncData(updated);
    await ref.read(listenerSettingsRepoProvider).save(updated);
  }
}

final roleProvider = NotifierProvider<RoleController, DeviceRole?>(
  RoleController.new,
);
final monitoringStatusProvider =
    NotifierProvider<MonitoringStatusController, bool>(
      MonitoringStatusController.new,
    );
final monitorSettingsProvider =
    AsyncNotifierProvider<MonitorSettingsController, MonitorSettings>(
      MonitorSettingsController.new,
    );
final listenerSettingsProvider =
    AsyncNotifierProvider<ListenerSettingsController, ListenerSettings>(
      ListenerSettingsController.new,
    );
final identityProvider =
    AsyncNotifierProvider<IdentityController, DeviceIdentity>(
      IdentityController.new,
    );
final serviceIdentityProvider = Provider<ServiceIdentityBuilder>((ref) {
  return const ServiceIdentityBuilder(
    serviceProtocol: 'baby-monitor',
    serviceVersion: 1,
    defaultPort: kControlDefaultPort,
    transport: kDefaultControlTransport,
  );
});
final mdnsServiceProvider = Provider<MdnsService>((ref) {
  if (!kIsWeb && Platform.isLinux) {
    return DesktopMdnsService();
  }
  return MethodChannelMdnsService();
});
final trustedListenersRepoProvider = Provider<TrustedListenersRepository>((
  ref,
) {
  return TrustedListenersRepository();
});
final monitorSettingsRepoProvider = Provider<MonitorSettingsRepository>((ref) {
  return MonitorSettingsRepository();
});
final listenerSettingsRepoProvider = Provider<ListenerSettingsRepository>((
  ref,
) {
  return ListenerSettingsRepository();
});
final trustedMonitorsRepoProvider = Provider<TrustedMonitorsRepository>((ref) {
  return TrustedMonitorsRepository();
});
final noiseSubscriptionsRepoProvider = Provider<NoiseSubscriptionsRepository>((
  ref,
) {
  return NoiseSubscriptionsRepository();
});
final pakeEngineProvider = Provider<PakeEngine>((ref) {
  return X25519PakeEngine();
});
final pairingServerProvider =
    NotifierProvider<PairingServerController, PairingServerState>(
      PairingServerController.new,
    );
final controlServerProvider =
    NotifierProvider<ControlServerController, ControlServerState>(
      ControlServerController.new,
    );
final controlClientProvider =
    NotifierProvider<ControlClientController, ControlClientState>(
      ControlClientController.new,
    );

/// Derived provider that only emits when the trusted listener FINGERPRINTS change.
/// This prevents server restarts when only metadata (like FCM tokens) are updated.
final _trustedListenerFingerprintsProvider = Provider<Set<String>?>((ref) {
  final listeners = ref.watch(trustedListenersProvider);
  final data = listeners.asData?.value;
  if (data == null) return null;
  return data.map((p) => p.certFingerprint).toSet();
});

/// @deprecated Use serviceLifecycleProvider from service_registration.dart instead.
/// This provider is kept for reference but no longer watched.
final controlServerAutoStartProvider = Provider<void>((ref) {
  final monitoringEnabled = ref.watch(monitoringStatusProvider);
  final identity = ref.watch(identityProvider);
  // Watch fingerprints only (not full listener data with FCM tokens)
  final trustedFingerprints = ref.watch(_trustedListenerFingerprintsProvider);
  final monitorSettings = ref.watch(monitorSettingsProvider);
  final appSession = ref.watch(appSessionProvider);

  Future.microtask(() async {
    // Read full listener data only when actually starting the server
    final trustedListeners = ref.read(trustedListenersProvider);

    if (!monitoringEnabled ||
        !identity.hasValue ||
        !trustedListeners.hasValue ||
        !monitorSettings.hasValue ||
        !appSession.hasValue) {
      developer.log(
        'Server auto-start skipped '
        'monitoring=$monitoringEnabled '
        'identityReady=${identity.hasValue} '
        'trustedReady=${trustedListeners.hasValue} '
        'settingsReady=${monitorSettings.hasValue} '
        'sessionReady=${appSession.hasValue}',
        name: 'control_server',
      );
      await ref.read(pairingServerProvider.notifier).stop();
      await ref.read(controlServerProvider.notifier).stop();
      return;
    }

    final deviceIdentity = identity.requireValue;
    final peers = trustedListeners.requireValue;
    final session = appSession.requireValue;

    developer.log(
      'Server auto-start invoking '
      'controlPort=$kControlDefaultPort pairingPort=$kPairingDefaultPort '
      'trusted=${peers.length} fingerprints=${trustedFingerprints?.length ?? 0}',
      name: 'control_server',
    );

    // Start pairing server (TLS only, for new device pairing)
    await ref
        .read(pairingServerProvider.notifier)
        .start(
          identity: deviceIdentity,
          port: kPairingDefaultPort,
          monitorName: session.deviceName,
        );

    // Start control server (mTLS WebSocket, for trusted connections)
    await ref
        .read(controlServerProvider.notifier)
        .start(
          identity: deviceIdentity,
          port: kControlDefaultPort,
          trustedPeers: peers,
        );
  });
});

/// Background service manager for platform-specific foreground services.
final backgroundServiceProvider = Provider<BackgroundServiceManager>((ref) {
  return createBackgroundServiceManager();
});

/// Audio capture state tracking
enum AudioCaptureStatus { stopped, starting, running, error }

/// Number of level samples to keep for waveform display (~5 seconds at 50fps).
const int kLevelHistorySize = 250;

class AudioCaptureState {
  const AudioCaptureState({
    this.status = AudioCaptureStatus.stopped,
    this.error,
    this.level = 0,
    this.levelHistory = const [],
  });

  final AudioCaptureStatus status;
  final String? error;

  /// Current audio level (0-100).
  final int level;

  /// Recent level history for waveform display.
  final List<int> levelHistory;

  AudioCaptureState copyWith({
    AudioCaptureStatus? status,
    String? error,
    int? level,
    List<int>? levelHistory,
  }) {
    return AudioCaptureState(
      status: status ?? this.status,
      error: error,
      level: level ?? this.level,
      levelHistory: levelHistory ?? this.levelHistory,
    );
  }
}

class AudioCaptureController extends Notifier<AudioCaptureState> {
  AudioCaptureService? _service;
  final List<int> _levelBuffer = [];

  @override
  AudioCaptureState build() => const AudioCaptureState();

  /// Whether the debug audio capture service is being used.
  bool get isDebugCapture => _service is DebugAudioCaptureService;

  /// Raw audio data stream for WebRTC streaming.
  /// Returns null if audio capture is not running.
  Stream<Uint8List>? get rawAudioStream => _service?.rawAudioStream;

  void _onLevel(int level) {
    _levelBuffer.add(level);
    if (_levelBuffer.length > kLevelHistorySize) {
      _levelBuffer.removeAt(0);
    }
    state = state.copyWith(
      level: level,
      levelHistory: List.unmodifiable(_levelBuffer),
    );
  }

  Future<void> start({
    required NoiseSettings settings,
    required NoiseEventSink onNoise,
    MdnsAdvertisement? mdnsAdvertisement,
    String? inputDeviceId,
    int inputGainPercent = 100,
  }) async {
    if (_service != null) {
      developer.log(
        'Audio capture already active, stopping first',
        name: 'audio_capture',
      );
      await stop();
    }

    state = state.copyWith(status: AudioCaptureStatus.starting);
    final gainFactor = inputGainPercent.clamp(0, 200) / 100.0;

    // Select platform-appropriate service
    if (!kIsWeb && Platform.isLinux) {
      // In debug mode on Linux, use synthetic audio for testing
      if (kDebugMode) {
        developer.log(
          'Using debug audio capture (synthetic audio)',
          name: 'audio_capture',
        );
        _service = DebugAudioCaptureService(
          settings: settings,
          onNoise: onNoise,
          onLevel: _onLevel,
          inputGain: gainFactor,
        );
      } else {
        _service = LinuxSubprocessAudioCaptureService(
          settings: settings,
          onNoise: onNoise,
          onLevel: _onLevel,
          inputGain: gainFactor,
          deviceId: inputDeviceId,
        );
      }
    } else if (!kIsWeb && Platform.isAndroid) {
      _service = AndroidAudioCaptureService(
        settings: settings,
        onNoise: onNoise,
        onLevel: _onLevel,
        inputGain: gainFactor,
        mdnsAdvertisement: mdnsAdvertisement,
      );
    } else if (!kIsWeb && Platform.isIOS) {
      _service = IOSAudioCaptureService(
        settings: settings,
        onNoise: onNoise,
        onLevel: _onLevel,
        inputGain: gainFactor,
        mdnsAdvertisement: mdnsAdvertisement,
      );
    } else {
      developer.log(
        'No audio capture available for ${Platform.operatingSystem}',
        name: 'audio_capture',
      );
      _service = NoopAudioCaptureService(
        settings: settings,
        onNoise: onNoise,
        onLevel: _onLevel,
      );
    }

    try {
      await _service!.start();
      state = state.copyWith(status: AudioCaptureStatus.running);
      developer.log('Audio capture started', name: 'audio_capture');
    } catch (e) {
      state = state.copyWith(
        status: AudioCaptureStatus.error,
        error: e.toString(),
      );
      developer.log('Audio capture start failed: $e', name: 'audio_capture');
    }
  }

  /// Inject synthetic test noise into the audio stream.
  /// Only works when using [DebugAudioCaptureService].
  /// Also plays a test tone through the virtual audio sink for WebRTC capture.
  Future<void> injectTestNoise({int durationMs = 1500}) async {
    if (_service is DebugAudioCaptureService) {
      await (_service as DebugAudioCaptureService).injectTestNoise(
        durationMs: durationMs,
      );
    } else {
      developer.log(
        'Cannot inject test noise: not using debug audio capture',
        name: 'audio_capture',
      );
    }
  }

  Future<void> stop() async {
    if (_service == null) return;

    try {
      await _service!.stop();
    } catch (e) {
      developer.log('Audio capture stop error: $e', name: 'audio_capture');
    }
    _service = null;
    _levelBuffer.clear();
    state = const AudioCaptureState(status: AudioCaptureStatus.stopped);
    developer.log('Audio capture stopped', name: 'audio_capture');
  }
}

final audioCaptureProvider =
    NotifierProvider<AudioCaptureController, AudioCaptureState>(
      AudioCaptureController.new,
    );

/// Tracks demand sources for audio capture.
class AudioCaptureDemandState {
  const AudioCaptureDemandState({
    this.noiseSubscriptionCount = 0,
    this.activeStreamCount = 0,
  });

  /// Number of active noise subscriptions.
  final int noiseSubscriptionCount;

  /// Number of active WebRTC streaming sessions.
  final int activeStreamCount;

  /// Whether there is any demand for audio capture.
  bool get hasDemand => noiseSubscriptionCount > 0 || activeStreamCount > 0;
}

/// Provider that derives audio capture demand from subscriptions and streams.
final audioCaptureDemandsProvider = Provider<AudioCaptureDemandState>((ref) {
  // Watch noise subscriptions
  final subs = ref.watch(noiseSubscriptionsProvider);
  final now = DateTime.now();
  final activeSubCount = subs.asData?.value
          .where((s) => !s.isExpired(now))
          .length ??
      0;

  // Watch active streaming sessions
  final streaming = ref.watch(monitorStreamingProvider);
  final activeStreamCount = streaming.activeSessions.length;

  return AudioCaptureDemandState(
    noiseSubscriptionCount: activeSubCount,
    activeStreamCount: activeStreamCount,
  );
});

/// @deprecated Use serviceLifecycleProvider from service_registration.dart instead.
/// This provider is kept for reference but no longer watched.
///
/// Auto-starts audio capture when monitoring is enabled on the monitor role
/// AND there is demand (subscriptions or streams).
/// On Android, this also handles mDNS advertising via the foreground service.
final audioCaptureAutoStartProvider = Provider<void>((ref) {
  final role = ref.watch(roleProvider);
  final monitoringEnabled = ref.watch(monitoringStatusProvider);
  final monitorSettings = ref.watch(monitorSettingsProvider);
  final demand = ref.watch(audioCaptureDemandsProvider);

  // Watch dependencies needed for mDNS advertisement (Android only)
  final identity = ref.watch(identityProvider);
  final appSession = ref.watch(appSessionProvider);

  Future.microtask(() async {
    // Only run audio capture on monitor devices
    if (role != DeviceRole.monitor) {
      await ref.read(audioCaptureProvider.notifier).stop();
      return;
    }

    // On Android, keep audio capture running when monitoring is enabled,
    // regardless of demand. This is because:
    // 1. Android foreground services can't be restarted from background
    // 2. The foreground service is needed for mDNS advertising anyway
    // On other platforms, stop if no demand to save resources.
    final isAndroid = !kIsWeb && Platform.isAndroid;
    final shouldStop = !monitoringEnabled ||
        !monitorSettings.hasValue ||
        (!isAndroid && !demand.hasDemand);

    if (shouldStop) {
      developer.log(
        'Audio capture skipped: monitoring=$monitoringEnabled '
        'settingsReady=${monitorSettings.hasValue} '
        'hasDemand=${demand.hasDemand} '
        'subs=${demand.noiseSubscriptionCount} '
        'streams=${demand.activeStreamCount} '
        'isAndroid=$isAndroid',
        name: 'audio_capture',
      );
      await ref.read(audioCaptureProvider.notifier).stop();
      return;
    }

    final settings = monitorSettings.requireValue;

    // Build mDNS advertisement for Android foreground service
    MdnsAdvertisement? mdnsAd;
    if (identity.hasValue && appSession.hasValue) {
      final builder = ref.read(serviceIdentityProvider);
      final controlState = ref.read(controlServerProvider);
      final pairingState = ref.read(pairingServerProvider);
      final controlPort = controlState.port ?? builder.defaultPort;
      final pairingPort = pairingState.port ?? kPairingDefaultPort;
      mdnsAd = builder.buildMdnsAdvertisement(
        identity: identity.requireValue,
        monitorName: appSession.requireValue.deviceName,
        controlPort: controlPort,
        pairingPort: pairingPort,
      );
      developer.log(
        'Audio capture with mDNS: remoteDeviceId=${mdnsAd.remoteDeviceId} controlPort=$controlPort',
        name: 'audio_capture',
      );
    }

    developer.log(
      'Audio capture auto-start: threshold=${settings.noise.threshold} '
      'minDuration=${settings.noise.minDurationMs}ms cooldown=${settings.noise.cooldownSeconds}s',
      name: 'audio_capture',
    );

    await ref
        .read(audioCaptureProvider.notifier)
        .start(
          settings: settings.noise,
          mdnsAdvertisement: mdnsAd,
          inputDeviceId: settings.audioInputDeviceId,
          inputGainPercent: settings.audioInputGain,
          onNoise: (event) {
            developer.log(
              'Noise detected: peak=${event.peakLevel} ts=${event.timestampMs}',
              name: 'audio_capture',
            );
            // Send noise event to connected listeners via control server
            final server = ref.read(controlServerProvider.notifier);
            server.broadcastNoiseEvent(
              timestampMs: event.timestampMs,
              peakLevel: event.peakLevel,
            );
          },
        );
  });
});

class NoiseSubscriptionsController
    extends AsyncNotifier<List<NoiseSubscription>> {
  @override
  Future<List<NoiseSubscription>> build() async {
    final repo = ref.read(noiseSubscriptionsRepoProvider);
    return repo.load();
  }

  Future<({NoiseSubscription subscription, int acceptedLeaseSeconds})> upsert({
    required TrustedPeer peer,
    required String platform,
    int? leaseSeconds,
    NotificationType? notificationType,
    String? fcmToken,
    String? webhookUrl,
    int? threshold,
    int? cooldownSeconds,
    AutoStreamType? autoStreamType,
    int? autoStreamDurationSec,
  }) async {
    final current = await _ensureValue();
    final now = DateTime.now();
    final accepted = _clampLeaseSeconds(leaseSeconds);
    final expiresAt = now.add(Duration(seconds: accepted));

    // Determine the identifier for subscription ID generation
    final effectiveType = notificationType ?? NotificationType.fcm;
    final identifier = switch (effectiveType) {
      NotificationType.fcm => fcmToken ?? '',
      NotificationType.webhook => webhookUrl ?? '',
      NotificationType.apns => fcmToken ?? '',
    };

    final subscription = NoiseSubscription(
      deviceId: peer.remoteDeviceId,
      certFingerprint: peer.certFingerprint,
      fcmToken: fcmToken ?? '',
      platform: platform,
      expiresAtEpochSec: expiresAt.millisecondsSinceEpoch ~/ 1000,
      createdAtEpochSec: now.millisecondsSinceEpoch ~/ 1000,
      subscriptionId: noiseSubscriptionId(peer.remoteDeviceId, identifier),
      notificationType: notificationType,
      webhookUrl: webhookUrl,
      threshold: threshold,
      cooldownSeconds: cooldownSeconds,
      autoStreamType: autoStreamType,
      autoStreamDurationSec: autoStreamDurationSec,
    );

    final updated = [
      // Only keep one active token per device; drop superseded tokens.
      ...current.where((s) => s.deviceId != peer.remoteDeviceId),
      subscription,
    ];

    state = AsyncData(updated);
    await _save(updated);
    developer.log(
      'Upserted noise subscription device=${peer.remoteDeviceId} '
      'fp=${shortFingerprint(peer.certFingerprint)} '
      'expiresAt=${expiresAt.toIso8601String()}',
      name: 'noise_sub',
    );

    return (subscription: subscription, acceptedLeaseSeconds: accepted);
  }

  Future<NoiseSubscription?> unsubscribe({
    required TrustedPeer peer,
    String? fcmToken,
    String? subscriptionId,
  }) async {
    if (fcmToken == null && subscriptionId == null) {
      throw ArgumentError('fcmToken or subscriptionId is required');
    }
    final current = await _ensureValue();
    NoiseSubscription? removed;
    final updated = <NoiseSubscription>[];
    for (final sub in current) {
      final matchesDevice = sub.deviceId == peer.remoteDeviceId;
      final matchesToken = fcmToken == null ? true : sub.fcmToken == fcmToken;
      final matchesId = subscriptionId == null
          ? true
          : sub.subscriptionId == subscriptionId;
      if (matchesDevice && matchesToken && matchesId) {
        removed = sub;
        continue;
      }
      updated.add(sub);
    }

    if (removed != null) {
      state = AsyncData(updated);
      await _save(updated);
      developer.log(
        'Unsubscribed noise token device=${peer.remoteDeviceId} '
        'fp=${shortFingerprint(peer.certFingerprint)}',
        name: 'noise_sub',
      );
    }
    return removed;
  }

  Future<void> clearForFingerprint(String fingerprint) async {
    final current = await _ensureValue();
    final updated = current
        .where((s) => s.certFingerprint != fingerprint)
        .toList();
    if (updated.length == current.length) return;
    state = AsyncData(updated);
    await _save(updated);
    developer.log(
      'Cleared noise subscriptions for fp=${shortFingerprint(fingerprint)}',
      name: 'noise_sub',
    );
  }

  Future<void> clearByTokens(Iterable<String> tokens) async {
    final tokenSet = tokens.toSet();
    if (tokenSet.isEmpty) return;
    final current = await _ensureValue();
    final updated = current
        .where((s) => !tokenSet.contains(s.fcmToken))
        .toList();
    if (updated.length == current.length) return;
    state = AsyncData(updated);
    await _save(updated);
    developer.log(
      'Cleared ${current.length - updated.length} invalid noise tokens',
      name: 'noise_sub',
    );
  }

  Future<void> removeExpired({DateTime? now}) async {
    final clock = now ?? DateTime.now();
    final current = await _ensureValue();
    final updated = current.where((s) => !s.isExpired(clock)).toList();
    if (updated.length == current.length) return;
    state = AsyncData(updated);
    await _save(updated);
  }

  List<NoiseSubscription> active({DateTime? now}) {
    final clock = now ?? DateTime.now();
    final data = state.asData?.value ?? [];
    return data.where((s) => !s.isExpired(clock)).toList();
  }

  /// Returns the minimum threshold across all active subscriptions.
  /// Returns null if there are no active subscriptions with custom thresholds.
  int? minimumThreshold({DateTime? now}) {
    final subs = active(now: now);
    if (subs.isEmpty) return null;

    int? minThreshold;
    for (final sub in subs) {
      final threshold = sub.threshold;
      if (threshold != null) {
        minThreshold =
            minThreshold == null ? threshold : min(minThreshold, threshold);
      }
    }
    return minThreshold;
  }

  Future<List<NoiseSubscription>> _ensureValue() async {
    final current = state.asData?.value;
    if (current != null) return current;
    final repo = ref.read(noiseSubscriptionsRepoProvider);
    final loaded = await repo.load();
    state = AsyncData(loaded);
    return loaded;
  }

  Future<void> _save(List<NoiseSubscription> updated) async {
    await ref.read(noiseSubscriptionsRepoProvider).save(updated);
  }

  int _clampLeaseSeconds(int? leaseSeconds) {
    if (leaseSeconds == null || leaseSeconds <= 0) {
      return kNoiseSubscriptionDefaultLease.inSeconds;
    }
    return leaseSeconds.clamp(1, kNoiseSubscriptionMaxLease.inSeconds);
  }
}

class TrustedListenersController extends AsyncNotifier<List<TrustedPeer>> {
  @override
  Future<List<TrustedPeer>> build() async {
    final repo = ref.read(trustedListenersRepoProvider);
    return repo.load();
  }

  Future<void> addListener(TrustedPeer peer) async {
    final current = await _ensureValue();
    if (current.any((p) => p.remoteDeviceId == peer.remoteDeviceId)) return;
    final updated = [...current, peer];
    state = AsyncData(updated);
    await ref.read(trustedListenersRepoProvider).save(updated);
  }

  Future<void> revoke(String deviceId) async {
    final current = await _ensureValue();
    TrustedPeer? removed;
    for (final listener in current) {
      if (listener.remoteDeviceId == deviceId) {
        removed = listener;
        break;
      }
    }
    final updated = current
        .where((listener) => listener.remoteDeviceId != deviceId)
        .toList();
    state = AsyncData(updated);
    await ref.read(trustedListenersRepoProvider).save(updated);
    if (removed != null) {
      await ref
          .read(noiseSubscriptionsProvider.notifier)
          .clearForFingerprint(removed.certFingerprint);
    }
  }

  /// Update FCM token for a listener (called when listener sends FCM_TOKEN_UPDATE).
  Future<void> updateFcmToken(String deviceId, String fcmToken) async {
    final current = await _ensureValue();
    final index = current.indexWhere((p) => p.remoteDeviceId == deviceId);
    if (index == -1) {
      developer.log(
        'Cannot update FCM token: listener $deviceId not found',
        name: 'fcm',
      );
      return;
    }

    final updated = [...current];
    updated[index] = current[index].copyWith(fcmToken: fcmToken);
    state = AsyncData(updated);
    await ref.read(trustedListenersRepoProvider).save(updated);
    developer.log('Updated FCM token for listener $deviceId', name: 'fcm');
  }

  /// Clear FCM token for listeners with matching token (called when token is invalid).
  Future<void> clearFcmTokenByToken(String fcmToken) async {
    final current = await _ensureValue();
    final index = current.indexWhere((p) => p.fcmToken == fcmToken);
    if (index == -1) return;

    final updated = [...current];
    updated[index] = current[index].clearFcmToken();
    state = AsyncData(updated);
    await ref.read(trustedListenersRepoProvider).save(updated);
    developer.log(
      'Cleared invalid FCM token for listener ${current[index].remoteDeviceId}',
      name: 'fcm',
    );
  }

  Future<List<TrustedPeer>> _ensureValue() async {
    final current = state.asData?.value;
    if (current != null) return current;
    final repo = ref.read(trustedListenersRepoProvider);
    final loaded = await repo.load();
    state = AsyncData(loaded);
    return loaded;
  }
}

class TrustedMonitorsController extends AsyncNotifier<List<TrustedMonitor>> {
  @override
  Future<List<TrustedMonitor>> build() async {
    final repo = ref.read(trustedMonitorsRepoProvider);
    return repo.load();
  }

  Future<void> addMonitor(
    MonitorQrPayload payload, {
    String? lastKnownIp,
    List<int>? certificateDer,
  }) async {
    final current = await _ensureValue();
    if (current.any((m) => m.remoteDeviceId == payload.remoteDeviceId)) return;
    // Use first IP from QR payload as lastKnownIp if not explicitly provided
    final effectiveLastKnownIp = lastKnownIp ?? payload.ips?.firstOrNull;
    final updated = [
      ...current,
      TrustedMonitor(
        remoteDeviceId: payload.remoteDeviceId,
        monitorName: payload.monitorName,
        certFingerprint: payload.certFingerprint,
        controlPort: payload.service.controlPort,
        pairingPort: payload.service.pairingPort,
        serviceVersion: payload.service.version,
        transport: payload.service.transport,
        lastKnownIp: effectiveLastKnownIp,
        knownIps: payload.ips,
        addedAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        certificateDer: certificateDer,
      ),
    ];
    state = AsyncData(updated);
    await ref.read(trustedMonitorsRepoProvider).save(updated);
  }

  Future<void> removeMonitor(String remoteDeviceId) async {
    final current = await _ensureValue();
    final updated = current
        .where((monitor) => monitor.remoteDeviceId != remoteDeviceId)
        .toList();
    state = AsyncData(updated);
    await ref.read(trustedMonitorsRepoProvider).save(updated);
  }

  Future<void> updateLastKnownIp(MdnsAdvertisement advertisement) async {
    if (advertisement.ip == null) return;
    final current = await _ensureValue();
    final index = current.indexWhere(
      (monitor) => monitor.remoteDeviceId == advertisement.remoteDeviceId,
    );
    if (index == -1) return;
    final existing = current[index];
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // Always update lastSeenEpochMs when we see the monitor via mDNS
    final updated = [...current];
    updated[index] = TrustedMonitor(
      remoteDeviceId: existing.remoteDeviceId,
      monitorName: existing.monitorName,
      certFingerprint: existing.certFingerprint,
      lastKnownIp: advertisement.ip ?? existing.lastKnownIp,
      lastNoiseEpochMs: existing.lastNoiseEpochMs,
      lastSeenEpochMs: nowMs,
      controlPort: advertisement.controlPort,
      pairingPort: advertisement.pairingPort,
      serviceVersion: advertisement.version,
      transport: advertisement.transport,
      addedAtEpochSec: existing.addedAtEpochSec,
    );
    state = AsyncData(updated);
    await ref.read(trustedMonitorsRepoProvider).save(updated);
  }

  Future<void> recordNoiseEvent({
    required String remoteDeviceId,
    required int timestampMs,
  }) async {
    final current = await _ensureValue();
    final index = current.indexWhere(
      (monitor) => monitor.remoteDeviceId == remoteDeviceId,
    );
    if (index == -1) return;
    final existing = current[index];
    final updated = [...current];
    updated[index] = TrustedMonitor(
      remoteDeviceId: existing.remoteDeviceId,
      monitorName: existing.monitorName,
      certFingerprint: existing.certFingerprint,
      lastKnownIp: existing.lastKnownIp,
      lastNoiseEpochMs: timestampMs,
      lastSeenEpochMs: existing.lastSeenEpochMs,
      controlPort: existing.controlPort,
      pairingPort: existing.pairingPort,
      serviceVersion: existing.serviceVersion,
      transport: existing.transport,
      addedAtEpochSec: existing.addedAtEpochSec,
    );
    state = AsyncData(updated);
    await ref.read(trustedMonitorsRepoProvider).save(updated);
  }

  Future<List<TrustedMonitor>> _ensureValue() async {
    final current = state.asData?.value;
    if (current != null) return current;
    final repo = ref.read(trustedMonitorsRepoProvider);
    final loaded = await repo.load();
    state = AsyncData(loaded);
    return loaded;
  }
}

final trustedMonitorsProvider =
    AsyncNotifierProvider<TrustedMonitorsController, List<TrustedMonitor>>(
      TrustedMonitorsController.new,
    );
final noiseSubscriptionsProvider =
    AsyncNotifierProvider<
      NoiseSubscriptionsController,
      List<NoiseSubscription>
    >(NoiseSubscriptionsController.new);
final trustedListenersProvider =
    AsyncNotifierProvider<TrustedListenersController, List<TrustedPeer>>(
      TrustedListenersController.new,
    );

class _SeenAdvertisement {
  _SeenAdvertisement({required this.advertisement, required this.seenAt});

  final MdnsAdvertisement advertisement;
  final DateTime seenAt;
}

final mdnsBrowseProvider = StreamProvider.autoDispose<List<MdnsAdvertisement>>((
  ref,
) {
  debugPrint('[mdns_provider] mdnsBrowseProvider initializing...');
  final mdns = ref.watch(mdnsServiceProvider);
  debugPrint(
    '[mdns_provider] mdnsBrowseProvider got MdnsService: ${mdns.runtimeType}',
  );
  final controller = StreamController<List<MdnsAdvertisement>>();
  final seen = <String, _SeenAdvertisement>{};
  const ttl = Duration(seconds: 45);

  void emit() {
    controller.add(seen.values.map((e) => e.advertisement).toList());
  }

  void upsert(MdnsAdvertisement ad) {
    seen[ad.remoteDeviceId] = _SeenAdvertisement(
      advertisement: ad,
      seenAt: DateTime.now(),
    );
    emit();
  }

  void remove(String remoteDeviceId) {
    if (seen.remove(remoteDeviceId) != null) {
      emit();
    }
  }

  debugPrint('[mdns_provider] Subscribing to mdns.browse() stream...');
  final browseStream = mdns.browse();
  debugPrint('[mdns_provider] Got browse stream, now listening...');
  final subscription = browseStream.listen((event) {
    debugPrint(
      '[mdns_provider] received: ${event.isOnline ? "ONLINE" : "OFFLINE"} '
      'remoteDeviceId=${event.advertisement.remoteDeviceId} ip=${event.advertisement.ip} '
      'seenCount=${seen.length}',
    );
    if (event.isOnline) {
      if (event.advertisement.ip != null) {
        unawaited(
          ref
              .read(trustedMonitorsProvider.notifier)
              .updateLastKnownIp(event.advertisement),
        );
      }
      upsert(event.advertisement);
      debugPrint(
        '[mdns_provider] Upserted ${event.advertisement.remoteDeviceId}, seenCount=${seen.length}',
      );
    } else {
      // Service went offline
      final removed = seen.containsKey(event.advertisement.remoteDeviceId);
      remove(event.advertisement.remoteDeviceId);
      debugPrint(
        '[mdns_provider] Removed ${event.advertisement.remoteDeviceId}, wasPresent=$removed, '
        'seenCount=${seen.length}',
      );
    }
  }, onError: controller.addError);

  final ticker = Timer.periodic(const Duration(seconds: 5), (_) {
    final now = DateTime.now();
    final staleKeys = seen.entries
        .where((entry) => now.difference(entry.value.seenAt) > ttl)
        .map((entry) => entry.key)
        .toList();
    if (staleKeys.isEmpty) return;
    for (final key in staleKeys) {
      seen.remove(key);
    }
    emit();
  });

  // Emit initial empty state so listeners render quickly.
  emit();

  ref.onDispose(() {
    ticker.cancel();
    subscription.cancel();
    controller.close();
  });

  return controller.stream;
});

final discoveredMonitorsProvider = Provider<List<MdnsAdvertisement>>((ref) {
  final browse = ref
      .watch(mdnsBrowseProvider)
      .maybeWhen(data: (list) => list, orElse: () => <MdnsAdvertisement>[]);

  // Filter out our own device to avoid discovering ourselves
  final identity = ref.watch(identityProvider);
  final localDeviceId = identity.maybeWhen(
    data: (id) => id.deviceId,
    orElse: () => null,
  );
  if (localDeviceId == null) return browse;

  return browse
      .where((ad) => ad.remoteDeviceId != localDeviceId)
      .toList();
});

class IdentityController extends AsyncNotifier<DeviceIdentity> {
  late final IdentityStore _store;

  @override
  Future<DeviceIdentity> build() async {
    _store = IdentityStore.create();
    final repo = IdentityRepository(store: _store);
    return repo.loadOrCreate();
  }

  /// Deletes the current identity and regenerates a new one.
  /// WARNING: This will break all existing pairings - devices will need to re-pair.
  Future<void> regenerate() async {
    state = const AsyncLoading();
    try {
      // Delete stored identity
      await _store.delete();

      // Generate new identity
      final repo = IdentityRepository(store: _store);
      final newIdentity = await repo.loadOrCreate();

      state = AsyncData(newIdentity);
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }
}

final pairingSessionProvider =
    NotifierProvider<PairingController, PairingSessionState?>(
      PairingController.new,
    );

// ---------------------------------------------------------------------------
// FCM (Firebase Cloud Messaging) providers
// ---------------------------------------------------------------------------

/// Singleton FCM service instance.
final fcmServiceProvider = Provider<FcmService>((ref) {
  return FcmService.instance;
});

/// State for noise event deduplication.
/// Tracks recently seen events to avoid duplicate notifications when
/// receiving the same event via both WebSocket and FCM.
class NoiseEventDeduplicationState {
  const NoiseEventDeduplicationState({
    this.lastEvent,
    this.recentEventIds = const {},
  });

  final NoiseEventData? lastEvent;
  final Set<String> recentEventIds;

  NoiseEventDeduplicationState copyWith({
    NoiseEventData? lastEvent,
    Set<String>? recentEventIds,
  }) {
    return NoiseEventDeduplicationState(
      lastEvent: lastEvent ?? this.lastEvent,
      recentEventIds: recentEventIds ?? this.recentEventIds,
    );
  }
}

/// Controller for deduplicating noise events received via multiple channels.
class NoiseEventDeduplicationController
    extends Notifier<NoiseEventDeduplicationState> {
  static const _maxEventIds = 100;

  @override
  NoiseEventDeduplicationState build() => const NoiseEventDeduplicationState();

  /// Process a noise event. Returns true if new, false if duplicate.
  bool processEvent(NoiseEventData event) {
    final eventId = event.eventId;

    if (state.recentEventIds.contains(eventId)) {
      developer.log('Duplicate noise event ignored: $eventId', name: 'fcm');
      return false;
    }

    // Add to recent IDs, pruning if necessary
    var newIds = {...state.recentEventIds, eventId};
    if (newIds.length > _maxEventIds) {
      // Remove oldest entries (arbitrary since Set is unordered, but good enough)
      newIds = newIds.skip(newIds.length - _maxEventIds).toSet();
    }

    state = NoiseEventDeduplicationState(
      lastEvent: event,
      recentEventIds: newIds,
    );

    developer.log(
      'New noise event processed: $eventId (${newIds.length} cached)',
      name: 'fcm',
    );
    return true;
  }

  /// Check if an event ID has been seen recently (for WebSocket events).
  bool isEventSeen(String remoteDeviceId, int timestamp) {
    return state.recentEventIds.contains('$remoteDeviceId-$timestamp');
  }

  /// Mark an event as seen (for WebSocket events before FCM arrives).
  void markEventSeen(String remoteDeviceId, int timestamp) {
    final eventId = '$remoteDeviceId-$timestamp';
    if (state.recentEventIds.contains(eventId)) return;

    var newIds = {...state.recentEventIds, eventId};
    if (newIds.length > _maxEventIds) {
      newIds = newIds.skip(newIds.length - _maxEventIds).toSet();
    }
    state = state.copyWith(recentEventIds: newIds);
  }
}

final noiseEventDeduplicationProvider =
    NotifierProvider<
      NoiseEventDeduplicationController,
      NoiseEventDeduplicationState
    >(NoiseEventDeduplicationController.new);
