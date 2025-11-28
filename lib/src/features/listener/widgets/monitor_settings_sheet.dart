import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models.dart';
import '../../../state/app_state.dart';
import '../../../state/per_monitor_settings.dart';
import '../../../theme.dart';

/// Shows the per-monitor settings bottom sheet.
void showMonitorSettingsSheet(
  BuildContext context, {
  required String remoteDeviceId,
  required String monitorName,
}) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => MonitorSettingsSheet(
      remoteDeviceId: remoteDeviceId,
      monitorName: monitorName,
    ),
  );
}

/// Per-monitor settings sheet content.
class MonitorSettingsSheet extends ConsumerWidget {
  const MonitorSettingsSheet({
    super.key,
    required this.remoteDeviceId,
    required this.monitorName,
  });

  final String remoteDeviceId;
  final String monitorName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(perMonitorSettingsProvider);
    final settings = settingsAsync.asData?.value.getOrDefault(remoteDeviceId) ??
        PerMonitorSettings.defaults(remoteDeviceId);

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
                        .setNotificationsEnabled(remoteDeviceId, value);
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
                        .setAutoPlayOnNoise(remoteDeviceId, value);
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
                            .setAutoPlayDuration(remoteDeviceId, value);
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

              // Noise preferences header
              Text(
                'Noise detection overrides',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Override global settings for this monitor only',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 12),

              // Threshold override
              _buildNoisePreferenceOverride(
                context,
                ref,
                title: 'Sensitivity',
                subtitle: 'Noise threshold for this monitor',
                currentOverride: settings.thresholdOverride,
                globalDefault: ref
                        .watch(listenerSettingsProvider)
                        .asData
                        ?.value
                        .noisePreferences
                        .threshold ??
                    50,
                options: [20, 30, 40, 50, 60, 70, 80, 90],
                formatValue: (v) => '$v%',
                onChanged: (value) {
                  ref
                      .read(perMonitorSettingsProvider.notifier)
                      .setThresholdOverride(remoteDeviceId, value);
                  // Refresh subscription with new preferences
                  ref
                      .read(controlClientProvider.notifier)
                      .refreshNoiseSubscription();
                },
              ),

              const SizedBox(height: 12),

              // Cooldown override
              _buildNoisePreferenceOverride(
                context,
                ref,
                title: 'Cooldown',
                subtitle: 'Seconds between alerts',
                currentOverride: settings.cooldownSecondsOverride,
                globalDefault: ref
                        .watch(listenerSettingsProvider)
                        .asData
                        ?.value
                        .noisePreferences
                        .cooldownSeconds ??
                    8,
                options: [3, 5, 8, 10, 15, 30],
                formatValue: (v) => '${v}s',
                onChanged: (value) {
                  ref
                      .read(perMonitorSettingsProvider.notifier)
                      .setCooldownSecondsOverride(remoteDeviceId, value);
                  // Refresh subscription with new preferences
                  ref
                      .read(controlClientProvider.notifier)
                      .refreshNoiseSubscription();
                },
              ),

              const SizedBox(height: 12),

              // Auto-stream type override
              _buildAutoStreamTypeOverride(
                context,
                ref,
                settings: settings,
                remoteDeviceId: remoteDeviceId,
              ),

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

  Widget _buildNoisePreferenceOverride(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String subtitle,
    required int? currentOverride,
    required int globalDefault,
    required List<int> options,
    required String Function(int) formatValue,
    required void Function(int?) onChanged,
  }) {
    final hasOverride = currentOverride != null;
    final displayValue = currentOverride ?? globalDefault;

    return _SettingsCard(
      title: title,
      subtitle: hasOverride
          ? '$subtitle (override: ${formatValue(displayValue)})'
          : '$subtitle (global: ${formatValue(globalDefault)})',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasOverride)
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () {
                onChanged(null);
                // Note: onChanged should call refreshNoiseSubscription
              },
              tooltip: 'Clear override',
            ),
          DropdownButton<int>(
            value: displayValue,
            underline: const SizedBox.shrink(),
            onChanged: (value) {
              if (value != null) {
                onChanged(value);
                // Note: onChanged should call refreshNoiseSubscription
              }
            },
            items: options
                .map((v) => DropdownMenuItem(
                      value: v,
                      child: Text(formatValue(v)),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildAutoStreamTypeOverride(
    BuildContext context,
    WidgetRef ref, {
    required PerMonitorSettings settings,
    required String remoteDeviceId,
  }) {
    final globalDefault = ref
            .watch(listenerSettingsProvider)
            .asData
            ?.value
            .noisePreferences
            .autoStreamType ??
        AutoStreamType.audio;

    final hasOverride = settings.autoStreamTypeOverride != null;
    final displayValue = settings.autoStreamTypeOverride ?? globalDefault;

    String formatType(AutoStreamType type) {
      switch (type) {
        case AutoStreamType.none:
          return 'Off';
        case AutoStreamType.audio:
          return 'Audio';
        case AutoStreamType.audioVideo:
          return 'A+V';
      }
    }

    return _SettingsCard(
      title: 'Auto-stream on noise',
      subtitle: hasOverride
          ? 'Override: ${formatType(displayValue)}'
          : 'Global: ${formatType(globalDefault)}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasOverride)
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () {
                ref
                    .read(perMonitorSettingsProvider.notifier)
                    .setAutoStreamTypeOverride(remoteDeviceId, null);
                // Refresh subscription with new preferences
                ref
                    .read(controlClientProvider.notifier)
                    .refreshNoiseSubscription();
              },
              tooltip: 'Clear override',
            ),
          DropdownButton<AutoStreamType>(
            value: displayValue,
            underline: const SizedBox.shrink(),
            onChanged: (value) {
              if (value != null) {
                ref
                    .read(perMonitorSettingsProvider.notifier)
                    .setAutoStreamTypeOverride(remoteDeviceId, value);
                // Refresh subscription with new preferences
                ref
                    .read(controlClientProvider.notifier)
                    .refreshNoiseSubscription();
              }
            },
            items: const [
              DropdownMenuItem(
                value: AutoStreamType.none,
                child: Text('Off'),
              ),
              DropdownMenuItem(
                value: AutoStreamType.audio,
                child: Text('Audio'),
              ),
              DropdownMenuItem(
                value: AutoStreamType.audioVideo,
                child: Text('A+V'),
              ),
            ],
          ),
        ],
      ),
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
