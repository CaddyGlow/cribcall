import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

const _kFileName = 'per_monitor_settings.json';

/// Per-monitor settings for notification and auto-play behavior.
class PerMonitorSettings {
  const PerMonitorSettings({
    required this.monitorId,
    this.notificationsEnabled = true,
    this.autoPlayOnNoise = false,
    this.autoPlayDurationSec = 15,
  });

  final String monitorId;

  /// Whether notifications are enabled for this monitor.
  /// If null, falls back to global setting.
  final bool notificationsEnabled;

  /// Whether to auto-play stream when a noise event is received.
  final bool autoPlayOnNoise;

  /// Duration in seconds for auto-play stream.
  final int autoPlayDurationSec;

  /// Creates default settings for a monitor.
  factory PerMonitorSettings.defaults(String monitorId) {
    return PerMonitorSettings(monitorId: monitorId);
  }

  PerMonitorSettings copyWith({
    bool? notificationsEnabled,
    bool? autoPlayOnNoise,
    int? autoPlayDurationSec,
  }) {
    return PerMonitorSettings(
      monitorId: monitorId,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      autoPlayOnNoise: autoPlayOnNoise ?? this.autoPlayOnNoise,
      autoPlayDurationSec: autoPlayDurationSec ?? this.autoPlayDurationSec,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'monitorId': monitorId,
      'notificationsEnabled': notificationsEnabled,
      'autoPlayOnNoise': autoPlayOnNoise,
      'autoPlayDurationSec': autoPlayDurationSec,
    };
  }

  factory PerMonitorSettings.fromJson(Map<String, dynamic> json) {
    return PerMonitorSettings(
      monitorId: json['monitorId'] as String,
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
      autoPlayOnNoise: json['autoPlayOnNoise'] as bool? ?? false,
      autoPlayDurationSec: json['autoPlayDurationSec'] as int? ?? 15,
    );
  }
}

/// Repository for per-monitor settings persistence.
class PerMonitorSettingsRepository {
  PerMonitorSettingsRepository({this.overrideDirectoryPath});

  final String? overrideDirectoryPath;
  Future<Directory>? _cachedDirectory;

  Future<File> _file() async {
    final dir = await _directory();
    await dir.create(recursive: true);
    return File('${dir.path}/$_kFileName');
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

  Future<Map<String, PerMonitorSettings>> loadAll() async {
    final file = await _file();
    if (!await file.exists()) return {};

    try {
      final contents = await file.readAsString();
      final map = jsonDecode(contents) as Map<String, dynamic>;
      return map.map((key, value) => MapEntry(
        key,
        PerMonitorSettings.fromJson(value as Map<String, dynamic>),
      ));
    } catch (e) {
      return {};
    }
  }

  Future<void> save(String monitorId, PerMonitorSettings settings) async {
    final existing = await loadAll();
    existing[monitorId] = settings;

    final json = jsonEncode(
      existing.map((key, value) => MapEntry(key, value.toJson())),
    );
    final file = await _file();
    await file.writeAsString(json);
  }

  Future<void> remove(String monitorId) async {
    final existing = await loadAll();
    existing.remove(monitorId);

    final json = jsonEncode(
      existing.map((key, value) => MapEntry(key, value.toJson())),
    );
    final file = await _file();
    await file.writeAsString(json);
  }
}

/// Provider for per-monitor settings repository.
final perMonitorSettingsRepositoryProvider =
    Provider<PerMonitorSettingsRepository>((ref) {
  return PerMonitorSettingsRepository();
});

/// State for per-monitor settings.
class PerMonitorSettingsState {
  const PerMonitorSettingsState({
    required this.settings,
    this.isLoading = false,
  });

  final Map<String, PerMonitorSettings> settings;
  final bool isLoading;

  PerMonitorSettings? getSettings(String monitorId) {
    return settings[monitorId];
  }

  PerMonitorSettings getOrDefault(String monitorId) {
    return settings[monitorId] ?? PerMonitorSettings.defaults(monitorId);
  }
}

/// Controller for per-monitor settings.
class PerMonitorSettingsController extends AsyncNotifier<PerMonitorSettingsState> {
  @override
  Future<PerMonitorSettingsState> build() async {
    final repo = ref.read(perMonitorSettingsRepositoryProvider);
    final settings = await repo.loadAll();
    return PerMonitorSettingsState(settings: settings);
  }

  /// Get settings for a specific monitor.
  PerMonitorSettings? getSettings(String monitorId) {
    return state.asData?.value.getSettings(monitorId);
  }

  /// Get settings for a monitor, or defaults if not set.
  PerMonitorSettings getOrDefault(String monitorId) {
    return state.asData?.value.getOrDefault(monitorId) ??
        PerMonitorSettings.defaults(monitorId);
  }

  /// Update notifications enabled for a monitor.
  Future<void> setNotificationsEnabled(
    String monitorId,
    bool enabled,
  ) async {
    final current = getOrDefault(monitorId);
    await _saveSettings(current.copyWith(notificationsEnabled: enabled));
  }

  /// Update auto-play on noise for a monitor.
  Future<void> setAutoPlayOnNoise(String monitorId, bool enabled) async {
    final current = getOrDefault(monitorId);
    await _saveSettings(current.copyWith(autoPlayOnNoise: enabled));
  }

  /// Update auto-play duration for a monitor.
  Future<void> setAutoPlayDuration(String monitorId, int durationSec) async {
    final current = getOrDefault(monitorId);
    await _saveSettings(current.copyWith(autoPlayDurationSec: durationSec));
  }

  /// Save settings for a monitor.
  Future<void> _saveSettings(PerMonitorSettings settings) async {
    final repo = ref.read(perMonitorSettingsRepositoryProvider);
    await repo.save(settings.monitorId, settings);

    // Update state
    final currentState = state.asData?.value;
    if (currentState != null) {
      final newSettings = Map<String, PerMonitorSettings>.from(currentState.settings);
      newSettings[settings.monitorId] = settings;
      state = AsyncData(PerMonitorSettingsState(settings: newSettings));
    }
  }

  /// Remove settings for a monitor.
  Future<void> removeSettings(String monitorId) async {
    final repo = ref.read(perMonitorSettingsRepositoryProvider);
    await repo.remove(monitorId);

    // Update state
    final currentState = state.asData?.value;
    if (currentState != null) {
      final newSettings = Map<String, PerMonitorSettings>.from(currentState.settings);
      newSettings.remove(monitorId);
      state = AsyncData(PerMonitorSettingsState(settings: newSettings));
    }
  }
}

/// Provider for per-monitor settings.
final perMonitorSettingsProvider =
    AsyncNotifierProvider<PerMonitorSettingsController, PerMonitorSettingsState>(
  PerMonitorSettingsController.new,
);
