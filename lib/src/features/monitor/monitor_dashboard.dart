import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../config/build_flags.dart';
import '../../domain/models.dart';
import '../../discovery/mdns_service.dart';
import '../../identity/device_identity.dart';
import '../../pairing/pin_pairing_controller.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../control/control_service.dart';

void _logMonitorDashboard(String message) {
  developer.log(message, name: 'monitor_dashboard');
  debugPrint('[monitor_dashboard] $message');
}

class MonitorDashboard extends ConsumerStatefulWidget {
  const MonitorDashboard({super.key});

  @override
  ConsumerState<MonitorDashboard> createState() => _MonitorDashboardState();
}

class _MonitorDashboardState extends ConsumerState<MonitorDashboard> {
  MdnsAdvertisement? _currentAdvertisement;
  bool _advertising = false;
  bool _listenersAttached = false;
  late final MdnsService _mdnsService;

  @override
  void initState() {
    super.initState();
    _mdnsService = ref.read(mdnsServiceProvider);
  }

  @override
  void dispose() {
    _stopAdvertising();
    super.dispose();
  }

  Future<void> _refreshAdvertisement() async {
    if (!mounted) return;
    final monitoringEnabled = ref.read(monitoringStatusProvider);
    final identity = ref.read(identityProvider);
    final settings = ref.read(monitorSettingsProvider);
    if (!monitoringEnabled || !identity.hasValue || !settings.hasValue) {
      await _stopAdvertising();
      return;
    }

    final builder = ref.read(serviceIdentityProvider);
    final controlState = ref.read(controlServerProvider);
    final servicePort = controlState.port ?? builder.defaultPort;
    final nextAd = builder.buildMdnsAdvertisement(
      identity: identity.requireValue,
      monitorName: settings.requireValue.name,
      servicePort: servicePort,
    );

    if (_advertising &&
        _currentAdvertisement != null &&
        _adsEqual(_currentAdvertisement!, nextAd)) {
      return;
    }

    await _stopAdvertising();
    try {
      await _mdnsService.startAdvertise(nextAd);
      _currentAdvertisement = nextAd;
      _advertising = true;
    } catch (_){ 
      // Ignore failures; listener will still show pinned monitors from storage.
    }
  }

  Future<void> _stopAdvertising() async {
    if (!_advertising) return;
    await _mdnsService.stop();
    _advertising = false;
    _currentAdvertisement = null;
  }

  bool _adsEqual(MdnsAdvertisement a, MdnsAdvertisement b) {
    return a.monitorId == b.monitorId &&
        a.monitorName == b.monitorName &&
        a.monitorCertFingerprint == b.monitorCertFingerprint &&
        a.servicePort == b.servicePort &&
        a.version == b.version &&
        a.transport == b.transport;
  }

  @override
  Widget build(BuildContext context) {
    // Trigger control server auto-start based on monitoring + identity + trust.
    ref.watch(controlServerAutoStartProvider);

    if (!_listenersAttached) {
      _listenersAttached = true;
      ref.listen<AsyncValue<DeviceIdentity>>(identityProvider, (_, __) {
        _refreshAdvertisement();
      });
      ref.listen<AsyncValue<MonitorSettings>>(monitorSettingsProvider, (_, __) {
        _refreshAdvertisement();
      });
      ref.listen<bool>(monitoringStatusProvider, (_, __) {
        _refreshAdvertisement();
      });
      ref.listen<AsyncValue<List<TrustedPeer>>>(
        trustedListenersProvider,
        (_, __) {},
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _refreshAdvertisement();
      });
    }
    final monitoringEnabled = ref.watch(monitoringStatusProvider);
    final settingsAsync = ref.watch(monitorSettingsProvider);
    final settings = settingsAsync.asData?.value ?? MonitorSettings.defaults;
    final trustedPeers = ref.watch(trustedListenersProvider);
    final identity = ref.watch(identityProvider);
    final serviceBuilder = ref.watch(serviceIdentityProvider);
    final pinSession = ref.watch(pinSessionProvider);
    final controlServer = ref.watch(controlServerProvider);

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
        _MonitorCard(
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
            TextFormField(
              initialValue: settings.name,
              decoration: const InputDecoration(
                labelText: 'Monitor name',
                hintText: 'Nursery',
              ),
              onChanged: (value) => ref
                  .read(monitorSettingsProvider.notifier)
                  .setName(value.trim()),
            ),
            const SizedBox(height: 8),
            if (settingsAsync.isLoading)
              const Padding(
                padding: EdgeInsets.only(bottom: 8.0),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            _MetricRow(
              label: 'Auto-stream',
              value:
                  '${_autoStreamLabel(settings.autoStreamType)} for ${settings.autoStreamDurationSec}s',
            ),
            const SizedBox(height: 8),
            _SettingsSlider(
              label: 'Noise threshold',
              helper: 'Higher = less sensitive. Persisted locally.',
              value: settings.noise.threshold.toDouble(),
              min: 0,
              max: 100,
              divisions: 20,
              displayValue: '${settings.noise.threshold}',
              onChanged: (v) => ref
                  .read(monitorSettingsProvider.notifier)
                  .setThreshold(v.round()),
            ),
            _SettingsSlider(
              label: 'Min duration (ms)',
              helper: 'Frames above threshold before triggering NOISE_EVENT.',
              value: settings.noise.minDurationMs.toDouble(),
              min: 200,
              max: 2000,
              divisions: 36,
              displayValue: '${settings.noise.minDurationMs} ms',
              onChanged: (v) => ref
                  .read(monitorSettingsProvider.notifier)
                  .setMinDurationMs(v.round()),
            ),
            _SettingsSlider(
              label: 'Cooldown (s)',
              helper: 'Delay before another event fires.',
              value: settings.noise.cooldownSeconds.toDouble(),
              min: 3,
              max: 20,
              divisions: 17,
              displayValue: '${settings.noise.cooldownSeconds}s',
              onChanged: (v) => ref
                  .read(monitorSettingsProvider.notifier)
                  .setCooldownSeconds(v.round()),
            ),
            const SizedBox(height: 6),
            Text(
              'Auto-stream behavior',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: AutoStreamType.values.map((type) {
                final selected = settings.autoStreamType == type;
                return ChoiceChip(
                  label: Text(switch (type) {
                    AutoStreamType.none => 'Off',
                    AutoStreamType.audio => 'Audio',
                    AutoStreamType.audioVideo => 'Audio+Video',
                  }),
                  selected: selected,
                  onSelected: (_) => ref
                      .read(monitorSettingsProvider.notifier)
                      .setAutoStreamType(type),
                );
              }).toList(),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  'Auto-stream duration',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 10),
                DropdownButton<int>(
                  value: settings.autoStreamDurationSec,
                  onChanged: (value) {
                    if (value == null) return;
                    ref
                        .read(monitorSettingsProvider.notifier)
                        .setAutoStreamDuration(value);
                  },
                  items: const [
                    DropdownMenuItem(value: 10, child: Text('10s')),
                    DropdownMenuItem(value: 15, child: Text('15s')),
                    DropdownMenuItem(value: 30, child: Text('30s')),
                    DropdownMenuItem(value: 45, child: Text('45s')),
                  ],
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        _MonitorCard(
          title: 'Pairing & identity',
          subtitle:
              'Share a QR or run PIN-based pairing. Listeners must pin this device fingerprint before any control traffic is accepted.',
          badge: 'Pinned cert',
          badgeColor: AppColors.primary,
          children: [
            identity.when(
              data: (id) => _MetricRow(
                label: 'Device fingerprint',
                value: id.certFingerprint.substring(0, 12),
              ),
              loading: () => const _MetricRow(
                label: 'Device fingerprint',
                value: 'loading...',
              ),
              error: (err, _) =>
                  const _MetricRow(label: 'Device fingerprint', value: 'error'),
            ),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      if (!identity.hasValue) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Identity still loading'),
                          ),
                        );
                        return;
                      }
                      final payload = serviceBuilder.buildQrPayload(
                        identity: identity.requireValue,
                        monitorName: settings.name,
                      );
                      final payloadString = serviceBuilder.qrPayloadString(
                        identity: identity.requireValue,
                        monitorName: settings.name,
                      );
                      _showQrSheet(
                        context,
                        payload: payloadString,
                        payloadJson: payload.toJson(),
                      );
                    },
                    icon: const Icon(Icons.qr_code),
                    label: const Text('Show pairing QR'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      _logMonitorDashboard('Start PIN session button pressed');
                      if (!identity.hasValue) {
                        _logMonitorDashboard('Identity not ready');
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Identity still loading'),
                          ),
                        );
                        return;
                      }
                      try {
                        _logMonitorDashboard(
                          'Starting PIN session for identity=${identity.requireValue.deviceId}',
                        );
                        final msg = await ref
                            .read(pinSessionProvider.notifier)
                            .startSession(identity.requireValue);
                        _logMonitorDashboard(
                          'PIN session created:\n'
                          '  sessionId=${msg.pairingSessionId}\n'
                          '  expiresInSec=${msg.expiresInSec}\n'
                          '  maxAttempts=${msg.maxAttempts}\n'
                          '  NOTE: Listener must send PIN_PAIRING_INIT to receive this PIN_REQUIRED message',
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'PIN session started (${msg.expiresInSec}s)',
                            ),
                          ),
                        );
                      } catch (e, stack) {
                        _logMonitorDashboard('PIN session start failed: $e\n$stack');
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Could not start PIN session'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.pin),
                    label: const Text('Start PIN session'),
                  ),
                ),
              ],
            ),
            if (pinSession != null) ...[
              const SizedBox(height: 8),
              _PinSessionBanner(session: pinSession),
            ],
          ],
        ),
        const SizedBox(height: 14),
        _MonitorCard(
          title: 'Trusted listeners',
          subtitle:
              'Pinned fingerprints are required on every control session.',
          badge: 'mTLS required',
          badgeColor: AppColors.primary,
          children: [
            trustedPeers.when(
              data: (peers) => peers.isEmpty
                  ? const Text('No trusted listeners yet.')
                  : Column(
                      children: peers
                          .map(
                            (peer) => _TrustedListenerRow(
                              name: peer.name,
                              fingerprint: peer.certFingerprint,
                              onRevoke: () async {
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
                                            onPressed: () => Navigator.of(
                                              context,
                                            ).pop(false),
                                            child: const Text('Cancel'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.of(context).pop(true),
                                            child: const Text('Revoke'),
                                          ),
                                        ],
                                      ),
                                    ) ??
                                    false;
                                if (confirmed) {
                                  await ref
                                      .read(trustedListenersProvider.notifier)
                                      .revoke(peer.deviceId);
                                }
                              },
                            ),
                          )
                          .toList(),
                    ),
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(minHeight: 2),
              ),
              error: (err, _) => Text(
                'Could not load trusted listeners',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.red),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _MonitorCard(
          title: 'Control channel status',
          subtitle:
              'HTTP+WebSocket control (TLS ${serviceBuilder.defaultPort}), nonce+signature handshake and pinned fingerprint.',
          badge: 'HTTP+WS',
          badgeColor: AppColors.primary,
          children: [
            _MetricRow(
              label: 'Status',
              value: _serverStatusLabel(controlServer),
            ),
            _MetricRow(
              label: 'Trusted listeners',
              value:
                  '${trustedPeers.maybeWhen(data: (list) => list.length, orElse: () => 0)} pinned',
            ),
            const _MetricRow(
              label: 'Streams',
              value: 'Control (bi-dir) • media via WebRTC',
            ),
          ],
        ),
      ],
    );
  }
}

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

String _serverStatusLabel(ControlServerState state) {
  switch (state.status) {
    case ControlServerStatus.running:
      return 'Running on ${state.port ?? kControlDefaultPort} (HTTP+WS)';
    case ControlServerStatus.starting:
      return 'Starting...';
    case ControlServerStatus.error:
      return 'Error: ${state.error ?? 'unknown'}';
    case ControlServerStatus.stopped:
    default:
      return 'Stopped';
  }
}

class _MonitorCard extends StatelessWidget {
  const _MonitorCard({
    required this.title,
    required this.subtitle,
    required this.children,
    this.badge,
    this.badgeColor,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final String? badge;
  final Color? badgeColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: (badgeColor ?? AppColors.primary).withValues(
                        alpha: 0.12,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      badge!,
                      style: TextStyle(
                        color: badgeColor ?? AppColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (trailing != null) ...[const SizedBox(width: 10), trailing!],
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSlider extends StatelessWidget {
  const _SettingsSlider({
    required this.label,
    required this.helper,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.displayValue,
    required this.onChanged,
  });

  final String label;
  final String helper;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String displayValue;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              displayValue,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          label: displayValue,
          onChanged: onChanged,
        ),
        Text(
          helper,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _TrustedListenerRow extends StatelessWidget {
  const _TrustedListenerRow({
    required this.name,
    required this.fingerprint,
    this.onRevoke,
  });

  final String name;
  final String fingerprint;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          const Icon(Icons.verified_user, size: 18, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            fingerprint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
          ),
          if (onRevoke != null) ...[
            const SizedBox(width: 8),
            TextButton(onPressed: onRevoke, child: const Text('Revoke')),
          ],
        ],
      ),
    );
  }
}

class _PinSessionBanner extends StatelessWidget {
  const _PinSessionBanner({required this.session});

  final PinSessionState session;

  @override
  Widget build(BuildContext context) {
    final remaining = session.expiresAt.difference(DateTime.now()).inSeconds;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Active PIN session',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                session.pin ?? '------',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  letterSpacing: 2,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                'Expires in ${remaining.clamp(0, 60)}s',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Session ID ${session.sessionId.substring(0, 8)} • attempts ${session.attemptsUsed}/${session.maxAttempts}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

void _showQrSheet(
  BuildContext context, {
  required String payload,
  required Map<String, dynamic> payloadJson,
}) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (context) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pairing QR',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Center(
                child: QrImageView(
                  data: payload,
                  size: 220,
                  backgroundColor: Colors.white,
                  padding: const EdgeInsets.all(12),
                ),
              ),
              const SizedBox(height: 12),
              _MetricRow(
                label: 'Payload size',
                value: '${payload.length} bytes',
              ),
              _MetricRow(
                label: 'Monitor',
                value: payloadJson['monitorName'] as String? ?? '',
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Text(
                  const JsonEncoder.withIndent('  ').convert(payloadJson),
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
