import 'dart:convert';
import 'dart:io';

import 'package:cribcall/src/identity/identity_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('identity repository persists and reloads same fingerprint', () async {
    final tempDir = await Directory.systemTemp.createTemp('identity-repo');
    final repo = IdentityRepository(overrideDirectoryPath: tempDir.path);

    final first = await repo.loadOrCreate();
    final second = await repo.loadOrCreate();

    expect(second.certFingerprint, first.certFingerprint);
    await tempDir.delete(recursive: true);
  });

  test('throws on fingerprint mismatch', () async {
    final tempDir = await Directory.systemTemp.createTemp('identity-repo');
    final repo = IdentityRepository(overrideDirectoryPath: tempDir.path);
    await repo.loadOrCreate();

    final file = File('${tempDir.path}/identity.json');
    await file.create(recursive: true);
    final contents = await file.readAsString();
    final data = jsonDecode(contents) as Map<String, dynamic>;
    data['certFingerprint'] = 'badfingerprint';
    await file.writeAsString(jsonEncode(data));
    expect(await file.exists(), isTrue);

    await expectLater(repo.loadOrCreate, throwsA(isA<Exception>()));
    await tempDir.delete(recursive: true);
  });
}
