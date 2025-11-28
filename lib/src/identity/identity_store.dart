import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  static const _metaKeyPrefix = 'cribcall_identity_meta_';
  static const _metaKeyCreatedAt = '${_metaKeyPrefix}created_at';
  static const _metaKeyCreatedVersion = '${_metaKeyPrefix}created_version';
  static const _metaKeyCreatedBuild = '${_metaKeyPrefix}created_build';
  static const _metaKeyLastSeenVersion = '${_metaKeyPrefix}last_seen_version';
  static const _metaKeyLastSeenBuild = '${_metaKeyPrefix}last_seen_build';
  static const _metaKeyReadCount = '${_metaKeyPrefix}read_count';
  static const _metaKeyWriteCount = '${_metaKeyPrefix}write_count';

  Future<void> _logDiagnostics({
    required String operation,
    required bool identityFound,
    String? error,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      final currentBuild = packageInfo.buildNumber;

      final createdAt = prefs.getString(_metaKeyCreatedAt);
      final createdVersion = prefs.getString(_metaKeyCreatedVersion);
      final createdBuild = prefs.getString(_metaKeyCreatedBuild);
      final lastSeenVersion = prefs.getString(_metaKeyLastSeenVersion);
      final lastSeenBuild = prefs.getString(_metaKeyLastSeenBuild);
      final readCount = prefs.getInt(_metaKeyReadCount) ?? 0;
      final writeCount = prefs.getInt(_metaKeyWriteCount) ?? 0;

      final isFirstRun = createdAt == null;
      final isNewVersion = lastSeenVersion != null && lastSeenVersion != currentVersion;
      final isNewBuild = lastSeenBuild != null && lastSeenBuild != currentBuild;

      debugPrint('[identity_store] === IDENTITY DIAGNOSTICS ($operation) ===');
      debugPrint('[identity_store] Current app: v$currentVersion+$currentBuild');
      debugPrint('[identity_store] Identity found: $identityFound');
      debugPrint('[identity_store] First run ever: $isFirstRun');
      if (!isFirstRun) {
        debugPrint('[identity_store] Identity created: $createdAt (v$createdVersion+$createdBuild)');
        debugPrint('[identity_store] Last seen: v$lastSeenVersion+$lastSeenBuild');
        debugPrint('[identity_store] Version changed: $isNewVersion, Build changed: $isNewBuild');
        debugPrint('[identity_store] Total reads: $readCount, Total writes: $writeCount');
      }
      if (error != null) {
        debugPrint('[identity_store] Error: $error');
      }

      // Detect potential issues
      if (!identityFound && !isFirstRun) {
        debugPrint('[identity_store] WARNING: Identity was previously created but not found!');
        debugPrint('[identity_store] This may indicate:');
        if (isNewVersion || isNewBuild) {
          debugPrint('[identity_store]   - App update caused keystore data loss (v$lastSeenVersion -> v$currentVersion)');
        }
        debugPrint('[identity_store]   - App was reinstalled');
        debugPrint('[identity_store]   - Android keystore was cleared');
        debugPrint('[identity_store]   - encryptedSharedPreferences key rotation issue');
      }

      // Update last seen version
      await prefs.setString(_metaKeyLastSeenVersion, currentVersion);
      await prefs.setString(_metaKeyLastSeenBuild, currentBuild);

      if (operation == 'read') {
        await prefs.setInt(_metaKeyReadCount, readCount + 1);
      }

      debugPrint('[identity_store] === END DIAGNOSTICS ===');
    } catch (e) {
      debugPrint('[identity_store] Failed to log diagnostics: $e');
    }
  }

  Future<void> _recordIdentityCreation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final packageInfo = await PackageInfo.fromPlatform();

      await prefs.setString(_metaKeyCreatedAt, DateTime.now().toIso8601String());
      await prefs.setString(_metaKeyCreatedVersion, packageInfo.version);
      await prefs.setString(_metaKeyCreatedBuild, packageInfo.buildNumber);
      await prefs.setString(_metaKeyLastSeenVersion, packageInfo.version);
      await prefs.setString(_metaKeyLastSeenBuild, packageInfo.buildNumber);
      await prefs.setInt(_metaKeyWriteCount, 1);

      debugPrint('[identity_store] Recorded new identity creation at v${packageInfo.version}+${packageInfo.buildNumber}');
    } catch (e) {
      debugPrint('[identity_store] Failed to record identity creation: $e');
    }
  }

  Future<void> _incrementWriteCount() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final count = prefs.getInt(_metaKeyWriteCount) ?? 0;
      await prefs.setInt(_metaKeyWriteCount, count + 1);
    } catch (e) {
      debugPrint('[identity_store] Failed to increment write count: $e');
    }
  }

  @override
  Future<Map<String, dynamic>?> read() async {
    debugPrint('[identity_store] SecureIdentityStore.read() starting');
    String? errorMsg;
    bool found = false;

    try {
      final value = await _storage.read(key: _key).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('[identity_store] SecureIdentityStore.read() TIMEOUT');
          errorMsg = 'TIMEOUT after 5 seconds';
          return null;
        },
      );
      found = value != null;
      debugPrint('[identity_store] SecureIdentityStore.read() completed: ${found ? 'found' : 'null'}');

      await _logDiagnostics(operation: 'read', identityFound: found, error: errorMsg);

      if (value == null) return null;
      return jsonDecode(value) as Map<String, dynamic>;
    } catch (e) {
      errorMsg = e.toString();
      debugPrint('[identity_store] SecureIdentityStore.read() error: $e');
      await _logDiagnostics(operation: 'read', identityFound: false, error: errorMsg);
      rethrow;
    }
  }

  @override
  Future<void> write(Map<String, dynamic> data) async {
    debugPrint('[identity_store] SecureIdentityStore.write() starting');

    // Check if this is a new identity or update
    final prefs = await SharedPreferences.getInstance();
    final isFirstWrite = prefs.getString(_metaKeyCreatedAt) == null;

    try {
      await _storage.write(key: _key, value: jsonEncode(data)).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('[identity_store] SecureIdentityStore.write() TIMEOUT');
          throw TimeoutException('SecureStorage write timeout');
        },
      );
      debugPrint('[identity_store] SecureIdentityStore.write() completed');

      if (isFirstWrite) {
        await _recordIdentityCreation();
      } else {
        await _incrementWriteCount();
      }
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

      // Clear metadata when identity is explicitly deleted
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_metaKeyCreatedAt);
      await prefs.remove(_metaKeyCreatedVersion);
      await prefs.remove(_metaKeyCreatedBuild);
      await prefs.remove(_metaKeyLastSeenVersion);
      await prefs.remove(_metaKeyLastSeenBuild);
      await prefs.remove(_metaKeyReadCount);
      await prefs.remove(_metaKeyWriteCount);
      debugPrint('[identity_store] Cleared identity metadata');
    } catch (e) {
      debugPrint('[identity_store] SecureIdentityStore.delete() error: $e');
      rethrow;
    }
  }
}
