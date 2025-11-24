import 'dart:async';
import 'dart:io';

import 'package:cribcall/src/domain/models.dart';
import 'package:cribcall/src/discovery/mdns_service.dart';
import 'package:cribcall/src/state/app_state.dart';
import 'package:cribcall/src/storage/settings_repository.dart';
import 'package:cribcall/src/storage/trusted_monitors_repository.dart';
import 'package:cribcall/src/pairing/pin_pairing_controller.dart';
import 'package:cribcall/src/identity/device_identity.dart';
import 'package:cribcall/src/pairing/pake_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('role controller switches roles and resets', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(roleProvider), isNull);
    container.read(roleProvider.notifier).select(DeviceRole.monitor);
    expect(container.read(roleProvider), DeviceRole.monitor);
    container.read(roleProvider.notifier).reset();
    expect(container.read(roleProvider), isNull);
  });

  test('monitor settings defaults align with spec baseline', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(monitorSettingsProvider.future);
    expect(settings.noise.threshold, 60);
    expect(settings.autoStreamType, AutoStreamType.audio);
    expect(settings.autoStreamDurationSec, 15);
  });

  test('monitor settings controller updates and persists name', () async {
    final tempDir = await Directory.systemTemp.createTemp('monitor_settings');
    final container = ProviderContainer(
      overrides: [
        monitorSettingsRepoProvider.overrideWithValue(
          MonitorSettingsRepository(overrideDirectoryPath: tempDir.path),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await tempDir.delete(recursive: true);
    });

    await container.read(monitorSettingsProvider.future);
    await container.read(monitorSettingsProvider.notifier).setName('Crib Cam');
    final updated = container.read(monitorSettingsProvider).value!;
    expect(updated.name, 'Crib Cam');

    final repo = MonitorSettingsRepository(overrideDirectoryPath: tempDir.path);
    final reloaded = await repo.load();
    expect(reloaded.name, 'Crib Cam');
  });

  test('monitoring status toggles', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(monitoringStatusProvider), isTrue);
    container.read(monitoringStatusProvider.notifier).toggle(false);
    expect(container.read(monitoringStatusProvider), isFalse);
  });

  test('mdns browse provider deduplicates', () async {
    final controller = StreamController<MdnsAdvertisement>();
    final container = ProviderContainer(
      overrides: [
        mdnsServiceProvider.overrideWithValue(
          _FakeMdnsService(controller.stream),
        ),
      ],
    );
    addTearDown(() => container.dispose());

    final completer = Completer<List<MdnsAdvertisement>>();
    container.listen(mdnsBrowseProvider, (prev, next) {
      if (next.hasValue) {
        completer.complete(next.value!);
      }
    });

    controller.add(
      const MdnsAdvertisement(
        monitorId: 'm1',
        monitorName: 'Nursery',
        monitorCertFingerprint: 'fp1',
        servicePort: 48080,
        version: 1,
      ),
    );
    controller.add(
      const MdnsAdvertisement(
        monitorId: 'm1',
        monitorName: 'Nursery',
        monitorCertFingerprint: 'fp1',
        servicePort: 48080,
        version: 1,
      ),
    );
    await controller.close();

    final list = await completer.future.timeout(const Duration(seconds: 2));
    expect(list.length, 1);
  });

  test(
    'trusted monitors controller persists last known IP and removals',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('trusted_monitors');
      final container = ProviderContainer(
        overrides: [
          trustedMonitorsRepoProvider.overrideWithValue(
            TrustedMonitorsRepository(overrideDirectoryPath: tempDir.path),
          ),
          pakeEngineProvider.overrideWithValue(_FakePakeEngine()),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await tempDir.delete(recursive: true);
      });

      await container.read(trustedMonitorsProvider.future);
      const payload = MonitorQrPayload(
        monitorId: 'm1',
        monitorName: 'Nursery',
        monitorCertFingerprint: 'fp1',
        service: QrServiceInfo(
          protocol: 'baby-monitor',
          version: 1,
          defaultPort: 48080,
        ),
      );
      await container
          .read(trustedMonitorsProvider.notifier)
          .addMonitor(payload);

      await container
          .read(trustedMonitorsProvider.notifier)
          .updateLastKnownIp(
            const MdnsAdvertisement(
              monitorId: 'm1',
              monitorName: 'Nursery',
              monitorCertFingerprint: 'fp1',
              servicePort: 48080,
              version: 1,
              ip: '192.168.1.10',
            ),
          );

      final afterUpdate = container.read(trustedMonitorsProvider).value!;
      expect(afterUpdate.single.lastKnownIp, '192.168.1.10');

      await container
          .read(trustedMonitorsProvider.notifier)
          .removeMonitor('m1');
      final cleared = container.read(trustedMonitorsProvider).value!;
      expect(cleared, isEmpty);
    },
  );

  test(
    'pin session lifecycle accepts correct pin and rejects bad pin',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('pin_test');
      final container = ProviderContainer(
        overrides: [
          trustedMonitorsRepoProvider.overrideWithValue(
            TrustedMonitorsRepository(overrideDirectoryPath: tempDir.path),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await tempDir.delete(recursive: true);
      });

      final monitorIdentity = await DeviceIdentity.generate();
      final listenerIdentity = await DeviceIdentity.generate();
      final pinMessage = await container
          .read(pinSessionProvider.notifier)
          .startSession(monitorIdentity);
      expect(pinMessage.maxAttempts, greaterThan(0));

      final ad = MdnsAdvertisement(
        monitorId: monitorIdentity.deviceId,
        monitorName: 'Nursery',
        monitorCertFingerprint: monitorIdentity.certFingerprint,
        servicePort: 48080,
        version: 1,
      );

      final failResult = await container
          .read(pinSessionProvider.notifier)
          .submitPin(
            pairingSessionId: pinMessage.pairingSessionId,
            pin: '000000',
            advertisement: ad,
            listenerIdentity: listenerIdentity,
            listenerName: 'Listener',
          );
      expect(failResult.success, isFalse);

      final successResult = await container
          .read(pinSessionProvider.notifier)
          .submitPin(
            pairingSessionId: pinMessage.pairingSessionId,
            pin: container.read(pinSessionProvider)!.pin,
            advertisement: ad,
            listenerIdentity: listenerIdentity,
            listenerName: 'Listener',
          );
      expect(successResult.success, isTrue);
    },
  );
}

class _FakeMdnsService implements MdnsService {
  _FakeMdnsService(this.stream);
  final Stream<MdnsAdvertisement> stream;

  @override
  Stream<MdnsAdvertisement> browse() => stream;

  @override
  Future<void> startAdvertise(MdnsAdvertisement advertisement) async {}

  @override
  Future<void> stop() async {}
}

class _FakePakeEngine implements PakeEngine {
  @override
  Future<PakeResponse> respond({
    required String pin,
    required String pakeMsgA,
  }) async {
    return const PakeResponse(pakeMsgB: 'msgB', pairingKey: [1, 2, 3, 4]);
  }

  @override
  Future<PakeStart> start({required String pin}) async {
    return const PakeStart(pakeMsgA: 'msgA');
  }
}
