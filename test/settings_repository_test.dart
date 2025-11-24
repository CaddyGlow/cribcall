import 'dart:io';

import 'package:cribcall/src/domain/models.dart';
import 'package:cribcall/src/storage/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('monitor settings repository persists updates', () async {
    final dir = await Directory.systemTemp.createTemp('monitor_settings');
    addTearDown(() async => dir.delete(recursive: true));
    final repo = MonitorSettingsRepository(overrideDirectoryPath: dir.path);

    final defaults = await repo.load();
    expect(defaults.name, MonitorSettings.defaults.name);
    expect(defaults.noise.threshold, MonitorSettings.defaults.noise.threshold);

    final updated = defaults.copyWith(
      name: 'Nursery 2',
      noise: defaults.noise.copyWith(threshold: 72),
      autoStreamType: AutoStreamType.audioVideo,
      autoStreamDurationSec: 30,
    );
    await repo.save(updated);

    final roundTrip = await repo.load();
    expect(roundTrip.name, 'Nursery 2');
    expect(roundTrip.noise.threshold, 72);
    expect(roundTrip.autoStreamType, AutoStreamType.audioVideo);
    expect(roundTrip.autoStreamDurationSec, 30);
  });

  test('listener settings repository persists updates', () async {
    final dir = await Directory.systemTemp.createTemp('listener_settings');
    addTearDown(() async => dir.delete(recursive: true));
    final repo = ListenerSettingsRepository(overrideDirectoryPath: dir.path);

    final defaults = await repo.load();
    expect(defaults.notificationsEnabled, isTrue);

    final updated = defaults.copyWith(
      notificationsEnabled: false,
      defaultAction: ListenerDefaultAction.autoOpenStream,
    );
    await repo.save(updated);

    final roundTrip = await repo.load();
    expect(roundTrip.notificationsEnabled, isFalse);
    expect(roundTrip.defaultAction, ListenerDefaultAction.autoOpenStream);
  });
}
