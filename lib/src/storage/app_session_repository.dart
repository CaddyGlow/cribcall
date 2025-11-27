import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';

const _deviceInfoChannel = MethodChannel('cribcall/device_info');

String _safeLocalHostname() {
  try {
    return Platform.localHostname;
  } catch (_) {
    return '';
  }
}

bool _looksLikeLocalhost(String value) {
  final host = value.trim().toLowerCase();
  return host == 'localhost' || host == 'localhost.localdomain';
}

bool _isMeaningfulHostname(String value) {
  return value.trim().isNotEmpty && !_looksLikeLocalhost(value);
}

String _fallbackDeviceLabel(bool isAndroid) {
  return isAndroid ? 'Android device' : 'Device';
}

Future<String?> _androidDeviceName() async {
  try {
    final name = await _deviceInfoChannel.invokeMethod<String>('getDeviceName');
    if (name == null) return null;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  } catch (_) {
    return null;
  }
}

/// Resolve a best-effort device name.
/// On Android, prefers the platform device name when the hostname is localhost.
Future<String> resolveDefaultDeviceName({
  String Function()? hostnameGetter,
  Future<String?> Function()? androidResolver,
  bool? isAndroidOverride,
}) async {
  final isAndroid = isAndroidOverride ?? Platform.isAndroid;
  final host = (hostnameGetter ?? _safeLocalHostname)().trim();

  if (_isMeaningfulHostname(host)) {
    return host;
  }

  if (!isAndroid) {
    return host.isNotEmpty ? host : _fallbackDeviceLabel(false);
  }

  final androidName = await (androidResolver ?? _androidDeviceName)();
  if (androidName != null) {
    return androidName;
  }

  return _fallbackDeviceLabel(true);
}

/// Returns the device hostname, used as the default device name.
String getDeviceHostname() {
  final host = _safeLocalHostname();
  if (_isMeaningfulHostname(host)) {
    return host;
  }
  return _fallbackDeviceLabel(Platform.isAndroid);
}

/// Persistent application session state.
/// Stores the last known state so it can be restored on app launch.
class AppSessionState {
  AppSessionState({
    this.lastRole,
    this.monitoringEnabled = true,
    this.lastConnectedMonitorId,
    String? deviceName,
  }) : deviceName = deviceName ?? getDeviceHostname();

  /// The last selected role (monitor or listener).
  final DeviceRole? lastRole;

  /// Whether monitoring was enabled (for monitor role).
  final bool monitoringEnabled;

  /// The last monitor ID the listener was connected to.
  final String? lastConnectedMonitorId;

  /// User-configurable device name. Defaults to hostname.
  final String deviceName;

  /// The device hostname (for display purposes).
  String get hostname => getDeviceHostname();

  /// Returns display name: just deviceName if it equals hostname,
  /// otherwise "deviceName (hostname)".
  String get displayName {
    final host = hostname;
    if (deviceName == host) {
      return deviceName;
    }
    return '$deviceName ($host)';
  }

  static final defaults = AppSessionState();

  AppSessionState copyWith({
    DeviceRole? lastRole,
    bool? monitoringEnabled,
    String? lastConnectedMonitorId,
    bool clearLastConnectedMonitorId = false,
    String? deviceName,
  }) {
    return AppSessionState(
      lastRole: lastRole ?? this.lastRole,
      monitoringEnabled: monitoringEnabled ?? this.monitoringEnabled,
      lastConnectedMonitorId: clearLastConnectedMonitorId
          ? null
          : (lastConnectedMonitorId ?? this.lastConnectedMonitorId),
      deviceName: deviceName ?? this.deviceName,
    );
  }

  Map<String, dynamic> toJson() => {
    'lastRole': lastRole?.name,
    'monitoringEnabled': monitoringEnabled,
    'lastConnectedMonitorId': lastConnectedMonitorId,
    'deviceName': deviceName,
  };

  factory AppSessionState.fromJson(
    Map<String, dynamic> json, {
    String? defaultDeviceName,
    bool? isAndroidOverride,
  }) {
    final roleStr = json['lastRole'] as String?;
    DeviceRole? role;
    if (roleStr != null) {
      role = DeviceRole.values.where((r) => r.name == roleStr).firstOrNull;
    }
    final deviceName = json['deviceName'] as String?;
    final isAndroid = isAndroidOverride ?? Platform.isAndroid;
    final resolvedDeviceName =
        deviceName == null ||
            deviceName.trim().isEmpty ||
            (isAndroid && _looksLikeLocalhost(deviceName))
        ? (defaultDeviceName ?? getDeviceHostname())
        : deviceName;
    return AppSessionState(
      lastRole: role,
      monitoringEnabled: json['monitoringEnabled'] as bool? ?? true,
      lastConnectedMonitorId: json['lastConnectedMonitorId'] as String?,
      deviceName: resolvedDeviceName,
    );
  }
}

/// Repository for persisting application session state.
class AppSessionRepository {
  AppSessionRepository({
    this.overrideDirectoryPath,
    this.deviceNameResolver,
    this.isAndroidOverride,
  });

  final String? overrideDirectoryPath;
  final Future<String> Function()? deviceNameResolver;
  final bool? isAndroidOverride;
  Future<Directory>? _cachedDirectory;

  Future<File> _file() async {
    final dir = await _directory();
    await dir.create(recursive: true);
    return File('${dir.path}/app_session.json');
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

  Future<String> _defaultDeviceName() {
    final resolver = deviceNameResolver;
    if (resolver != null) return resolver();
    return resolveDefaultDeviceName(isAndroidOverride: isAndroidOverride);
  }

  Future<AppSessionState> load() async {
    final defaultDeviceName = await _defaultDeviceName();
    final file = await _file();
    if (!await file.exists()) {
      return AppSessionState(deviceName: defaultDeviceName);
    }
    try {
      final contents = await file.readAsString();
      final data = jsonDecode(contents) as Map<String, dynamic>;
      return AppSessionState.fromJson(
        data,
        defaultDeviceName: defaultDeviceName,
        isAndroidOverride: isAndroidOverride,
      );
    } catch (_) {
      return AppSessionState(deviceName: defaultDeviceName);
    }
  }

  Future<void> save(AppSessionState state) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(state.toJson()));
  }
}
