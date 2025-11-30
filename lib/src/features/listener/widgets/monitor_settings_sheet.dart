import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models.dart';
import '../../../state/app_state.dart';
import '../../../state/connected_monitor_settings.dart';
import '../../../theme.dart';
import '../../shared/widgets/cc_info_box.dart';
import '../../shared/widgets/cc_settings_slider.dart';
import '../../shared/widgets/cc_settings_tile.dart';

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
    final settingsAsync = ref.watch(connectedMonitorSettingsProvider);
    final settings =
        settingsAsync.asData?.value.getOrDefault(remoteDeviceId) ??
        ConnectedMonitorSettings.withDefaults(remoteDeviceId);

    return DraggableScrollableSheet(
      initialChildSize: 0.45,
      minChildSize: 0.3,
      maxChildSize: 0.8,
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
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Monitor-provided defaults with your overrides',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppColors.muted),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => ref
                        .read(controlClientProvider.notifier)
                        .requestMonitorSettings(),
                    child: const Text('Refresh'),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Notifications toggle
              CcSettingsTile(
                title: 'Notifications',
                subtitle: 'Receive alerts when noise is detected',
                trailing: Switch(
                  value: settings.notificationsEnabled,
                  onChanged: (value) {
                    ref
                        .read(connectedMonitorSettingsProvider.notifier)
                        .setNotificationsEnabled(remoteDeviceId, value);
                  },
                ),
              ),

              const SizedBox(height: 12),

              // Auto-play toggle
              CcSettingsTile(
                title: 'Auto-play on noise',
                subtitle:
                    'Automatically start streaming when noise is detected',
                trailing: Switch(
                  value: settings.autoPlayOnNoise,
                  onChanged: (value) {
                    ref
                        .read(connectedMonitorSettingsProvider.notifier)
                        .setAutoPlayOnNoise(remoteDeviceId, value);
                  },
                ),
              ),

              // Auto-play duration (only shown if auto-play is enabled)
              if (settings.autoPlayOnNoise) ...[
                const SizedBox(height: 12),
                CcSettingsTile(
                  title: 'Auto-play duration',
                  subtitle: 'How long to stream after noise event',
                  trailing: DropdownButton<int>(
                    value: settings.autoPlayDurationSec,
                    underline: const SizedBox.shrink(),
                    onChanged: (value) {
                      if (value != null) {
                        ref
                            .read(connectedMonitorSettingsProvider.notifier)
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
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                'Monitor defaults are shown; set overrides for this listener.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
              const SizedBox(height: 12),

              // Threshold override
              CcSettingsSlider.withOverride(
                label: 'Sensitivity',
                value: (settings.customThreshold ?? settings.baseThreshold)
                    .toDouble(),
                min: 10,
                max: 100,
                divisions: 18,
                displayValue:
                    '${settings.customThreshold ?? settings.baseThreshold}%',
                baseValue: settings.baseThreshold.toDouble(),
                baseDisplayValue: '${settings.baseThreshold}%',
                hasOverride: settings.customThreshold != null,
                onChanged: (value) async {
                  await ref
                      .read(connectedMonitorSettingsProvider.notifier)
                      .setCustomThreshold(remoteDeviceId, value.round());
                  await ref
                      .read(controlClientProvider.notifier)
                      .refreshNoiseSubscription();
                },
                onClear: () async {
                  await ref
                      .read(connectedMonitorSettingsProvider.notifier)
                      .setCustomThreshold(remoteDeviceId, null);
                  await ref
                      .read(controlClientProvider.notifier)
                      .refreshNoiseSubscription();
                },
              ),

              const SizedBox(height: 12),

              // Cooldown override
              CcSettingsSlider.withOverride(
                label: 'Cooldown',
                value: (settings.customCooldownSeconds ??
                        settings.baseCooldownSeconds)
                    .toDouble(),
                min: 1,
                max: 30,
                divisions: 29,
                displayValue:
                    '${settings.customCooldownSeconds ?? settings.baseCooldownSeconds}s',
                baseValue: settings.baseCooldownSeconds.toDouble(),
                baseDisplayValue: '${settings.baseCooldownSeconds}s',
                hasOverride: settings.customCooldownSeconds != null,
                onChanged: (value) async {
                  await ref
                      .read(connectedMonitorSettingsProvider.notifier)
                      .setCustomCooldownSeconds(remoteDeviceId, value.round());
                  await ref
                      .read(controlClientProvider.notifier)
                      .refreshNoiseSubscription();
                },
                onClear: () async {
                  await ref
                      .read(connectedMonitorSettingsProvider.notifier)
                      .setCustomCooldownSeconds(remoteDeviceId, null);
                  await ref
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
              const CcInfoBox(
                text:
                    'Overrides are stored per monitor. If the monitor changes its defaults, refresh to sync and your overrides will be re-applied.',
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

  Widget _buildAutoStreamTypeOverride(
    BuildContext context,
    WidgetRef ref, {
    required ConnectedMonitorSettings settings,
    required String remoteDeviceId,
  }) {
    final baseValue = settings.baseAutoStreamType;
    final hasOverride = settings.customAutoStreamType != null;
    final displayValue = settings.customAutoStreamType ?? baseValue;

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

    return CcSettingsTile(
      title: 'Auto-stream on noise',
      subtitle: hasOverride
          ? 'Override: ${formatType(displayValue)}'
          : 'Monitor default: ${formatType(baseValue)}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasOverride)
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () async {
                await ref
                    .read(connectedMonitorSettingsProvider.notifier)
                    .setCustomAutoStreamType(remoteDeviceId, null);
                await ref
                    .read(controlClientProvider.notifier)
                    .refreshNoiseSubscription();
              },
              tooltip: 'Clear override',
            ),
          DropdownButton<AutoStreamType>(
            value: displayValue,
            underline: const SizedBox.shrink(),
            onChanged: (value) async {
              if (value != null) {
                await ref
                    .read(connectedMonitorSettingsProvider.notifier)
                    .setCustomAutoStreamType(remoteDeviceId, value);
                await ref
                    .read(controlClientProvider.notifier)
                    .refreshNoiseSubscription();
              }
            },
            items: const [
              DropdownMenuItem(value: AutoStreamType.none, child: Text('Off')),
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

