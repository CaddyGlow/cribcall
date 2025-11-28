import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';

const _kFileName = 'per_monitor_settings.json';

/// Per-monitor settings for notification and noise detection behavior.
/// Fields that are null fall back to global listener settings.
class PerMonitorSettings {
  const PerMonitorSettings({
    required this.remoteDeviceId,
    this.notificationsEnabled = true,
    this.autoPlayOnNoise = false,
    this.autoPlayDurationSec = 15,
    this.thresholdOverride,
    this.cooldownSecondsOverride,
    this.autoStreamTypeOverride,
    this.autoStreamDurationSecOverride,
  });

  final String remoteDeviceId;

  /// Whether notifications are enabled for this monitor.
  final bool notificationsEnabled;

  /// Whether to auto-play stream when a noise event is received.
  final bool autoPlayOnNoise;

  /// Duration in seconds for auto-play stream.
  final int autoPlayDurationSec;

  /// Per-monitor threshold override. If null, uses global listener setting.
  final int? thresholdOverride;

  /// Per-monitor cooldown override. If null, uses global listener setting.
  final int? cooldownSecondsOverride;

  /// Per-monitor auto-stream type override. If null, uses global listener setting.
  final AutoStreamType? autoStreamTypeOverride;

  /// Per-monitor auto-stream duration override. If null, uses global listener setting.
  final int? autoStreamDurationSecOverride;

  /// Creates default settings for a monitor.
  factory PerMonitorSettings.defaults(String remoteDeviceId) {
    return PerMonitorSettings(remoteDeviceId: remoteDeviceId);
  }

  /// Returns true if any noise preference overrides are set.
  bool get hasNoisePreferenceOverrides =>
      thresholdOverride != null ||
      cooldownSecondsOverride != null ||
      autoStreamTypeOverride != null ||
      autoStreamDurationSecOverride != null;

  /// Get effective noise preferences, merging overrides with global defaults.
  NoisePreferences effectiveNoisePreferences(NoisePreferences globalDefaults) {
    return NoisePreferences(
      threshold: thresholdOverride ?? globalDefaults.threshold,
      cooldownSeconds: cooldownSecondsOverride ?? globalDefaults.cooldownSeconds,
      autoStreamType: autoStreamTypeOverride ?? globalDefaults.autoStreamType,
      autoStreamDurationSec:
          autoStreamDurationSecOverride ?? globalDefaults.autoStreamDurationSec,
    );
  }

  PerMonitorSettings copyWith({
    bool? notificationsEnabled,
    bool? autoPlayOnNoise,
    int? autoPlayDurationSec,
    int? thresholdOverride,
    int? cooldownSecondsOverride,
    AutoStreamType? autoStreamTypeOverride,
    int? autoStreamDurationSecOverride,
    bool clearThresholdOverride = false,
    bool clearCooldownSecondsOverride = false,
    bool clearAutoStreamTypeOverride = false,
    bool clearAutoStreamDurationSecOverride = false,
  }) {
    return PerMonitorSettings(
      remoteDeviceId: remoteDeviceId,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      autoPlayOnNoise: autoPlayOnNoise ?? this.autoPlayOnNoise,
      autoPlayDurationSec: autoPlayDurationSec ?? this.autoPlayDurationSec,
      thresholdOverride: clearThresholdOverride
          ? null
          : (thresholdOverride ?? this.thresholdOverride),
      cooldownSecondsOverride: clearCooldownSecondsOverride
          ? null
          : (cooldownSecondsOverride ?? this.cooldownSecondsOverride),
      autoStreamTypeOverride: clearAutoStreamTypeOverride
          ? null
          : (autoStreamTypeOverride ?? this.autoStreamTypeOverride),
      autoStreamDurationSecOverride: clearAutoStreamDurationSecOverride
          ? null
          : (autoStreamDurationSecOverride ?? this.autoStreamDurationSecOverride),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'remoteDeviceId': remoteDeviceId,
      'notificationsEnabled': notificationsEnabled,
      'autoPlayOnNoise': autoPlayOnNoise,
      'autoPlayDurationSec': autoPlayDurationSec,
      if (thresholdOverride != null) 'thresholdOverride': thresholdOverride,
      if (cooldownSecondsOverride != null)
        'cooldownSecondsOverride': cooldownSecondsOverride,
      if (autoStreamTypeOverride != null)
        'autoStreamTypeOverride': autoStreamTypeOverride!.name,
      if (autoStreamDurationSecOverride != null)
        'autoStreamDurationSecOverride': autoStreamDurationSecOverride,
    };
  }

  factory PerMonitorSettings.fromJson(Map<String, dynamic> json) {
    final autoStreamTypeName = json['autoStreamTypeOverride'] as String?;
    return PerMonitorSettings(
      remoteDeviceId: json['remoteDeviceId'] as String,
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
      autoPlayOnNoise: json['autoPlayOnNoise'] as bool? ?? false,
      autoPlayDurationSec: json['autoPlayDurationSec'] as int? ?? 15,
      thresholdOverride: json['thresholdOverride'] as int?,
      cooldownSecondsOverride: json['cooldownSecondsOverride'] as int?,
      autoStreamTypeOverride: autoStreamTypeName != null
          ? AutoStreamType.values.byName(autoStreamTypeName)
          : null,
      autoStreamDurationSecOverride:
          json['autoStreamDurationSecOverride'] as int?,
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

  Future<void> save(String remoteDeviceId, PerMonitorSettings settings) async {
    final existing = await loadAll();
    existing[remoteDeviceId] = settings;

    final json = jsonEncode(
      existing.map((key, value) => MapEntry(key, value.toJson())),
    );
    final file = await _file();
    await file.writeAsString(json);
  }

  Future<void> remove(String remoteDeviceId) async {
    final existing = await loadAll();
    existing.remove(remoteDeviceId);

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

  PerMonitorSettings? getSettings(String remoteDeviceId) {
    return settings[remoteDeviceId];
  }

  PerMonitorSettings getOrDefault(String remoteDeviceId) {
    return settings[remoteDeviceId] ?? PerMonitorSettings.defaults(remoteDeviceId);
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
  PerMonitorSettings? getSettings(String remoteDeviceId) {
    return state.asData?.value.getSettings(remoteDeviceId);
  }

  /// Get settings for a monitor, or defaults if not set.
  PerMonitorSettings getOrDefault(String remoteDeviceId) {
    return state.asData?.value.getOrDefault(remoteDeviceId) ??
        PerMonitorSettings.defaults(remoteDeviceId);
  }

  /// Update notifications enabled for a monitor.
  Future<void> setNotificationsEnabled(
    String remoteDeviceId,
    bool enabled,
  ) async {
    final current = getOrDefault(remoteDeviceId);
    await _saveSettings(current.copyWith(notificationsEnabled: enabled));
  }

  /// Update auto-play on noise for a monitor.
  Future<void> setAutoPlayOnNoise(String remoteDeviceId, bool enabled) async {
    final current = getOrDefault(remoteDeviceId);
    await _saveSettings(current.copyWith(autoPlayOnNoise: enabled));
  }

  /// Update auto-play duration for a monitor.
  Future<void> setAutoPlayDuration(String remoteDeviceId, int durationSec) async {
    final current = getOrDefault(remoteDeviceId);
    await _saveSettings(current.copyWith(autoPlayDurationSec: durationSec));
  }

  /// Set threshold override for a monitor. Pass null to clear.
  Future<void> setThresholdOverride(String remoteDeviceId, int? threshold) async {
    final current = getOrDefault(remoteDeviceId);
    await _saveSettings(current.copyWith(
      thresholdOverride: threshold,
      clearThresholdOverride: threshold == null,
    ));
  }

  /// Set cooldown override for a monitor. Pass null to clear.
  Future<void> setCooldownSecondsOverride(String remoteDeviceId, int? cooldown) async {
    final current = getOrDefault(remoteDeviceId);
    await _saveSettings(current.copyWith(
      cooldownSecondsOverride: cooldown,
      clearCooldownSecondsOverride: cooldown == null,
    ));
  }

  /// Set auto-stream type override for a monitor. Pass null to clear.
  Future<void> setAutoStreamTypeOverride(
    String remoteDeviceId,
    AutoStreamType? type,
  ) async {
    final current = getOrDefault(remoteDeviceId);
    await _saveSettings(current.copyWith(
      autoStreamTypeOverride: type,
      clearAutoStreamTypeOverride: type == null,
    ));
  }

  /// Set auto-stream duration override for a monitor. Pass null to clear.
  Future<void> setAutoStreamDurationSecOverride(
    String remoteDeviceId,
    int? duration,
  ) async {
    final current = getOrDefault(remoteDeviceId);
    await _saveSettings(current.copyWith(
      autoStreamDurationSecOverride: duration,
      clearAutoStreamDurationSecOverride: duration == null,
    ));
  }

  /// Save settings for a monitor.
  Future<void> _saveSettings(PerMonitorSettings settings) async {
    final repo = ref.read(perMonitorSettingsRepositoryProvider);
    await repo.save(settings.remoteDeviceId, settings);

    // Update state
    final currentState = state.asData?.value;
    if (currentState != null) {
      final newSettings = Map<String, PerMonitorSettings>.from(currentState.settings);
      newSettings[settings.remoteDeviceId] = settings;
      state = AsyncData(PerMonitorSettingsState(settings: newSettings));
    }
  }

  /// Remove settings for a monitor.
  Future<void> removeSettings(String remoteDeviceId) async {
    final repo = ref.read(perMonitorSettingsRepositoryProvider);
    await repo.remove(remoteDeviceId);

    // Update state
    final currentState = state.asData?.value;
    if (currentState != null) {
      final newSettings = Map<String, PerMonitorSettings>.from(currentState.settings);
      newSettings.remove(remoteDeviceId);
      state = AsyncData(PerMonitorSettingsState(settings: newSettings));
    }
  }
}

/// Provider for per-monitor settings.
final perMonitorSettingsProvider =
    AsyncNotifierProvider<PerMonitorSettingsController, PerMonitorSettingsState>(
  PerMonitorSettingsController.new,
);
