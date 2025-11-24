import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';

class TrustedMonitorsRepository {
  TrustedMonitorsRepository({this.overrideDirectoryPath});

  final String? overrideDirectoryPath;
  Future<Directory>? _cachedDirectory;

  Future<File> _file() async {
    final dir = await _directory();
    await dir.create(recursive: true);
    return File('${dir.path}/trusted_monitors.json');
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

  Future<List<TrustedMonitor>> load() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final contents = await file.readAsString();
    final data = jsonDecode(contents) as List<dynamic>;
    return data
        .map((e) => TrustedMonitor.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<void> save(List<TrustedMonitor> monitors) async {
    final file = await _file();
    final data = monitors.map((m) => m.toJson()).toList();
    await file.writeAsString(jsonEncode(data));
  }
}
