import 'dart:convert';
import 'dart:io';

import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class IdentityStore {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> data);

  factory IdentityStore.create({String? overrideDirectoryPath}) {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      return SecureIdentityStore();
    }
    final baseDir =
        overrideDirectoryPath ??
        Platform.environment['CRIBCALL_DATA_DIR'] ??
        '${Platform.environment['HOME'] ?? '.'}/.local/share/com.cribcall.cribcall';
    return FileIdentityStore(overrideDirectoryPath: baseDir);
  }
}

class FileIdentityStore implements IdentityStore {
  FileIdentityStore({this.overrideDirectoryPath});

  final String? overrideDirectoryPath;

  Future<File> _file() async {
    final dir = Directory(overrideDirectoryPath!);
    await dir.create(recursive: true);
    final file = File('${dir.path}/identity.json');
    debugPrint('[identity_store] using path ${file.path}');
    return file;
  }

  Future<File> file() => _file();

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
    debugPrint('[identity_store] wrote identity to ${file.path}');
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
