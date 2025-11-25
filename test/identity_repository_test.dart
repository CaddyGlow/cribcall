import 'dart:convert';
import 'dart:io';

import 'package:cribcall/src/identity/identity_repository.dart';
import 'package:cribcall/src/identity/identity_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IdentityRepository', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('identity_repo_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('creates and persists P-256 identity', () async {
      final store = FileIdentityStore(overrideDirectoryPath: tempDir.path);
      final repo = IdentityRepository(store: store);

      final identity1 = await repo.loadOrCreate();

      final file = File('${tempDir.path}/identity.json');
      expect(file.existsSync(), isTrue);

      final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(decoded['deviceId'], isNotEmpty);
      expect(decoded['privateKey'], isNotEmpty);
      expect(decoded['publicKey'], isNotEmpty);
      expect(decoded['certificateDer'], isNotEmpty);
      expect(decoded['certFingerprint'], equals(identity1.certFingerprint));

      final privateKey = base64Decode(decoded['privateKey'] as String);
      final publicKey = base64Decode(decoded['publicKey'] as String);
      expect(privateKey.length, 32);
      expect(publicKey.length, 65);
      expect(publicKey.first, 0x04);
    });

    test('reloads persisted identity without regenerating', () async {
      final store = FileIdentityStore(overrideDirectoryPath: tempDir.path);
      final repo = IdentityRepository(store: store);

      final identity1 = await repo.loadOrCreate();
      final identity2 = await repo.loadOrCreate();

      expect(identity2.deviceId, identity1.deviceId);
      expect(identity2.certFingerprint, identity1.certFingerprint);
      expect(identity2.publicKey.bytes, identity1.publicKey.bytes);
    });
  });
}
