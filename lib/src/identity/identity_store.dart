import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class IdentityStore {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> data);
  Future<void> delete();

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

  @override
  Future<void> delete() async {
    final file = await _file();
    if (await file.exists()) {
      await file.delete();
      debugPrint('[identity_store] deleted identity from ${file.path}');
    }
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
    debugPrint('[identity_store] SecureIdentityStore.read() starting');
    try {
      final value = await _storage.read(key: _key).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('[identity_store] SecureIdentityStore.read() TIMEOUT');
          return null;
        },
      );
      debugPrint('[identity_store] SecureIdentityStore.read() completed: ${value != null ? 'found' : 'null'}');
      if (value == null) return null;
      return jsonDecode(value) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[identity_store] SecureIdentityStore.read() error: $e');
      rethrow;
    }
  }

  @override
  Future<void> write(Map<String, dynamic> data) async {
    debugPrint('[identity_store] SecureIdentityStore.write() starting');
    try {
      await _storage.write(key: _key, value: jsonEncode(data)).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('[identity_store] SecureIdentityStore.write() TIMEOUT');
          throw TimeoutException('SecureStorage write timeout');
        },
      );
      debugPrint('[identity_store] SecureIdentityStore.write() completed');
    } catch (e) {
      debugPrint('[identity_store] SecureIdentityStore.write() error: $e');
      rethrow;
    }
  }

  @override
  Future<void> delete() async {
    debugPrint('[identity_store] SecureIdentityStore.delete() starting');
    try {
      await _storage.delete(key: _key).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('[identity_store] SecureIdentityStore.delete() TIMEOUT');
          throw TimeoutException('SecureStorage delete timeout');
        },
      );
      debugPrint('[identity_store] SecureIdentityStore.delete() completed');
    } catch (e) {
      debugPrint('[identity_store] SecureIdentityStore.delete() error: $e');
      rethrow;
    }
  }
}
