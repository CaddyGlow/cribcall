import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/per_monitor_settings.dart';
import '../../../theme.dart';

/// Shows the per-monitor settings bottom sheet.
void showMonitorSettingsSheet(
  BuildContext context, {
  required String monitorId,
  required String monitorName,
}) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => MonitorSettingsSheet(
      monitorId: monitorId,
      monitorName: monitorName,
    ),
  );
}

/// Per-monitor settings sheet content.
class MonitorSettingsSheet extends ConsumerWidget {
  const MonitorSettingsSheet({
    super.key,
    required this.monitorId,
    required this.monitorName,
  });

  final String monitorId;
  final String monitorName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(perMonitorSettingsProvider);
    final settings = settingsAsync.asData?.value.getOrDefault(monitorId) ??
        PerMonitorSettings.defaults(monitorId);

    return DraggableScrollableSheet(
      initialChildSize: 0.45,
      minChildSize: 0.3,
      maxChildSize: 0.7,
      expand: false,
      builder: (context, scrollController) {
        return SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.settings,
                      color: AppColors.primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Settings for "$monitorName"',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Customize notifications and auto-play',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Notifications toggle
              _SettingsCard(
                title: 'Notifications',
                subtitle: 'Receive alerts when noise is detected',
                trailing: Switch(
                  value: settings.notificationsEnabled,
                  onChanged: (value) {
                    ref
                        .read(perMonitorSettingsProvider.notifier)
                        .setNotificationsEnabled(monitorId, value);
                  },
                ),
              ),

              const SizedBox(height: 12),

              // Auto-play toggle
              _SettingsCard(
                title: 'Auto-play on noise',
                subtitle: 'Automatically start streaming when noise is detected',
                trailing: Switch(
                  value: settings.autoPlayOnNoise,
                  onChanged: (value) {
                    ref
                        .read(perMonitorSettingsProvider.notifier)
                        .setAutoPlayOnNoise(monitorId, value);
                  },
                ),
              ),

              // Auto-play duration (only shown if auto-play is enabled)
              if (settings.autoPlayOnNoise) ...[
                const SizedBox(height: 12),
                _SettingsCard(
                  title: 'Auto-play duration',
                  subtitle: 'How long to stream after noise event',
                  trailing: DropdownButton<int>(
                    value: settings.autoPlayDurationSec,
                    underline: const SizedBox.shrink(),
                    onChanged: (value) {
                      if (value != null) {
                        ref
                            .read(perMonitorSettingsProvider.notifier)
                            .setAutoPlayDuration(monitorId, value);
                      }
                    },
                    items: const [
                      DropdownMenuItem(value: 10, child: Text('10s')),
                      DropdownMenuItem(value: 15, child: Text('15s')),
                      DropdownMenuItem(value: 30, child: Text('30s')),
                      DropdownMenuItem(value: 45, child: Text('45s')),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 24),

              // Info text
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.1),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: AppColors.primary.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'These settings override global listener settings for this specific monitor.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Close button
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
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
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}
