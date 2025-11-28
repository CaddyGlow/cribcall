import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/build_flags.dart';
import '../../control/control_service.dart';
import '../../discovery/mdns_service.dart';
import '../../domain/models.dart';
import '../../identity/device_identity.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../util/format_utils.dart';
import '../../utils/network_utils.dart';
import '../shared/widgets/widgets.dart';
import 'widgets/widgets.dart';

void _log(String message) {
  developer.log(message, name: 'monitor_dashboard');
  debugPrint('[monitor_dashboard] $message');
}

/// Refactored Monitor Dashboard using shared components.
class MonitorDashboard extends ConsumerStatefulWidget {
  const MonitorDashboard({super.key});

  @override
  ConsumerState<MonitorDashboard> createState() => _MonitorDashboardState();
}

class _MonitorDashboardState extends ConsumerState<MonitorDashboard> {
  MdnsAdvertisement? _currentAdvertisement;
  bool _advertising = false;
  bool _refreshInProgress = false;
  Timer? _refreshDebounce;
  late final MdnsService _mdnsService;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _mdnsService = ref.read(mdnsServiceProvider);
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _stopAdvertising();
    super.dispose();
  }

  /// Schedule a debounced refresh to avoid multiple rapid calls.
  void _scheduleRefresh({Duration delay = const Duration(milliseconds: 100)}) {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(delay, () {
      _refreshAdvertisement();
    });
  }

  Future<void> _refreshAdvertisement() async {
    _log(
      '_refreshAdvertisement called, mounted=$mounted, inProgress=$_refreshInProgress',
    );
    if (!mounted) return;
    if (_refreshInProgress) {
      _log('_refreshAdvertisement: already in progress, scheduling retry');
      _scheduleRefresh();
      return;
    }
    _refreshInProgress = true;
    try {
      await _doRefreshAdvertisement();
    } finally {
      _refreshInProgress = false;
    }
  }

  Future<void> _doRefreshAdvertisement() async {
    final monitoringEnabled = ref.read(monitoringStatusProvider);
    final identity = ref.read(identityProvider);
    final appSession = ref.read(appSessionProvider);

    _log(
      '_refreshAdvertisement: monitoring=$monitoringEnabled '
      'identity.hasValue=${identity.hasValue} '
      'appSession.hasValue=${appSession.hasValue}',
    );

    if (!monitoringEnabled) {
      _log('_refreshAdvertisement: monitoring disabled, stopping');
      await _stopAdvertising();
      return;
    }

    final readyValues = await _awaitIdentityAndSession(
      identity: identity,
      appSession: appSession,
    );

    if (readyValues == null) {
      if (_isAndroid) {
        _log('_refreshAdvertisement: waiting for identity/appSession, will retry');
        _scheduleRefresh(delay: const Duration(seconds: 1));
        return;
      }
      _log('_refreshAdvertisement: conditions not met, stopping');
      await _stopAdvertising();
      return;
    }

    final builder = ref.read(serviceIdentityProvider);
    final controlState = ref.read(controlServerProvider);
    final pairingState = ref.read(pairingServerProvider);
    final controlPort = controlState.port ?? builder.defaultPort;
    final pairingPort = pairingState.port ?? builder.defaultPairingPort;
    final nextAd = builder.buildMdnsAdvertisement(
      identity: readyValues.identity,
      monitorName: readyValues.appSession.deviceName,
      controlPort: controlPort,
      pairingPort: pairingPort,
    );

    _log(
      '_refreshAdvertisement: nextAd remoteDeviceId=${nextAd.remoteDeviceId} '
      'controlPort=$controlPort pairingPort=$pairingPort '
      'already advertising=$_advertising',
    );

    if (_advertising &&
        _currentAdvertisement != null &&
        _adsEqual(_currentAdvertisement!, nextAd)) {
      _log('_refreshAdvertisement: same ad, skipping');
      return;
    }

    await _stopAdvertising();
    try {
      _log('_refreshAdvertisement: calling startAdvertise...');
      await _mdnsService.startAdvertise(nextAd);
      _currentAdvertisement = nextAd;
      _advertising = true;
      _log('_refreshAdvertisement: SUCCESS, now advertising');
    } catch (e) {
      _log('startAdvertise failed: $e');
    }
  }

  Future<void> _stopAdvertising() async {
    if (!_advertising) return;
    await _mdnsService.stop();
    _advertising = false;
    _currentAdvertisement = null;
  }

  bool _adsEqual(MdnsAdvertisement a, MdnsAdvertisement b) {
    return a.remoteDeviceId == b.remoteDeviceId &&
        a.monitorName == b.monitorName &&
        a.certFingerprint == b.certFingerprint &&
        a.controlPort == b.controlPort &&
        a.pairingPort == b.pairingPort &&
        a.version == b.version &&
        a.transport == b.transport;
  }

  Future<({DeviceIdentity identity, AppSessionState appSession})?>
      _awaitIdentityAndSession({
        required AsyncValue<DeviceIdentity> identity,
        required AsyncValue<AppSessionState> appSession,
      }) async {
    if (identity.hasValue && appSession.hasValue) {
      return (
        identity: identity.requireValue,
        appSession: appSession.requireValue,
      );
    }

    if (!_isAndroid) return null;

    _log('_refreshAdvertisement: waiting for identity/appSession on Android');
    try {
      await Future.wait([
        if (!identity.hasValue) ref.read(identityProvider.future),
        if (!appSession.hasValue) ref.read(appSessionProvider.future),
      ]).timeout(const Duration(seconds: 5));
    } catch (err) {
      _log('_refreshAdvertisement: identity/appSession wait timed out: $err');
      return null;
    }

    final refreshedIdentity = ref.read(identityProvider);
    final refreshedAppSession = ref.read(appSessionProvider);
    if (refreshedIdentity.hasValue && refreshedAppSession.hasValue) {
      return (
        identity: refreshedIdentity.requireValue,
        appSession: refreshedAppSession.requireValue,
      );
    }

    _log('_refreshAdvertisement: identity/appSession still missing after wait');
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Trigger auto-start providers
    // Note: On Android, audioCaptureAutoStartProvider handles mDNS via foreground service
    ref.watch(controlServerAutoStartProvider);
    ref.watch(audioCaptureAutoStartProvider);

    // Watch providers for advertisement (Linux/iOS mDNS)
    final identityForAd = ref.watch(identityProvider);
    final appSessionForAd = ref.watch(appSessionProvider);
    final monitoringForAd = ref.watch(monitoringStatusProvider);

    // Refresh advertisement when dependencies change (for non-Android platforms)
    // Use _scheduleRefresh to debounce multiple rapid changes
    ref.listen<AsyncValue<DeviceIdentity>>(identityProvider, (prev, next) {
      _scheduleRefresh();
    });
    ref.listen<AsyncValue<AppSessionState>>(appSessionProvider, (prev, next) {
      _scheduleRefresh();
    });
    ref.listen<bool>(monitoringStatusProvider, (prev, next) {
      _scheduleRefresh();
    });

    // Schedule initial advertisement for non-Android platforms
    if (identityForAd.hasValue &&
        appSessionForAd.hasValue &&
        monitoringForAd &&
        !_advertising) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduleRefresh();
      });
    }

    final monitoringEnabled = ref.watch(monitoringStatusProvider);
    final settingsAsync = ref.watch(monitorSettingsProvider);
    final settings = settingsAsync.asData?.value ?? MonitorSettings.defaults;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Monitor controls',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),

        // Main monitoring card
        _MonitoringControlsCard(
          monitoringEnabled: monitoringEnabled,
          settings: settings,
          isLoading: settingsAsync.isLoading,
        ),

        const SizedBox(height: 14),

        // Pairing & Identity card
        const _PairingIdentityCard(),

        const SizedBox(height: 14),

        // Trusted listeners card
        const _TrustedListenersCard(),

        const SizedBox(height: 14),

        // Control channel status
        const _ControlStatusCard(),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Monitoring Controls Card
// ---------------------------------------------------------------------------

class _MonitoringControlsCard extends ConsumerWidget {
  const _MonitoringControlsCard({
    required this.monitoringEnabled,
    required this.settings,
    required this.isLoading,
  });

  final bool monitoringEnabled;
  final MonitorSettings settings;
  final bool isLoading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioCaptureState = ref.watch(audioCaptureProvider);
    final isDebugCapture = ref
        .watch(audioCaptureProvider.notifier)
        .isDebugCapture;
    final appSession = ref.watch(appSessionProvider);
    final deviceDisplayName =
        appSession.asData?.value.displayName ?? 'Loading...';
    final audioDevices = ref.watch(audioInputDevicesProvider);

    return CcCard(
      title: monitoringEnabled ? 'Monitoring ON' : 'Monitoring OFF',
      subtitle:
          'Runs sound detection locally. No audio leaves the device unless a trusted listener opens a stream.',
      badge: monitoringEnabled ? 'Live' : 'Stopped',
      badgeColor: monitoringEnabled ? AppColors.success : AppColors.warning,
      trailing: Switch(
        value: monitoringEnabled,
        thumbColor: WidgetStatePropertyAll(AppColors.primary),
        onChanged: (value) =>
            ref.read(monitoringStatusProvider.notifier).toggle(value),
      ),
      children: [
        if (isLoading)
          const Padding(
            padding: EdgeInsets.only(bottom: 8.0),
            child: LinearProgressIndicator(minHeight: 2),
          ),

        // Listening indicator
        const ListeningIndicator(),
        const SizedBox(height: 12),

        // Current settings summary
        CcMetricRow(label: 'Device name', value: deviceDisplayName),
        CcMetricRow(
          label: 'Input device',
          valueWidget: audioDevices.when(
            data: (devices) => _buildInputDeviceValue(
              context,
              ref,
              devices,
              settings.audioInputDeviceId,
            ),
            loading: () => const Text('Loading devices...'),
            error: (error, _) => Row(
              children: [
                Expanded(
                  child: Text(
                    'Devices unavailable',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => ref.refresh(audioInputDevicesProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
        CcMetricRow(
          label: 'Noise threshold',
          value:
              '${settings.noise.threshold}% (${_thresholdToDb(settings.noise.threshold)})',
        ),
        CcMetricRow(
          label: 'Auto-stream',
          value:
              '${_autoStreamLabel(settings.autoStreamType)} for ${settings.autoStreamDurationSec}s',
        ),

        const Divider(height: 24),

        // Testing section
        Row(
          children: [
            Text(
              'Audio monitor',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 8),
            if (isDebugCapture)
              CcBadge(
                label: 'SYNTHETIC',
                color: Colors.orange,
                size: CcBadgeSize.small,
              ),
          ],
        ),
        const SizedBox(height: 8),

        // Audio waveform
        if (monitoringEnabled) ...[
          AudioWaveform(
            levelHistory: audioCaptureState.levelHistory,
            currentLevel: audioCaptureState.level,
            threshold: settings.noise.threshold,
            isDebugCapture: isDebugCapture,
          ),
          const SizedBox(height: 12),
        ],

        // Test buttons
        _TestButtons(isDebugCapture: isDebugCapture),
      ],
    );
  }
}

class _TestButtons extends ConsumerWidget {
  const _TestButtons({required this.isDebugCapture});

  final bool isDebugCapture;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controlServer = ref.watch(controlServerProvider);
    final monitoringEnabled = ref.watch(monitoringStatusProvider);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: controlServer.status == ControlServerStatus.running
              ? () {
                  final timestampMs = DateTime.now().millisecondsSinceEpoch;
                  ref
                      .read(controlServerProvider.notifier)
                      .broadcastNoiseEvent(
                        timestampMs: timestampMs,
                        peakLevel: 75,
                      );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Test noise event sent'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              : null,
          icon: const Icon(Icons.volume_up),
          label: const Text('Send Test Noise Event'),
        ),
        if (isDebugCapture)
          OutlinedButton.icon(
            onPressed: monitoringEnabled
                ? () {
                    ref.read(audioCaptureProvider.notifier).injectTestNoise();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Injecting synthetic noise...'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                : null,
            icon: const Icon(Icons.graphic_eq),
            label: const Text('Inject Synthetic Noise'),
          ),
      ],
    );
  }
}

Widget _buildInputDeviceValue(
  BuildContext context,
  WidgetRef ref,
  List<AudioInputDevice> devices,
  String? currentDeviceId,
) {
  if (devices.isEmpty) {
    return Row(
      children: [
        const Expanded(child: Text('No devices found')),
        TextButton(
          onPressed: () => ref.refresh(audioInputDevicesProvider),
          child: const Text('Refresh'),
        ),
      ],
    );
  }

  final selected = _resolveSelectedDevice(devices, currentDeviceId);
  final label = selected.name;
  final displayLabel = selected.isDefault ? '$label (default)' : label;

  return Row(
    children: [
      Expanded(
        child: Text(
          displayLabel,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      TextButton(
        onPressed: () => showDeviceInputSettingsModal(
          context,
          currentDeviceId: currentDeviceId,
          onDeviceSelected: (deviceId) {
            ref
                .read(monitorSettingsProvider.notifier)
                .setAudioInputDeviceId(deviceId);
          },
        ),
        child: const Text('Change'),
      ),
    ],
  );
}

AudioInputDevice _resolveSelectedDevice(
  List<AudioInputDevice> devices,
  String? currentDeviceId,
) {
  if (currentDeviceId == null) {
    return devices.firstWhere((d) => d.isDefault, orElse: () => devices.first);
  }

  return devices.firstWhere(
    (d) => d.id == currentDeviceId,
    orElse: () =>
        devices.firstWhere((d) => d.isDefault, orElse: () => devices.first),
  );
}

// ---------------------------------------------------------------------------
// Pairing & Identity Card
// ---------------------------------------------------------------------------

class _PairingIdentityCard extends ConsumerWidget {
  const _PairingIdentityCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(identityProvider);
    final appSession = ref.watch(appSessionProvider);
    final serviceBuilder = ref.watch(serviceIdentityProvider);
    final pairingServer = ref.watch(pairingServerProvider);

    return CcCard(
      title: 'Pairing & identity',
      subtitle:
          'Share a QR or run PIN-based pairing. Listeners must pin this device fingerprint before any control traffic is accepted.',
      badge: 'Pinned cert',
      badgeColor: AppColors.primary,
      children: [
        identity.when(
          data: (id) => CcMetricRow(
            label: 'Device fingerprint',
            value: shortFingerprint(id.certFingerprint),
          ),
          loading: () => const CcMetricRow(
            label: 'Device fingerprint',
            value: 'loading...',
          ),
          error: (err, st) =>
              const CcMetricRow(label: 'Device fingerprint', value: 'error'),
        ),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () async {
                  if (!identity.hasValue || !appSession.hasValue) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Identity still loading')),
                    );
                    return;
                  }
                  // Generate one-time pairing token for QR code flow
                  final pairingToken = ref
                      .read(pairingServerProvider.notifier)
                      .generatePairingToken();
                  if (pairingToken == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Pairing server not ready')),
                    );
                    return;
                  }
                  final deviceName = appSession.requireValue.deviceName;
                  final ips = await getLocalIpAddresses();
                  final payload = serviceBuilder.qrPayloadString(
                    identity: identity.requireValue,
                    monitorName: deviceName,
                    ips: ips,
                    pairingToken: pairingToken,
                  );
                  final payloadJson = serviceBuilder
                      .buildQrPayload(
                        identity: identity.requireValue,
                        monitorName: deviceName,
                        ips: ips,
                        pairingToken: pairingToken,
                      )
                      .toJson();
                  if (!context.mounted) return;
                  showPairingQrSheet(
                    context,
                    payload: payload,
                    payloadJson: payloadJson,
                  );
                },
                icon: const Icon(Icons.qr_code),
                label: const Text('Show pairing QR'),
              ),
            ),
          ],
        ),
        if (pairingServer.activeSession != null) ...[
          const SizedBox(height: 8),
          PairingSessionBanner(
            session: pairingServer.activeSession!,
            onAccept: () {
              ref
                  .read(pairingServerProvider.notifier)
                  .confirmSession(pairingServer.activeSession!.sessionId);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Pairing accepted - waiting for listener to confirm',
                  ),
                ),
              );
            },
            onReject: () {
              ref
                  .read(pairingServerProvider.notifier)
                  .rejectSession(pairingServer.activeSession!.sessionId);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Pairing rejected')));
            },
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Trusted Listeners Card
// ---------------------------------------------------------------------------

class _TrustedListenersCard extends ConsumerWidget {
  const _TrustedListenersCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trustedPeers = ref.watch(trustedListenersProvider);

    return CcCard(
      title: 'Trusted listeners',
      subtitle: 'Pinned fingerprints are required on every control session.',
      badge: 'mTLS required',
      badgeColor: AppColors.primary,
      children: [
        trustedPeers.when(
          data: (peers) => peers.isEmpty
              ? const Text('No trusted listeners yet.')
              : Column(
                  children: peers
                      .map(
                        (peer) => TrustedListenerRow(
                          name: peer.name,
                          fingerprint: peer.certFingerprint,
                          onRevoke: () => _confirmRevoke(context, ref, peer),
                        ),
                      )
                      .toList(),
                ),
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(minHeight: 2),
          ),
          error: (err, st) => Text(
            'Could not load trusted listeners',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.red),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmRevoke(
    BuildContext context,
    WidgetRef ref,
    TrustedPeer peer,
  ) async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Revoke listener?'),
            content: Text(
              'Remove ${peer.name}? They must re-pair before connecting again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Revoke'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed) {
      await ref
          .read(trustedListenersProvider.notifier)
          .revoke(peer.remoteDeviceId);
    }
  }
}

// ---------------------------------------------------------------------------
// Control Status Card
// ---------------------------------------------------------------------------

class _ControlStatusCard extends ConsumerWidget {
  const _ControlStatusCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serviceBuilder = ref.watch(serviceIdentityProvider);
    final controlServer = ref.watch(controlServerProvider);
    final trustedPeers = ref.watch(trustedListenersProvider);

    return CcCard(
      title: 'Control channel status',
      subtitle:
          'HTTP+WebSocket control (TLS ${serviceBuilder.defaultPort}), nonce+signature handshake and pinned fingerprint.',
      badge: 'HTTP+WS',
      badgeColor: AppColors.primary,
      children: [
        CcMetricRow(label: 'Status', value: _serverStatusLabel(controlServer)),
        CcMetricRow(
          label: 'Active connections',
          value: '${controlServer.activeConnectionsCount}',
        ),
        CcMetricRow(
          label: 'Trusted listeners',
          value:
              '${trustedPeers.maybeWhen(data: (list) => list.length, orElse: () => 0)} pinned',
        ),
        const CcMetricRow(
          label: 'Streams',
          value: 'Control (bi-dir) + media via WebRTC',
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _autoStreamLabel(AutoStreamType type) {
  switch (type) {
    case AutoStreamType.none:
      return 'Off';
    case AutoStreamType.audio:
      return 'Audio';
    case AutoStreamType.audioVideo:
      return 'Audio + video';
  }
}

String _thresholdToDb(int threshold) {
  final db = (threshold * 60 / 100) - 60;
  return '${db.round()}dB';
}

String _serverStatusLabel(ControlServerState state) {
  switch (state.status) {
    case ControlServerStatus.running:
      return 'Running on ${state.port ?? kControlDefaultPort} (HTTP+WS)';
    case ControlServerStatus.starting:
      return 'Starting...';
    case ControlServerStatus.error:
      return 'Error: ${state.error ?? 'unknown'}';
    case ControlServerStatus.stopped:
      return 'Stopped';
  }
}
