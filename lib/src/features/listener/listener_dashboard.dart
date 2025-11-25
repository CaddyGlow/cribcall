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

    MdnsAdvertisement? _fallbackAdvertisement(TrustedMonitor monitor) {
      if (monitor.lastKnownIp == null) return null;
      return MdnsAdvertisement(
        monitorId: monitor.monitorId,
        monitorName: monitor.monitorName,
        monitorCertFingerprint: monitor.certFingerprint,
        servicePort: monitor.servicePort,
        version: monitor.serviceVersion,
        transport: monitor.transport,
        ip: monitor.lastKnownIp,
      );
    }

    Future<void> handleListen(
      BuildContext uiContext,
      _MonitorCardData data,
    ) async {
      if (!uiContext.mounted) return;
      if (!data.trusted) {
        if (data.advertisement != null) {
          await showModalBottomSheet<void>(
            context: uiContext,
            showDragHandle: true,
            builder: (context) =>
                ListenerPinPage(advertisement: data.advertisement!),
          );
        } else {
          ScaffoldMessenger.of(uiContext).showSnackBar(
            const SnackBar(
              content: Text('Pair this monitor (QR or PIN) before listening'),
            ),
          );
        }
        return;
      }
      if (data.trustedMonitor == null) {
        ScaffoldMessenger.of(uiContext).showSnackBar(
          const SnackBar(
            content: Text('Trusted monitor details missing; re-pair and retry'),
          ),
        );
        return;
      }
      final endpoint = data.connectTarget;
      if (endpoint == null) {
        ScaffoldMessenger.of(uiContext).showSnackBar(
          const SnackBar(
            content: Text('Monitor is offline; waiting for mDNS presence'),
          ),
        );
        return;
      }
      if (!identity.hasValue) {
        ScaffoldMessenger.of(uiContext).showSnackBar(
          const SnackBar(
            content: Text('Loading device identity; try again in a moment'),
          ),
        );
        return;
      }
      final failure = await ref
          .read(controlClientProvider.notifier)
          .connectToMonitor(
            advertisement: endpoint,
            monitor: data.trustedMonitor!,
            identity: identity.requireValue,
          );
      if (!uiContext.mounted) return;
      if (failure != null) {
        ScaffoldMessenger.of(uiContext).showSnackBar(
          SnackBar(content: Text('Control connect failed: ${failure.message}')),
        );
      } else {
        ScaffoldMessenger.of(uiContext).showSnackBar(
          SnackBar(
            content: Text(
              'Connecting to ${data.name} via HTTP+WS control channel...',
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
          lastNoiseEpochMs: pinnedMonitor?.lastNoiseEpochMs,
          fingerprint: ad.monitorCertFingerprint,
          trusted: isTrusted,
          trustedMonitor: pinnedMonitor,
          lastKnownIp: ad.ip ?? pinnedMonitor?.lastKnownIp,
          onForget: isTrusted
              ? () => forgetMonitor(ad.monitorId, ad.monitorName)
              : null,
          advertisement: ad,
          connectTarget: ad,
          onListen: () => handleListen(context, data),
        );
        return data;
      }),
      for (final monitor in pinned)
        if (!advertisements.any((ad) => ad.monitorId == monitor.monitorId))
          (() {
            late final _MonitorCardData data;
            final fallback = _fallbackAdvertisement(monitor);
            data = _MonitorCardData(
              name: monitor.monitorName,
              status: fallback == null ? 'Offline' : 'Last seen',
              lastNoiseEpochMs: monitor.lastNoiseEpochMs,
              fingerprint: monitor.certFingerprint,
              trusted: true,
              trustedMonitor: monitor,
              lastKnownIp: monitor.lastKnownIp,
              onForget: () =>
                  forgetMonitor(monitor.monitorId, monitor.monitorName),
              advertisement: null,
              connectTarget: fallback,
              onListen: () => handleListen(context, data),
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
                          showModalBottomSheet<void>(
                            context: context,
                            showDragHandle: true,
                            builder: (sheetContext) {
                              final discovered = monitors
                                  .where((m) => m.advertisement != null)
                                  .toList();
                              return _NetworkScanSheet(monitors: discovered);
                            },
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
      ],
    );
  }
}

class _MonitorCardData {
  _MonitorCardData({
    required this.name,
    required this.status,
    required this.lastNoiseEpochMs,
    required this.fingerprint,
    required this.trusted,
    this.lastKnownIp,
    this.trustedMonitor,
    this.onForget,
    this.advertisement,
    this.connectTarget,
    this.onListen,
  });

  final String name;
  final String status;
  final int? lastNoiseEpochMs;
  final String fingerprint;
  final bool trusted;
  final String? lastKnownIp;
  final TrustedMonitor? trustedMonitor;
  final VoidCallback? onForget;
  final MdnsAdvertisement? advertisement;
  final MdnsAdvertisement? connectTarget;
  final VoidCallback? onListen;
}

class _MonitorCard extends StatelessWidget {
  const _MonitorCard({required this.data});

  final _MonitorCardData data;

  @override
  Widget build(BuildContext context) {
    final online = data.status.toLowerCase() == 'online';
    final lastNoiseText = _formatLastNoise(data.lastNoiseEpochMs);
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
                  'Last noise: $lastNoiseText',
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

class _NetworkScanSheet extends StatelessWidget {
  const _NetworkScanSheet({required this.monitors});

  final List<_MonitorCardData> monitors;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Network scan',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            'Listening for CribCall monitors via mDNS.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
          ),
          const SizedBox(height: 12),
          if (monitors.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No monitors discovered yet.'),
            )
          else
            ...monitors.map((m) {
              final online = m.status.toLowerCase() == 'online';
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.name,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Fingerprint ${m.fingerprint}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: AppColors.muted),
                          ),
                          if (m.advertisement?.ip != null)
                            Text(
                              'IP ${m.advertisement!.ip}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: AppColors.muted),
                            ),
                        ],
                      ),
                    ),
                    if (m.trusted)
                      FilledButton(
                        onPressed: m.onListen,
                        child: Text(online ? 'Listen' : 'Try reconnect'),
                      )
                    else
                      OutlinedButton(
                        onPressed: () async {
                          if (m.advertisement == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Monitor offline; cannot pair.'),
                              ),
                            );
                            return;
                          }
                          await showModalBottomSheet<void>(
                            context: context,
                            showDragHandle: true,
                            builder: (_) => ListenerPinPage(
                              advertisement: m.advertisement!,
                            ),
                          );
                        },
                        child: const Text('Pair with PIN'),
                      ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}

String _formatLastNoise(int? epochMs) {
  if (epochMs == null) return 'No events yet';
  final ts = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final diff = DateTime.now().difference(ts);
  if (diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} hr ago';
  return '${diff.inDays} d ago';
}
