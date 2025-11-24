import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

abstract class IdentityStore {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> data);

  factory IdentityStore.create({String? overrideDirectoryPath}) {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      return SecureIdentityStore();
    }
    return FileIdentityStore(overrideDirectoryPath: overrideDirectoryPath);
  }
}

class FileIdentityStore implements IdentityStore {
  FileIdentityStore({this.overrideDirectoryPath});

  final String? overrideDirectoryPath;

  Future<File> _file() async {
    final dir = overrideDirectoryPath != null
        ? Directory(overrideDirectoryPath!)
        : await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}/identity.json');
  }

  @override
  Future<Map<String, dynamic>?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    final contents = await file.readAsString();
    return jsonDecode(contents) as Map<String, dynamic>;
  }

  @override
  Future<void> write(Map<String, dynamic> data) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(data));
  }
}

class SecureIdentityStore implements IdentityStore {
  SecureIdentityStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  final FlutterSecureStorage _storage;
  static const _key = 'cribcall_device_identity';

  @override
  Future<Map<String, dynamic>?> read() async {
    final value = await _storage.read(key: _key);
    if (value == null) return null;
    return jsonDecode(value) as Map<String, dynamic>;
  }

  @override
  Future<void> write(Map<String, dynamic> data) async {
    await _storage.write(key: _key, value: jsonEncode(data));
  }
}
