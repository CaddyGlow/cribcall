import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../control/control_client.dart' as client;
import '../../control/control_service.dart';
import '../../domain/models.dart';
import '../../identity/device_identity.dart';
import '../../sound/audio_playback.dart';
import '../../state/app_state.dart';
import '../../state/connected_monitor_settings.dart';
import '../../theme.dart';
import '../../util/format_utils.dart';
import '../../webrtc/webrtc_controller.dart';
import '../shared/widgets/widgets.dart';
import 'listener_pin_page.dart';
import 'listener_scan_qr_page.dart';
import 'widgets/widgets.dart';

/// Listener dashboard - orchestrator for displaying paired monitors
/// with inline playback and per-monitor settings.
class ListenerDashboard extends ConsumerStatefulWidget {
  const ListenerDashboard({super.key});

  @override
  ConsumerState<ListenerDashboard> createState() => _ListenerDashboardState();
}

class _ListenerDashboardState extends ConsumerState<ListenerDashboard> {
  String? _activeMonitorId;
  StreamSubscription<Uint8List>? _audioDataSubscription;
  AudioPlaybackService? _audioPlayback;
  ProviderSubscription<AsyncValue<ListenerSettings>>? _listenerSettingsSub;
  Timer? _pinTimer;
  bool _startingPlayback = false;
  bool _sessionRestoreAttempted = false;

  @override
  void initState() {
    super.initState();
    _initAudioPlayback();
    _listenerSettingsSub = ref.listenManual<AsyncValue<ListenerSettings>>(
      listenerSettingsProvider,
      (previous, next) {
        final settings = next.asData?.value;
        if (settings != null) {
          _applyPlaybackVolume(settings.playbackVolume);
        }
      },
    );
    _applyCurrentPlaybackVolume();
    _attemptSessionRestore();
  }

  /// Attempt to reconnect to the last connected monitor on startup.
  Future<void> _attemptSessionRestore() async {
    if (_sessionRestoreAttempted) return;
    _sessionRestoreAttempted = true;

    final session = await ref.read(appSessionProvider.future);
    final lastMonitorId = session.lastConnectedMonitorId;
    if (lastMonitorId == null) return;

    // Wait for trusted monitors and identity to be available
    final monitors = await ref.read(trustedMonitorsProvider.future);
    final identity = await ref.read(identityProvider.future);

    final monitor = monitors
        .where((m) => m.remoteDeviceId == lastMonitorId)
        .firstOrNull;
    if (monitor == null) return;

    // Check if we can find the monitor via mDNS
    final advertisements = ref.read(discoveredMonitorsProvider);
    final ad = advertisements
        .where((a) => a.remoteDeviceId == lastMonitorId)
        .firstOrNull;
    if (ad == null) return;

    // Auto-reconnect
    if (!mounted) return;
    await ref
        .read(controlClientProvider.notifier)
        .connectToMonitor(
          advertisement: ad,
          monitor: monitor,
          identity: identity,
        );
  }

  void _initAudioPlayback() {
    _audioDataSubscription = ref
        .read(streamingProvider.notifier)
        .audioDataStream
        .listen(_onAudioData);
  }

  void _onAudioData(Uint8List data) {
    if (_audioPlayback == null ||
        (!_audioPlayback!.isRunning && !_startingPlayback)) {
      _audioPlayback ??= AudioPlaybackService();
      _startingPlayback = true;
      _audioPlayback!.start().then((_) {
        _startingPlayback = false;
        _applyCurrentPlaybackVolume();
      });
    }
    _applyCurrentPlaybackVolume();
    _audioPlayback?.write(data);
  }

  void _startPinTimer() {
    _pinTimer?.cancel();
    _pinTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      ref.read(streamingProvider.notifier).pinStream();
    });
  }

  void _stopPinTimer() {
    _pinTimer?.cancel();
    _pinTimer = null;
  }

  void _applyCurrentPlaybackVolume() {
    final settings = ref.read(listenerSettingsProvider).asData?.value;
    if (settings != null) {
      _applyPlaybackVolume(settings.playbackVolume);
    }
  }

  void _applyPlaybackVolume(int volumePercent) {
    final factor = (volumePercent.clamp(0, 200)) / 100.0;
    _audioPlayback?.setVolume(factor);
  }

  @override
  void dispose() {
    _stopPinTimer();
    _audioDataSubscription?.cancel();
    _audioPlayback?.stop();
    _listenerSettingsSub?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final advertisements = ref.watch(discoveredMonitorsProvider);
    final trustedMonitors = ref.watch(trustedMonitorsProvider);
    final identity = ref.watch(identityProvider);
    final pinned = trustedMonitors.maybeWhen(
      data: (list) => list,
      orElse: () => <TrustedMonitor>[],
    );

    // Get control client state for connection status
    final controlClientState = ref.watch(controlClientProvider);
    final connectedMonitorId = controlClientState.remoteDeviceId;
    final isControlConnected =
        controlClientState.status == ControlClientStatus.connected;
    final isControlConnecting =
        controlClientState.status == ControlClientStatus.connecting;

    // Separate trusted from discovered
    final trustedData = <MonitorItemData>[];
    final discoveredData = <MonitorItemData>[];
    _buildMonitorLists(
      advertisements,
      pinned,
      trustedData,
      discoveredData,
      connectedMonitorId: connectedMonitorId,
      isControlConnected: isControlConnected,
      isControlConnecting: isControlConnecting,
    );

    // Manage pin timer based on streaming state
    final streamState = ref.watch(streamingProvider);
    final isStreaming = streamState.status == StreamingStatus.connected;
    if (isStreaming && _pinTimer == null) {
      _startPinTimer();
    } else if (!isStreaming) {
      _stopPinTimer();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with settings button
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Listener controls',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            IconButton(
              onPressed: () => _showNoiseSettingsDrawer(context),
              icon: const Icon(Icons.tune, size: 22),
              tooltip: 'Noise detection settings',
              style: IconButton.styleFrom(
                backgroundColor: AppColors.primary.withValues(alpha: 0.1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Trusted monitors card
        _buildTrustedMonitorsCard(context, trustedData, identity, pinned),
        const SizedBox(height: 14),

        // Discovery & pairing card
        _buildDiscoveryCard(context, discoveredData),
      ],
    );
  }

  void _buildMonitorLists(
    List<MdnsAdvertisement> advertisements,
    List<TrustedMonitor> pinned,
    List<MonitorItemData> trustedData,
    List<MonitorItemData> discoveredData, {
    String? connectedMonitorId,
    bool isControlConnected = false,
    bool isControlConnecting = false,
  }) {
    // Process discovered advertisements
    for (final ad in advertisements) {
      final pinnedMonitor = pinned.cast<TrustedMonitor?>().firstWhere(
        (p) => p?.remoteDeviceId == ad.remoteDeviceId,
        orElse: () => null,
      );
      final isTrusted = pinnedMonitor != null;
      final isThisConnected =
          isControlConnected && connectedMonitorId == ad.remoteDeviceId;
      final isThisConnecting =
          isControlConnecting && connectedMonitorId == ad.remoteDeviceId;

      final data = MonitorItemData(
        remoteDeviceId: ad.remoteDeviceId,
        name: ad.monitorName,
        status: 'Online',
        lastNoiseEpochMs: pinnedMonitor?.lastNoiseEpochMs,
        lastSeenEpochMs: pinnedMonitor?.lastSeenEpochMs,
        fingerprint: ad.certFingerprint,
        trusted: isTrusted,
        trustedMonitor: pinnedMonitor,
        lastKnownIp: ad.ip ?? pinnedMonitor?.lastKnownIp,
        advertisement: ad,
        connectTarget: ad,
        isConnected: isThisConnected,
        isConnecting: isThisConnecting,
        onConnect: isTrusted
            ? () => _handleConnect(ad.remoteDeviceId, ad, pinnedMonitor, ad)
            : null,
        onDisconnect: isThisConnected ? _handleDisconnect : null,
        onListen: isThisConnected
            ? () => ref.read(streamingProvider.notifier).requestStream()
            : null,
        onStop: _handleStop,
        onForget: isTrusted
            ? () => _forgetMonitor(pinnedMonitor, advertisement: ad)
            : null,
        onPair: () => _showPairSheet(ad),
        onSettings: isTrusted
            ? () => showMonitorSettingsSheet(
                context,
                remoteDeviceId: ad.remoteDeviceId,
                monitorName: ad.monitorName,
              )
            : null,
      );

      if (isTrusted) {
        trustedData.add(data);
      } else {
        discoveredData.add(data);
      }
    }

    // Add offline pinned monitors
    for (final monitor in pinned) {
      if (advertisements.any(
        (ad) => ad.remoteDeviceId == monitor.remoteDeviceId,
      )) {
        continue;
      }
      final fallback = _fallbackAdvertisement(monitor);
      final isThisConnected =
          isControlConnected && connectedMonitorId == monitor.remoteDeviceId;
      final isThisConnecting =
          isControlConnecting && connectedMonitorId == monitor.remoteDeviceId;

      trustedData.add(
        MonitorItemData(
          remoteDeviceId: monitor.remoteDeviceId,
          name: monitor.monitorName,
          status: 'Offline',
          lastNoiseEpochMs: monitor.lastNoiseEpochMs,
          lastSeenEpochMs: monitor.lastSeenEpochMs,
          fingerprint: monitor.certFingerprint,
          trusted: true,
          trustedMonitor: monitor,
          lastKnownIp: monitor.lastKnownIp,
          advertisement: null,
          connectTarget: fallback,
          isConnected: isThisConnected,
          isConnecting: isThisConnecting,
          onConnect: fallback != null
              ? () => _handleConnect(
                  monitor.remoteDeviceId,
                  null,
                  monitor,
                  fallback,
                )
              : null,
          onDisconnect: isThisConnected ? _handleDisconnect : null,
          onListen: isThisConnected
              ? () => ref.read(streamingProvider.notifier).requestStream()
              : null,
          onStop: _handleStop,
          onForget: () => _forgetMonitor(monitor, advertisement: fallback),
          onSettings: () => showMonitorSettingsSheet(
            context,
            remoteDeviceId: monitor.remoteDeviceId,
            monitorName: monitor.monitorName,
          ),
        ),
      );
    }
  }

  MdnsAdvertisement? _fallbackAdvertisement(TrustedMonitor monitor) {
    // Try lastKnownIp first, then fall back to first known IP from QR pairing
    final ip = monitor.lastKnownIp ?? monitor.knownIps?.firstOrNull;
    if (ip == null) return null;
    return MdnsAdvertisement(
      remoteDeviceId: monitor.remoteDeviceId,
      monitorName: monitor.monitorName,
      certFingerprint: monitor.certFingerprint,
      controlPort: monitor.controlPort,
      pairingPort: monitor.pairingPort,
      version: monitor.serviceVersion,
      transport: monitor.transport,
      ip: ip,
    );
  }

  Future<void> _forgetMonitor(
    TrustedMonitor monitor, {
    MdnsAdvertisement? advertisement,
  }) async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Forget monitor?'),
            content: Text(
              'Remove ${monitor.monitorName} from trusted list? You will need to re-pair.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Forget'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;

    final identity = ref.read(identityProvider).asData?.value;
    final target = advertisement ?? _fallbackAdvertisement(monitor);
    bool unpaired = false;

    if (identity != null && target?.ip != null) {
      final unpairClient = client.ControlClient(identity: identity);
      unpaired = await unpairClient.requestUnpair(
        host: target!.ip!,
        port: target.controlPort,
        expectedFingerprint: monitor.certFingerprint,
        deviceId: identity.deviceId,
      );
    }

    await ref
        .read(trustedMonitorsProvider.notifier)
        .removeMonitor(monitor.remoteDeviceId);
    await ref
        .read(connectedMonitorSettingsProvider.notifier)
        .removeSettings(monitor.remoteDeviceId);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          unpaired
              ? 'Unpaired and forgot ${monitor.monitorName}'
              : 'Forgot ${monitor.monitorName}',
        ),
      ),
    );
  }

  /// Connect to a monitor's control server (for receiving notifications).
  Future<void> _handleConnect(
    String remoteDeviceId,
    MdnsAdvertisement? advertisement,
    TrustedMonitor trustedMonitor,
    MdnsAdvertisement connectTarget,
  ) async {
    final identity = ref.read(identityProvider);

    if (!identity.hasValue) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Loading device identity; try again in a moment'),
        ),
      );
      return;
    }

    // Set active monitor
    setState(() => _activeMonitorId = remoteDeviceId);

    final failure = await ref
        .read(controlClientProvider.notifier)
        .connectToMonitor(
          advertisement: connectTarget,
          monitor: trustedMonitor,
          identity: identity.requireValue,
        );

    if (!mounted) return;
    if (failure != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Connect failed: $failure')));
      setState(() => _activeMonitorId = null);
    }
  }

  /// Disconnect from the current monitor.
  void _handleDisconnect() {
    // Stop streaming first if active
    final streamState = ref.read(streamingProvider);
    if (streamState.status == StreamingStatus.connected ||
        streamState.status == StreamingStatus.connecting) {
      ref.read(streamingProvider.notifier).endStream();
    }
    _stopPinTimer();
    _audioPlayback?.stop();

    // Disconnect control connection
    ref.read(controlClientProvider.notifier).disconnect();
    setState(() => _activeMonitorId = null);
  }

  void _handleStop() {
    ref.read(streamingProvider.notifier).endStream();
    _stopPinTimer();
    _audioPlayback?.stop();
    setState(() => _activeMonitorId = null);
  }

  Future<void> _showPairSheet(MdnsAdvertisement advertisement) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListenerPinPage(advertisement: advertisement),
    );
  }

  /// Show the global noise detection settings drawer.
  void _showNoiseSettingsDrawer(BuildContext context) {
    showNoiseSettingsDrawer(context);
  }

  Widget _buildTrustedMonitorsCard(
    BuildContext context,
    List<MonitorItemData> monitors,
    AsyncValue<DeviceIdentity> identity,
    List<TrustedMonitor> pinned,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Trusted monitors',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                identity.maybeWhen(
                  data: (id) => PinnedBadge(fingerprint: id.certFingerprint),
                  orElse: () => const PinnedBadge(),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Server pinning protects against MITM attacks.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: 14),

            // Monitor list
            if (monitors.isEmpty)
              CcEmptyState(
                icon: Icons.podcasts_outlined,
                title: 'No paired monitors',
                description: 'Scan a QR code or browse the network to pair.',
              )
            else
              ...monitors.map(
                (m) => TrustedMonitorItem(
                  data: m,
                  isActive: _activeMonitorId == m.remoteDeviceId,
                ),
              ),

            const SizedBox(height: 8),
            Text(
              'Paired: ${pinned.length}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  void _showDiscoveredMonitorsDrawer(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.85,
        expand: false,
        builder: (context, scrollController) => Consumer(
          builder: (context, ref, _) {
            // Watch providers reactively so drawer updates in real-time
            final advertisements = ref.watch(discoveredMonitorsProvider);
            final trustedMonitors = ref.watch(trustedMonitorsProvider);
            final pinned = trustedMonitors.maybeWhen(
              data: (list) => list,
              orElse: () => <TrustedMonitor>[],
            );
            final pinnedIds = pinned.map((m) => m.remoteDeviceId).toSet();

            // Filter to only unpaired monitors
            final monitors = advertisements
                .where((ad) => !pinnedIds.contains(ad.remoteDeviceId))
                .map(
                  (ad) => MonitorItemData(
                    remoteDeviceId: ad.remoteDeviceId,
                    name: ad.monitorName,
                    status: 'Online',
                    fingerprint: ad.certFingerprint,
                    trusted: false,
                    advertisement: ad,
                    onPair: () => _showPairSheet(ad),
                  ),
                )
                .toList();

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Discovered monitors',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CcBadge(
                            label: '${monitors.length} found',
                            color: AppColors.primary,
                            size: CcBadgeSize.small,
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: () {
                              ref.invalidate(mdnsBrowseProvider);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Refreshing mDNS discovery...'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            },
                            icon: const Icon(Icons.refresh, size: 20),
                            tooltip: 'Refresh',
                            style: IconButton.styleFrom(
                              padding: const EdgeInsets.all(8),
                              minimumSize: const Size(32, 32),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Monitors found on your network that are not yet paired.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: monitors.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.wifi_find,
                                  size: 48,
                                  color: AppColors.muted.withValues(alpha: 0.5),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'No monitors found',
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.muted,
                                      ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Make sure monitors are running on your network',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: AppColors.muted),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            controller: scrollController,
                            itemCount: monitors.length,
                            itemBuilder: (context, index) =>
                                DiscoveredMonitorItem(data: monitors[index]),
                          ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildDiscoveryCard(
    BuildContext context,
    List<MonitorItemData> discoveredMonitors,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Discovery & pairing',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              'Scan a QR for instant trust or browse mDNS and pair with a 6-digit PIN.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      final scaffoldMessenger = ScaffoldMessenger.of(context);
                      final result = await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ListenerScanQrPage(),
                        ),
                      );
                      if (!mounted) return;
                      if (result is MonitorQrPayload) {
                        scaffoldMessenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              'Pinned ${result.monitorName} (${shortFingerprint(result.certFingerprint)})',
                            ),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.qr_code_2),
                    label: const Text('Scan QR code'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _showDiscoveredMonitorsDrawer(context),
                    icon: const Icon(Icons.wifi_find),
                    label: Text(
                      discoveredMonitors.isEmpty
                          ? 'Browse network'
                          : 'Browse network (${discoveredMonitors.length})',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Row(
              children: [
                Icon(Icons.lock, size: 16, color: AppColors.primary),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Untrusted clients may only send pairing messages.',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
