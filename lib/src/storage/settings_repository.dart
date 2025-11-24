import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';

abstract class _BaseSettingsRepository {
  _BaseSettingsRepository({this.overrideDirectoryPath});

  final String? overrideDirectoryPath;
  Future<Directory>? _cachedDirectory;

  Future<File> _file(String name) async {
    final dir = await _directory();
    await dir.create(recursive: true);
    return File('${dir.path}/$name');
  }

  Future<Directory> _directory() {
    return _cachedDirectory ??= _resolveDirectory();
  }

  Future<Directory> _resolveDirectory() async {
    if (overrideDirectoryPath != null) {
      return Directory(overrideDirectoryPath!);
    }
    try {
      return await getApplicationSupportDirectory();
    } on MissingPluginException {
      return Directory.systemTemp.createTempSync('cribcall_support');
    }
  }
}

class MonitorSettingsRepository extends _BaseSettingsRepository {
  MonitorSettingsRepository({super.overrideDirectoryPath});

  Future<MonitorSettings> load() async {
    final file = await _file('monitor_settings.json');
    if (!await file.exists()) return MonitorSettings.defaults;
    try {
      final contents = await file.readAsString();
      final data = jsonDecode(contents) as Map<String, dynamic>;
      return MonitorSettings.fromJson(data);
    } catch (_) {
      return MonitorSettings.defaults;
    }
  }

  Future<void> save(MonitorSettings settings) async {
    final file = await _file('monitor_settings.json');
    await file.writeAsString(jsonEncode(settings.toJson()));
  }
}

class ListenerSettingsRepository extends _BaseSettingsRepository {
  ListenerSettingsRepository({super.overrideDirectoryPath});

  Future<ListenerSettings> load() async {
    final file = await _file('listener_settings.json');
    if (!await file.exists()) return ListenerSettings.defaults;
    try {
      final contents = await file.readAsString();
      final data = jsonDecode(contents) as Map<String, dynamic>;
      return ListenerSettings.fromJson(data);
    } catch (_) {
      return ListenerSettings.defaults;
    }
  }

  Future<void> save(ListenerSettings settings) async {
    final file = await _file('listener_settings.json');
    await file.writeAsString(jsonEncode(settings.toJson()));
  }
}
