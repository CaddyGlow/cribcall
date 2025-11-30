import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models.dart';
import '../../../state/app_state.dart';
import '../../../theme.dart';

/// Show the noise settings drawer.
/// Noise sensitivity/cooldown now come from monitors; this drawer only controls
/// listener-side behavior (notification vs auto-open stream) and explains where
/// to adjust per-monitor overrides.
void showNoiseSettingsDrawer(BuildContext context) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const NoiseSettingsDrawer(),
  );
}

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
    final defaultAction = settings.defaultAction;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.tune, color: AppColors.primary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Noise alerts',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Monitors provide sensitivity/cooldown. Choose how the app reacts.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        _NoiseSettingRow(
          icon: Icons.notifications_active,
          title: 'When noise is detected',
          subtitle: defaultAction == ListenerDefaultAction.notify
              ? 'Send a notification'
              : 'Automatically open audio stream',
          trailing: SegmentedButton<ListenerDefaultAction>(
            segments: const [
              ButtonSegment(
                value: ListenerDefaultAction.notify,
                label: Text('Notify'),
                icon: Icon(Icons.notifications_none),
              ),
              ButtonSegment(
                value: ListenerDefaultAction.autoOpenStream,
                label: Text('Auto-open'),
                icon: Icon(Icons.play_circle_outline),
              ),
            ],
            selected: {defaultAction},
            onSelectionChanged: (selection) {
              final choice = selection.isEmpty ? null : selection.first;
              if (choice == null) return;
              ref
                  .read(listenerSettingsProvider.notifier)
                  .setDefaultAction(choice);
            },
          ),
        ),

        const SizedBox(height: 20),

        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.1)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: AppColors.primary.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Noise sensitivity and cooldown are provided per monitor. '
                  'Open a monitor card and tap Settings to adjust overrides for that monitor.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

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
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  subtitle,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
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
