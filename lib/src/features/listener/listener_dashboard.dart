import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../control/control_service.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import 'listener_pin_page.dart';
import 'listener_scan_qr_page.dart';
import 'widgets/pinned_badge.dart';

class ListenerDashboard extends ConsumerWidget {
  const ListenerDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final advertisements = ref.watch(discoveredMonitorsProvider);
    final trustedMonitors = ref.watch(trustedMonitorsProvider);
    final identity = ref.watch(identityProvider);
    final listenerSettingsAsync = ref.watch(listenerSettingsProvider);
    final listenerSettings =
        listenerSettingsAsync.asData?.value ?? ListenerSettings.defaults;
    final pinned = trustedMonitors.maybeWhen(
      data: (list) => list,
      orElse: () => <TrustedMonitor>[],
    );

    Future<void> forgetMonitor(String monitorId, String monitorName) async {
      final confirmed =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Forget monitor?'),
              content: Text(
                'Remove $monitorName from trusted list? You will need to re-pair.',
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
      await ref.read(trustedMonitorsProvider.notifier).removeMonitor(monitorId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Forgot $monitorName')));
    }

    Future<void> handleListen(_MonitorCardData data) async {
      if (!context.mounted) return;
      if (!data.trusted) {
        if (data.advertisement != null) {
          await showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            builder: (context) =>
                ListenerPinPage(advertisement: data.advertisement!),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Pair this monitor (QR or PIN) before listening'),
            ),
          );
        }
        return;
      }
      if (data.trustedMonitor == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Trusted monitor details missing; re-pair and retry'),
          ),
        );
        return;
      }
      if (data.advertisement == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Monitor is offline; waiting for mDNS presence'),
          ),
        );
        return;
      }
      if (!identity.hasValue) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Loading device identity; try again in a moment'),
          ),
        );
        return;
      }
      final failure = await ref
          .read(controlClientProvider.notifier)
          .connectToMonitor(
            advertisement: data.advertisement!,
            monitor: data.trustedMonitor!,
            identity: identity.requireValue,
          );
      if (!context.mounted) return;
      if (failure != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Control connect failed: ${failure.message}')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Connecting to ${data.name} via QUIC control channel...',
            ),
          ),
        );
      }
    }

    final monitors = [
      ...advertisements.map((ad) {
        final pinnedMonitor = pinned.cast<TrustedMonitor?>().firstWhere(
          (p) => p?.monitorId == ad.monitorId,
          orElse: () => null,
        );
        final isTrusted = pinnedMonitor != null;
        late final _MonitorCardData data;
        data = _MonitorCardData(
          name: ad.monitorName,
          status: 'Online',
          lastNoise: isTrusted ? '3 min ago' : '—',
          fingerprint: ad.monitorCertFingerprint,
          trusted: isTrusted,
          trustedMonitor: pinnedMonitor,
          lastKnownIp: ad.ip ?? pinnedMonitor?.lastKnownIp,
          onForget: isTrusted
              ? () => forgetMonitor(ad.monitorId, ad.monitorName)
              : null,
          advertisement: ad,
          onListen: () => handleListen(data),
        );
        return data;
      }),
      for (final monitor in pinned)
        if (!advertisements.any((ad) => ad.monitorId == monitor.monitorId))
          (() {
            late final _MonitorCardData data;
            data = _MonitorCardData(
              name: monitor.monitorName,
              status: 'Offline',
              lastNoise: '—',
              fingerprint: monitor.certFingerprint,
              trusted: true,
              trustedMonitor: monitor,
              lastKnownIp: monitor.lastKnownIp,
              onForget: () =>
                  forgetMonitor(monitor.monitorId, monitor.monitorName),
              advertisement: null,
              onListen: () => handleListen(data),
            );
            return data;
          })(),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Listener controls',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        Card(
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
                      data: (id) =>
                          PinnedBadge(fingerprint: id.certFingerprint),
                      orElse: () => const PinnedBadge(),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Server pinning happens before any control traffic leaves this device.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
                ),
                const SizedBox(height: 14),
                ...monitors.map((m) => _MonitorCard(data: m)),
                const SizedBox(height: 12),
                trustedMonitors.when(
                  data: (list) => Text(
                    'Pinned monitors: ${list.length}',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                  loading: () => const Text('Loading pinned monitors...'),
                  error: (err, _) => Text(
                    'Could not load pinned monitors',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.red),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Listener settings',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (listenerSettingsAsync.isLoading)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Noise notifications'),
                  subtitle: const Text(
                    'Local alerts on NOISE_EVENT even when app is backgrounded.',
                  ),
                  value: listenerSettings.notificationsEnabled,
                  onChanged: (_) => ref
                      .read(listenerSettingsProvider.notifier)
                      .toggleNotifications(),
                ),
                const SizedBox(height: 6),
                Text(
                  'Default action',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: ListenerDefaultAction.values.map((action) {
                    final selected = listenerSettings.defaultAction == action;
                    return ChoiceChip(
                      label: Text(
                        action == ListenerDefaultAction.notify
                            ? 'Notify only'
                            : 'Auto-open stream',
                      ),
                      selected: selected,
                      onSelected: (_) => ref
                          .read(listenerSettingsProvider.notifier)
                          .setDefaultAction(action),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Discovery & pairing',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Scan a QR for instant trust or browse mDNS and pair with a 6-digit PIN bound to the server fingerprint.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () async {
                          final result = await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const ListenerScanQrPage(),
                            ),
                          );
                          if (!context.mounted) return;
                          if (result is MonitorQrPayload) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Pinned ${result.monitorName} (${result.monitorCertFingerprint.substring(0, 12)})',
                                ),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.qr_code_2),
                        label: const Text('Scan QR code'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'mDNS scan is pending platform channel implementation.',
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.wifi_tethering),
                        label: const Text('Scan network'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: const [
                    Icon(Icons.lock, size: 18, color: AppColors.primary),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Untrusted clients may only send pairing messages; everything else requires a pinned fingerprint.',
                        style: TextStyle(color: AppColors.muted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Live stream prep',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'WebRTC uses host-only ICE by default. Audio starts sub-second once the QUIC control stream hands off SDP.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: const [
                    _Tag(text: 'Opus @ 48 kHz mono'),
                    _Tag(text: 'DTLS-SRTP, UDP only'),
                    _Tag(text: 'Auto-stop unless pinned'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MonitorCardData {
  _MonitorCardData({
    required this.name,
    required this.status,
    required this.lastNoise,
    required this.fingerprint,
    required this.trusted,
    this.lastKnownIp,
    this.trustedMonitor,
    this.onForget,
    this.advertisement,
    this.onListen,
  });

  final String name;
  final String status;
  final String lastNoise;
  final String fingerprint;
  final bool trusted;
  final String? lastKnownIp;
  final TrustedMonitor? trustedMonitor;
  final VoidCallback? onForget;
  final MdnsAdvertisement? advertisement;
  final VoidCallback? onListen;
}

class _MonitorCard extends StatelessWidget {
  const _MonitorCard({required this.data});

  final _MonitorCardData data;

  @override
  Widget build(BuildContext context) {
    final online = data.status.toLowerCase() == 'online';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: online
                    ? AppColors.success.withValues(alpha: 0.16)
                    : AppColors.warning.withValues(alpha: 0.16),
                child: Icon(
                  online ? Icons.podcasts : Icons.podcasts_outlined,
                  color: online ? AppColors.success : AppColors.warning,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.name,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Fingerprint ${data.fingerprint}',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                    ),
                    if (data.lastKnownIp != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Last known IP ${data.lastKnownIp}',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                      ),
                    ],
                  ],
                ),
              ),
              if (data.trusted) ...[
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Pinned',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: online
                      ? AppColors.success.withValues(alpha: 0.14)
                      : AppColors.warning.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  data.status,
                  style: TextStyle(
                    color: online ? AppColors.success : AppColors.warning,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(
                Icons.notifications_active,
                size: 16,
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Last noise: ${data.lastNoise}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              TextButton(onPressed: data.onListen, child: const Text('Listen')),
              TextButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Video streaming not wired yet'),
                    ),
                  );
                },
                child: const Text('View video'),
              ),
              if (!data.trusted && data.advertisement != null)
                TextButton.icon(
                  onPressed: () async {
                    final ad = data.advertisement!;
                    await showModalBottomSheet<void>(
                      context: context,
                      showDragHandle: true,
                      builder: (context) => ListenerPinPage(advertisement: ad),
                    );
                  },
                  icon: const Icon(Icons.pin),
                  label: const Text('Pair with PIN'),
                ),
              if (data.trusted && data.onForget != null)
                TextButton.icon(
                  onPressed: data.onForget,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Forget'),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
