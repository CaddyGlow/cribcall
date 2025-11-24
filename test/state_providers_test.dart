import 'package:cribcall/src/domain/models.dart';
import 'package:cribcall/src/state/app_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('role controller switches roles and resets', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(roleProvider), isNull);
    container.read(roleProvider.notifier).select(DeviceRole.monitor);
    expect(container.read(roleProvider), DeviceRole.monitor);
    container.read(roleProvider.notifier).reset();
    expect(container.read(roleProvider), isNull);
  });

  test('monitor settings defaults align with spec baseline', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = container.read(monitorSettingsProvider);
    expect(settings.noise.threshold, 60);
    expect(settings.autoStreamType, AutoStreamType.audio);
    expect(settings.autoStreamDurationSec, 15);
  });

  test('monitoring status toggles', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(monitoringStatusProvider), isTrue);
    container.read(monitoringStatusProvider.notifier).toggle(false);
    expect(container.read(monitoringStatusProvider), isFalse);
  });
}
