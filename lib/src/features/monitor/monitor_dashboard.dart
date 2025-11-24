import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../domain/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';

class MonitorDashboard extends ConsumerWidget {
  const MonitorDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final monitoringEnabled = ref.watch(monitoringStatusProvider);
    final settings = ref.watch(monitorSettingsProvider);
    final trustedPeers = ref.watch(trustedPeersProvider);
    final identity = ref.watch(identityProvider);
    final serviceBuilder = ref.watch(serviceIdentityProvider);

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
            _MetricRow(
              label: 'Threshold',
              value: '${settings.noise.threshold} / 100',
            ),
            _MetricRow(
              label: 'Min duration',
              value: '${settings.noise.minDurationMs} ms',
            ),
            _MetricRow(
              label: 'Cooldown',
              value: '${settings.noise.cooldownSeconds} s',
            ),
            _MetricRow(
              label: 'Auto-stream',
              value:
                  '${_autoStreamLabel(settings.autoStreamType)} for ${settings.autoStreamDurationSec}s',
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => ref
                  .read(monitorSettingsProvider.notifier)
                  .setAutoStreamDuration(
                    settings.autoStreamDurationSec == 15 ? 30 : 15,
                  ),
              icon: const Icon(Icons.timelapse),
              label: const Text('Toggle auto-stream length'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _MonitorCard(
          title: 'Pairing & identity',
          subtitle:
              'Share a QR or run PIN-based pairing. Listeners must pin this device fingerprint before QUIC traffic is accepted.',
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
                    onPressed: () {},
                    icon: const Icon(Icons.pin),
                    label: const Text('Start PIN session'),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        _MonitorCard(
          title: 'Trusted listeners',
          subtitle: 'Pinned fingerprints are required on every QUIC session.',
          badge: 'mTLS required',
          badgeColor: AppColors.primary,
          children: [
            for (final peer in trustedPeers)
              _TrustedListenerRow(
                name: peer.name,
                fingerprint: peer.certFingerprint,
              ),
          ],
        ),
        const SizedBox(height: 14),
        _MonitorCard(
          title: 'Control channel status',
          subtitle:
              'QUIC server listens on UDP 48080, length-prefixed JSON on the control stream.',
          badge: 'QUIC server',
          badgeColor: AppColors.primary,
          children: const [
            _MetricRow(label: 'Role', value: 'Server with pinned certificate'),
            _MetricRow(
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

class _TrustedListenerRow extends StatelessWidget {
  const _TrustedListenerRow({required this.name, required this.fingerprint});

  final String name;
  final String fingerprint;

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
