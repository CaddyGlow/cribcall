import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';

const _kFileName = 'connected_monitor_settings.json';

/// Settings for a connected monitor, storing both the monitor's base settings
/// and the listener's customizations.
///
/// When a listener connects to a monitor, the monitor sends its settings.
/// The listener can then customize these and send them back to the monitor.
class ConnectedMonitorSettings {
  const ConnectedMonitorSettings({
    required this.monitorDeviceId,
    required this.baseThreshold,
    required this.baseCooldownSeconds,
    required this.baseAutoStreamType,
    required this.baseAutoStreamDurationSec,
    required this.baseAudioInputGain,
    this.customThreshold,
    this.customCooldownSeconds,
    this.customAutoStreamType,
    this.customAutoStreamDurationSec,
    this.notificationsEnabled = true,
    this.autoPlayOnNoise = false,
    this.autoPlayDurationSec = 15,
    this.lastReceivedEpochMs,
  });

  final String monitorDeviceId;

  // Base settings from monitor (read-only, received via MONITOR_SETTINGS)
  final int baseThreshold;
  final int baseCooldownSeconds;
  final AutoStreamType baseAutoStreamType;
  final int baseAutoStreamDurationSec;
  final int baseAudioInputGain; // Read-only, informational

  // Listener's customizations (null = use monitor's base value)
  final int? customThreshold;
  final int? customCooldownSeconds;
  final AutoStreamType? customAutoStreamType;
  final int? customAutoStreamDurationSec;

  // Local listener settings (not sent to monitor)
  final bool notificationsEnabled;
  final bool autoPlayOnNoise;
  final int autoPlayDurationSec;

  // Timestamp when settings were last received from monitor
  final int? lastReceivedEpochMs;

  /// Effective threshold (custom if set, otherwise base).
  int get effectiveThreshold => customThreshold ?? baseThreshold;

  /// Effective cooldown (custom if set, otherwise base).
  int get effectiveCooldownSeconds =>
      customCooldownSeconds ?? baseCooldownSeconds;

  /// Effective auto-stream type (custom if set, otherwise base).
  AutoStreamType get effectiveAutoStreamType =>
      customAutoStreamType ?? baseAutoStreamType;

  /// Effective auto-stream duration (custom if set, otherwise base).
  int get effectiveAutoStreamDurationSec =>
      customAutoStreamDurationSec ?? baseAutoStreamDurationSec;

  /// Returns true if any customizations are set.
  bool get hasCustomizations =>
      customThreshold != null ||
      customCooldownSeconds != null ||
      customAutoStreamType != null ||
      customAutoStreamDurationSec != null;

  /// Creates default settings with monitor defaults (before receiving from monitor).
  factory ConnectedMonitorSettings.withDefaults(String monitorDeviceId) {
    return ConnectedMonitorSettings(
      monitorDeviceId: monitorDeviceId,
      baseThreshold: MonitorSettings.defaults.noise.threshold,
      baseCooldownSeconds: MonitorSettings.defaults.noise.cooldownSeconds,
      baseAutoStreamType: MonitorSettings.defaults.autoStreamType,
      baseAutoStreamDurationSec: MonitorSettings.defaults.autoStreamDurationSec,
      baseAudioInputGain: MonitorSettings.defaults.audioInputGain,
    );
  }

  ConnectedMonitorSettings copyWith({
    int? baseThreshold,
    int? baseCooldownSeconds,
    AutoStreamType? baseAutoStreamType,
    int? baseAutoStreamDurationSec,
    int? baseAudioInputGain,
    int? customThreshold,
    int? customCooldownSeconds,
    AutoStreamType? customAutoStreamType,
    int? customAutoStreamDurationSec,
    bool? notificationsEnabled,
    bool? autoPlayOnNoise,
    int? autoPlayDurationSec,
    int? lastReceivedEpochMs,
    bool clearCustomThreshold = false,
    bool clearCustomCooldownSeconds = false,
    bool clearCustomAutoStreamType = false,
    bool clearCustomAutoStreamDurationSec = false,
  }) {
    return ConnectedMonitorSettings(
      monitorDeviceId: monitorDeviceId,
      baseThreshold: baseThreshold ?? this.baseThreshold,
      baseCooldownSeconds: baseCooldownSeconds ?? this.baseCooldownSeconds,
      baseAutoStreamType: baseAutoStreamType ?? this.baseAutoStreamType,
      baseAutoStreamDurationSec:
          baseAutoStreamDurationSec ?? this.baseAutoStreamDurationSec,
      baseAudioInputGain: baseAudioInputGain ?? this.baseAudioInputGain,
      customThreshold: clearCustomThreshold
          ? null
          : (customThreshold ?? this.customThreshold),
      customCooldownSeconds: clearCustomCooldownSeconds
          ? null
          : (customCooldownSeconds ?? this.customCooldownSeconds),
      customAutoStreamType: clearCustomAutoStreamType
          ? null
          : (customAutoStreamType ?? this.customAutoStreamType),
      customAutoStreamDurationSec: clearCustomAutoStreamDurationSec
          ? null
          : (customAutoStreamDurationSec ?? this.customAutoStreamDurationSec),
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      autoPlayOnNoise: autoPlayOnNoise ?? this.autoPlayOnNoise,
      autoPlayDurationSec: autoPlayDurationSec ?? this.autoPlayDurationSec,
      lastReceivedEpochMs: lastReceivedEpochMs ?? this.lastReceivedEpochMs,
    );
  }

  /// Updates base settings from a received MONITOR_SETTINGS message.
  ConnectedMonitorSettings updateFromMonitor({
    required int threshold,
    required int cooldownSeconds,
    required AutoStreamType autoStreamType,
    required int autoStreamDurationSec,
    required int audioInputGain,
  }) {
    return copyWith(
      baseThreshold: threshold,
      baseCooldownSeconds: cooldownSeconds,
      baseAutoStreamType: autoStreamType,
      baseAutoStreamDurationSec: autoStreamDurationSec,
      baseAudioInputGain: audioInputGain,
      lastReceivedEpochMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'monitorDeviceId': monitorDeviceId,
      'baseThreshold': baseThreshold,
      'baseCooldownSeconds': baseCooldownSeconds,
      'baseAutoStreamType': baseAutoStreamType.name,
      'baseAutoStreamDurationSec': baseAutoStreamDurationSec,
      'baseAudioInputGain': baseAudioInputGain,
      if (customThreshold != null) 'customThreshold': customThreshold,
      if (customCooldownSeconds != null)
        'customCooldownSeconds': customCooldownSeconds,
      if (customAutoStreamType != null)
        'customAutoStreamType': customAutoStreamType!.name,
      if (customAutoStreamDurationSec != null)
        'customAutoStreamDurationSec': customAutoStreamDurationSec,
      'notificationsEnabled': notificationsEnabled,
      'autoPlayOnNoise': autoPlayOnNoise,
      'autoPlayDurationSec': autoPlayDurationSec,
      if (lastReceivedEpochMs != null)
        'lastReceivedEpochMs': lastReceivedEpochMs,
    };
  }

  factory ConnectedMonitorSettings.fromJson(Map<String, dynamic> json) {
    final baseAutoStreamTypeName = json['baseAutoStreamType'] as String?;
    final customAutoStreamTypeName = json['customAutoStreamType'] as String?;
    return ConnectedMonitorSettings(
      monitorDeviceId: json['monitorDeviceId'] as String,
      baseThreshold:
          json['baseThreshold'] as int? ??
          MonitorSettings.defaults.noise.threshold,
      baseCooldownSeconds:
          json['baseCooldownSeconds'] as int? ??
          MonitorSettings.defaults.noise.cooldownSeconds,
      baseAutoStreamType: baseAutoStreamTypeName != null
          ? AutoStreamType.values.byName(baseAutoStreamTypeName)
          : MonitorSettings.defaults.autoStreamType,
      baseAutoStreamDurationSec:
          json['baseAutoStreamDurationSec'] as int? ??
          MonitorSettings.defaults.autoStreamDurationSec,
      baseAudioInputGain:
          json['baseAudioInputGain'] as int? ??
          MonitorSettings.defaults.audioInputGain,
      customThreshold: json['customThreshold'] as int?,
      customCooldownSeconds: json['customCooldownSeconds'] as int?,
      customAutoStreamType: customAutoStreamTypeName != null
          ? AutoStreamType.values.byName(customAutoStreamTypeName)
          : null,
      customAutoStreamDurationSec: json['customAutoStreamDurationSec'] as int?,
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
      autoPlayOnNoise: json['autoPlayOnNoise'] as bool? ?? false,
      autoPlayDurationSec: json['autoPlayDurationSec'] as int? ?? 15,
      lastReceivedEpochMs: json['lastReceivedEpochMs'] as int?,
    );
  }
}

/// Repository for connected monitor settings persistence.
class ConnectedMonitorSettingsRepository {
  ConnectedMonitorSettingsRepository({this.overrideDirectoryPath});

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

  Future<Map<String, ConnectedMonitorSettings>> loadAll() async {
    final file = await _file();
    if (!await file.exists()) return {};

    try {
      final contents = await file.readAsString();
      final map = jsonDecode(contents) as Map<String, dynamic>;
      return map.map(
        (key, value) => MapEntry(
          key,
          ConnectedMonitorSettings.fromJson(value as Map<String, dynamic>),
        ),
      );
    } catch (e) {
      return {};
    }
  }

  Future<void> save(
    String monitorDeviceId,
    ConnectedMonitorSettings settings,
  ) async {
    final existing = await loadAll();
    existing[monitorDeviceId] = settings;

    final json = jsonEncode(
      existing.map((key, value) => MapEntry(key, value.toJson())),
    );
    final file = await _file();
    await file.writeAsString(json);
  }

  Future<void> remove(String monitorDeviceId) async {
    final existing = await loadAll();
    existing.remove(monitorDeviceId);

    final json = jsonEncode(
      existing.map((key, value) => MapEntry(key, value.toJson())),
    );
    final file = await _file();
    await file.writeAsString(json);
  }
}

/// Provider for connected monitor settings repository.
final connectedMonitorSettingsRepositoryProvider =
    Provider<ConnectedMonitorSettingsRepository>((ref) {
      return ConnectedMonitorSettingsRepository();
    });

/// State for connected monitor settings.
class ConnectedMonitorSettingsState {
  const ConnectedMonitorSettingsState({
    required this.settings,
    this.isLoading = false,
  });

  final Map<String, ConnectedMonitorSettings> settings;
  final bool isLoading;

  ConnectedMonitorSettings? getSettings(String monitorDeviceId) {
    return settings[monitorDeviceId];
  }

  ConnectedMonitorSettings getOrDefault(String monitorDeviceId) {
    return settings[monitorDeviceId] ??
        ConnectedMonitorSettings.withDefaults(monitorDeviceId);
  }
}

/// Controller for connected monitor settings.
class ConnectedMonitorSettingsController
    extends AsyncNotifier<ConnectedMonitorSettingsState> {
  @override
  Future<ConnectedMonitorSettingsState> build() async {
    final repo = ref.read(connectedMonitorSettingsRepositoryProvider);
    final settings = await repo.loadAll();
    return ConnectedMonitorSettingsState(settings: settings);
  }

  /// Get settings for a specific monitor.
  ConnectedMonitorSettings? getSettings(String monitorDeviceId) {
    return state.asData?.value.getSettings(monitorDeviceId);
  }

  /// Get settings for a monitor, or defaults if not set.
  ConnectedMonitorSettings getOrDefault(String monitorDeviceId) {
    return state.asData?.value.getOrDefault(monitorDeviceId) ??
        ConnectedMonitorSettings.withDefaults(monitorDeviceId);
  }

  /// Update base settings received from a monitor via MONITOR_SETTINGS message.
  Future<void> updateFromMonitor({
    required String monitorDeviceId,
    required int threshold,
    required int cooldownSeconds,
    required AutoStreamType autoStreamType,
    required int autoStreamDurationSec,
    required int audioInputGain,
  }) async {
    final current = getOrDefault(monitorDeviceId);
    final updated = current.updateFromMonitor(
      threshold: threshold,
      cooldownSeconds: cooldownSeconds,
      autoStreamType: autoStreamType,
      autoStreamDurationSec: autoStreamDurationSec,
      audioInputGain: audioInputGain,
    );
    await _saveSettings(updated);
  }

  /// Set custom threshold for a monitor. Pass null to reset to monitor default.
  Future<void> setCustomThreshold(
    String monitorDeviceId,
    int? threshold,
  ) async {
    final current = getOrDefault(monitorDeviceId);
    await _saveSettings(
      current.copyWith(
        customThreshold: threshold,
        clearCustomThreshold: threshold == null,
      ),
    );
  }

  /// Set custom cooldown for a monitor. Pass null to reset to monitor default.
  Future<void> setCustomCooldownSeconds(
    String monitorDeviceId,
    int? cooldownSeconds,
  ) async {
    final current = getOrDefault(monitorDeviceId);
    await _saveSettings(
      current.copyWith(
        customCooldownSeconds: cooldownSeconds,
        clearCustomCooldownSeconds: cooldownSeconds == null,
      ),
    );
  }

  /// Set custom auto-stream type. Pass null to reset to monitor default.
  Future<void> setCustomAutoStreamType(
    String monitorDeviceId,
    AutoStreamType? type,
  ) async {
    final current = getOrDefault(monitorDeviceId);
    await _saveSettings(
      current.copyWith(
        customAutoStreamType: type,
        clearCustomAutoStreamType: type == null,
      ),
    );
  }

  /// Set custom auto-stream duration. Pass null to reset to monitor default.
  Future<void> setCustomAutoStreamDurationSec(
    String monitorDeviceId,
    int? durationSec,
  ) async {
    final current = getOrDefault(monitorDeviceId);
    await _saveSettings(
      current.copyWith(
        customAutoStreamDurationSec: durationSec,
        clearCustomAutoStreamDurationSec: durationSec == null,
      ),
    );
  }

  /// Update notifications enabled for a monitor.
  Future<void> setNotificationsEnabled(
    String monitorDeviceId,
    bool enabled,
  ) async {
    final current = getOrDefault(monitorDeviceId);
    await _saveSettings(current.copyWith(notificationsEnabled: enabled));
  }

  /// Update auto-play on noise for a monitor.
  Future<void> setAutoPlayOnNoise(String monitorDeviceId, bool enabled) async {
    final current = getOrDefault(monitorDeviceId);
    await _saveSettings(current.copyWith(autoPlayOnNoise: enabled));
  }

  /// Update auto-play duration for a monitor.
  Future<void> setAutoPlayDuration(
    String monitorDeviceId,
    int durationSec,
  ) async {
    final current = getOrDefault(monitorDeviceId);
    await _saveSettings(current.copyWith(autoPlayDurationSec: durationSec));
  }

  /// Reset all customizations to monitor defaults.
  Future<void> resetToMonitorDefaults(String monitorDeviceId) async {
    final current = getOrDefault(monitorDeviceId);
    await _saveSettings(
      current.copyWith(
        clearCustomThreshold: true,
        clearCustomCooldownSeconds: true,
        clearCustomAutoStreamType: true,
        clearCustomAutoStreamDurationSec: true,
      ),
    );
  }

  /// Save settings for a monitor.
  Future<void> _saveSettings(ConnectedMonitorSettings settings) async {
    final repo = ref.read(connectedMonitorSettingsRepositoryProvider);
    await repo.save(settings.monitorDeviceId, settings);

    // Update state
    final currentState = state.asData?.value;
    if (currentState != null) {
      final newSettings = Map<String, ConnectedMonitorSettings>.from(
        currentState.settings,
      );
      newSettings[settings.monitorDeviceId] = settings;
      state = AsyncData(ConnectedMonitorSettingsState(settings: newSettings));
    }
  }

  /// Remove settings for a monitor.
  Future<void> removeSettings(String monitorDeviceId) async {
    final repo = ref.read(connectedMonitorSettingsRepositoryProvider);
    await repo.remove(monitorDeviceId);

    // Update state
    final currentState = state.asData?.value;
    if (currentState != null) {
      final newSettings = Map<String, ConnectedMonitorSettings>.from(
        currentState.settings,
      );
      newSettings.remove(monitorDeviceId);
      state = AsyncData(ConnectedMonitorSettingsState(settings: newSettings));
    }
  }
}

/// Provider for connected monitor settings.
final connectedMonitorSettingsProvider =
    AsyncNotifierProvider<
      ConnectedMonitorSettingsController,
      ConnectedMonitorSettingsState
    >(ConnectedMonitorSettingsController.new);
