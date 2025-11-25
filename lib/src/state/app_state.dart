import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';

import '../config/build_flags.dart';
import '../domain/models.dart';
import '../discovery/mdns_service.dart';
import '../identity/device_identity.dart';
import '../identity/identity_repository.dart';
import '../identity/identity_store.dart';
import '../identity/service_identity.dart';
import '../pairing/pake_engine.dart';
import '../pairing/pin_pairing_controller.dart';
import '../storage/settings_repository.dart';
import '../storage/trusted_listeners_repository.dart';
import '../storage/trusted_monitors_repository.dart';
import '../control/control_service.dart';

class RoleController extends Notifier<DeviceRole?> {
  @override
  DeviceRole? build() => null;

  void select(DeviceRole role) => state = role;

  void reset() => state = null;
}

class MonitoringStatusController extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle(bool value) => state = value;
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

  Future<void> setName(String name) =>
      _updateAndPersist((current) => current.copyWith(name: name));

  Future<void> setAutoStreamType(AutoStreamType type) =>
      _updateAndPersist((current) => current.copyWith(autoStreamType: type));

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
    defaultPort: 48080,
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
final pakeEngineProvider = Provider<PakeEngine>((ref) {
  return X25519PakeEngine();
});
final controlTransportsProvider = Provider<ControlTransports>((ref) {
  return ControlTransports.create();
});
final controlServerProvider =
    NotifierProvider<ControlServerController, ControlServerState>(
      ControlServerController.new,
    );
final controlClientProvider =
    NotifierProvider<ControlClientController, ControlClientState>(
      ControlClientController.new,
    );
final controlServerAutoStartProvider = Provider<void>((ref) {
  final monitoringEnabled = ref.watch(monitoringStatusProvider);
  final identity = ref.watch(identityProvider);
  final trustedListeners = ref.watch(trustedListenersProvider);
  final builder = ref.watch(serviceIdentityProvider);

  Future.microtask(() async {
    if (!monitoringEnabled ||
        !identity.hasValue ||
        !trustedListeners.hasValue) {
      await ref.read(controlServerProvider.notifier).stop();
      return;
    }

    final trustedFingerprints = trustedListeners.requireValue
        .map((p) => p.certFingerprint)
        .toList();
    await ref
        .read(controlServerProvider.notifier)
        .start(
          identity: identity.requireValue,
          port: builder.defaultPort,
          trustedFingerprints: trustedFingerprints,
        );
  });
});

class TrustedListenersController extends AsyncNotifier<List<TrustedPeer>> {
  @override
  Future<List<TrustedPeer>> build() async {
    final repo = ref.read(trustedListenersRepoProvider);
    return repo.load();
  }

  Future<void> addListener(TrustedPeer peer) async {
    final current = await _ensureValue();
    if (current.any((p) => p.deviceId == peer.deviceId)) return;
    final updated = [...current, peer];
    state = AsyncData(updated);
    await ref.read(trustedListenersRepoProvider).save(updated);
  }

  Future<void> revoke(String deviceId) async {
    final current = await _ensureValue();
    final updated = current
        .where((listener) => listener.deviceId != deviceId)
        .toList();
    state = AsyncData(updated);
    await ref.read(trustedListenersRepoProvider).save(updated);
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

  Future<void> addMonitor(MonitorQrPayload payload) async {
    final current = await _ensureValue();
    if (current.any((m) => m.monitorId == payload.monitorId)) return;
    final updated = [
      ...current,
      TrustedMonitor(
        monitorId: payload.monitorId,
        monitorName: payload.monitorName,
        certFingerprint: payload.monitorCertFingerprint,
        addedAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    ];
    state = AsyncData(updated);
    await ref.read(trustedMonitorsRepoProvider).save(updated);
  }

  Future<void> removeMonitor(String monitorId) async {
    final current = await _ensureValue();
    final updated = current
        .where((monitor) => monitor.monitorId != monitorId)
        .toList();
    state = AsyncData(updated);
    await ref.read(trustedMonitorsRepoProvider).save(updated);
  }

  Future<void> updateLastKnownIp(MdnsAdvertisement advertisement) async {
    if (advertisement.ip == null) return;
    final current = await _ensureValue();
    final index = current.indexWhere(
      (monitor) => monitor.monitorId == advertisement.monitorId,
    );
    if (index == -1) return;
    final existing = current[index];
    if (existing.lastKnownIp == advertisement.ip) return;
    final updated = [...current];
    updated[index] = TrustedMonitor(
      monitorId: existing.monitorId,
      monitorName: existing.monitorName,
      certFingerprint: existing.certFingerprint,
      lastKnownIp: advertisement.ip,
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
  final mdns = ref.watch(mdnsServiceProvider);
  final controller = StreamController<List<MdnsAdvertisement>>();
  final seen = <String, _SeenAdvertisement>{};
  const ttl = Duration(seconds: 45);

  void emit() {
    controller.add(seen.values.map((e) => e.advertisement).toList());
  }

  void upsert(MdnsAdvertisement ad) {
    seen[ad.monitorId] = _SeenAdvertisement(
      advertisement: ad,
      seenAt: DateTime.now(),
    );
    emit();
  }

  final subscription = mdns.browse().listen((event) {
    if (event.ip != null) {
      unawaited(
        ref.read(trustedMonitorsProvider.notifier).updateLastKnownIp(event),
      );
    }
    upsert(event);
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
  return browse;
});

class IdentityController extends AsyncNotifier<DeviceIdentity> {
  @override
  Future<DeviceIdentity> build() async {
    final store = IdentityStore.create();
    final repo = IdentityRepository(store: store);
    return repo.loadOrCreate();
  }
}

final pinSessionProvider =
    NotifierProvider<PinPairingController, PinSessionState?>(
      PinPairingController.new,
    );
