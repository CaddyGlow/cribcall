import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models.dart';
import '../../../state/app_state.dart';
import '../../../theme.dart';

/// Show the global noise detection settings drawer.
void showNoiseSettingsDrawer(BuildContext context) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const NoiseSettingsDrawer(),
  );
}

/// Drawer for global noise detection settings.
class NoiseSettingsDrawer extends ConsumerWidget {
  const NoiseSettingsDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listenerSettings = ref.watch(listenerSettingsProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.7,
      expand: false,
      builder: (context, scrollController) => SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: listenerSettings.when(
          data: (settings) => _buildContent(context, ref, settings),
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(),
            ),
          ),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text('Error loading settings: $e'),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    ListenerSettings settings,
  ) {
    final prefs = settings.noisePreferences;

    return Column(
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
                Icons.tune,
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
                    'Noise detection settings',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Global defaults for all monitors',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.muted,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // Threshold
        _NoiseSettingRow(
          icon: Icons.volume_up,
          title: 'Sensitivity',
          subtitle: '${prefs.threshold}% threshold',
          trailing: DropdownButton<int>(
            value: prefs.threshold,
            underline: const SizedBox.shrink(),
            onChanged: (value) {
              if (value != null) {
                ref
                    .read(listenerSettingsProvider.notifier)
                    .setNoiseThreshold(value);
                ref
                    .read(controlClientProvider.notifier)
                    .refreshNoiseSubscription();
              }
            },
            items: [20, 30, 40, 50, 60, 70, 80, 90]
                .map((v) => DropdownMenuItem(
                      value: v,
                      child: Text('$v%'),
                    ))
                .toList(),
          ),
        ),
        const SizedBox(height: 12),

        // Cooldown
        _NoiseSettingRow(
          icon: Icons.hourglass_empty,
          title: 'Cooldown',
          subtitle: '${prefs.cooldownSeconds}s between alerts',
          trailing: DropdownButton<int>(
            value: prefs.cooldownSeconds,
            underline: const SizedBox.shrink(),
            onChanged: (value) {
              if (value != null) {
                ref
                    .read(listenerSettingsProvider.notifier)
                    .setCooldownSeconds(value);
                ref
                    .read(controlClientProvider.notifier)
                    .refreshNoiseSubscription();
              }
            },
            items: [3, 5, 8, 10, 15, 30]
                .map((v) => DropdownMenuItem(
                      value: v,
                      child: Text('${v}s'),
                    ))
                .toList(),
          ),
        ),
        const SizedBox(height: 12),

        // Auto-stream type
        _NoiseSettingRow(
          icon: Icons.stream,
          title: 'Auto-stream on noise',
          subtitle: prefs.autoStreamType == AutoStreamType.none
              ? 'Disabled'
              : prefs.autoStreamType == AutoStreamType.audio
                  ? 'Audio only'
                  : 'Audio + Video',
          trailing: DropdownButton<AutoStreamType>(
            value: prefs.autoStreamType,
            underline: const SizedBox.shrink(),
            onChanged: (value) {
              if (value != null) {
                ref
                    .read(listenerSettingsProvider.notifier)
                    .setAutoStreamType(value);
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
        ),

        const SizedBox(height: 20),

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
                  'These settings are sent to monitors when you connect. '
                  'Per-monitor overrides can be set in each monitor\'s settings.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.muted,
                      ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Done button
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ),

        const SizedBox(height: 16),
      ],
    );
  }
}

/// A row widget for noise detection settings.
class _NoiseSettingRow extends StatelessWidget {
  const _NoiseSettingRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                Text(
                  subtitle,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.muted),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
