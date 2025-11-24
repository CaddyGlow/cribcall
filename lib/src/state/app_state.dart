import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../discovery/mdns_service.dart';
import '../identity/device_identity.dart';
import '../identity/identity_repository.dart';
import '../identity/identity_store.dart';
import '../identity/service_identity.dart';
import '../storage/trusted_monitors_repository.dart';

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

class MonitorSettingsController extends Notifier<MonitorSettings> {
  @override
  MonitorSettings build() => const MonitorSettings(
    name: 'Nursery',
    noise: NoiseSettings(threshold: 60, minDurationMs: 800, cooldownSeconds: 8),
    autoStreamType: AutoStreamType.audio,
    autoStreamDurationSec: 15,
  );

  void setNoise(NoiseSettings noise) => state = state.copyWith(noise: noise);

  void setAutoStreamDuration(int seconds) =>
      state = state.copyWith(autoStreamDurationSec: seconds);

  void toggleAutoStreamType() {
    final next = switch (state.autoStreamType) {
      AutoStreamType.none => AutoStreamType.audio,
      AutoStreamType.audio => AutoStreamType.audioVideo,
      AutoStreamType.audioVideo => AutoStreamType.none,
    };
    state = state.copyWith(autoStreamType: next);
  }
}

class ListenerSettingsController extends Notifier<ListenerSettings> {
  @override
  ListenerSettings build() => const ListenerSettings(
    notificationsEnabled: true,
    defaultAction: ListenerDefaultAction.notify,
  );

  void toggleNotifications() =>
      state = state.copyWith(notificationsEnabled: !state.notificationsEnabled);

  void setDefaultAction(ListenerDefaultAction action) =>
      state = state.copyWith(defaultAction: action);
}

final roleProvider = NotifierProvider<RoleController, DeviceRole?>(
  RoleController.new,
);
final monitoringStatusProvider =
    NotifierProvider<MonitoringStatusController, bool>(
      MonitoringStatusController.new,
    );
final monitorSettingsProvider =
    NotifierProvider<MonitorSettingsController, MonitorSettings>(
      MonitorSettingsController.new,
    );
final listenerSettingsProvider =
    NotifierProvider<ListenerSettingsController, ListenerSettings>(
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
  );
});
final mdnsServiceProvider = Provider<MdnsService>((ref) {
  return MethodChannelMdnsService();
});
final trustedMonitorsRepoProvider = Provider<TrustedMonitorsRepository>((ref) {
  return TrustedMonitorsRepository();
});

class TrustedMonitorsController extends AsyncNotifier<List<TrustedMonitor>> {
  @override
  Future<List<TrustedMonitor>> build() async {
    final repo = ref.read(trustedMonitorsRepoProvider);
    return repo.load();
  }

  Future<void> addMonitor(MonitorQrPayload payload) async {
    final current = state.value ?? [];
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
}

final trustedMonitorsProvider =
    AsyncNotifierProvider<TrustedMonitorsController, List<TrustedMonitor>>(
        TrustedMonitorsController.new);

final trustedPeersProvider = Provider<List<TrustedPeer>>((ref) {
  return const [
    TrustedPeer(
      deviceId: 'listener-1',
      name: 'Dad’s Phone',
      certFingerprint: 'c3:1a:04:fa:9d',
      addedAtEpochSec: 1700000000,
    ),
    TrustedPeer(
      deviceId: 'desktop-1',
      name: 'Desktop',
      certFingerprint: '77:de:aa:14:21',
      addedAtEpochSec: 1705000000,
    ),
  ];
});

final discoveredMonitorsProvider = Provider<List<MdnsAdvertisement>>((ref) {
  return const [
    MdnsAdvertisement(
      monitorId: 'monitor-1',
      monitorName: 'Nursery',
      monitorCertFingerprint: '7f:91:2c:...:de',
      servicePort: 48080,
      version: 1,
    ),
    MdnsAdvertisement(
      monitorId: 'monitor-2',
      monitorName: 'Guest room',
      monitorCertFingerprint: 'bb:01:44:...:9a',
      servicePort: 48080,
      version: 1,
    ),
  ];
});

class IdentityController extends AsyncNotifier<DeviceIdentity> {
  @override
  Future<DeviceIdentity> build() async {
    final store = IdentityStore.create();
    final repo = IdentityRepository(store: store);
    return repo.loadOrCreate();
  }
}
