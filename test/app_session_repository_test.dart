import 'dart:io';

import 'package:cribcall/src/storage/app_session_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'resolveDefaultDeviceName prefers Android device name over localhost',
    () async {
      final name = await resolveDefaultDeviceName(
        hostnameGetter: () => 'localhost',
        androidResolver: () async => 'Pixel 9',
        isAndroidOverride: true,
      );
      expect(name, 'Pixel 9');
    },
  );

  test(
    'resolveDefaultDeviceName falls back to Android label when hostname is empty',
    () async {
      final name = await resolveDefaultDeviceName(
        hostnameGetter: () => '',
        androidResolver: () async => null,
        isAndroidOverride: true,
      );
      expect(name, 'Android device');
    },
  );

  test(
    'AppSessionRepository replaces localhost defaults with resolved name',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('app_session_repo');
      addTearDown(() => tempDir.delete(recursive: true));

      final repo = AppSessionRepository(
        overrideDirectoryPath: tempDir.path,
        deviceNameResolver: () async => 'Pixel 9',
        isAndroidOverride: true,
      );

      final file = File('${tempDir.path}/app_session.json');
      await file.create(recursive: true);
      await file.writeAsString('{"deviceName": "localhost"}');

      final loaded = await repo.load();
      expect(loaded.deviceName, 'Pixel 9');
    },
  );
}
