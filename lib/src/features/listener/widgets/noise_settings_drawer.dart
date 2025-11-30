import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models.dart';
import '../../../state/app_state.dart';
import '../../../theme.dart';
import '../../../webrtc/webrtc_controller.dart';
import '../../shared/widgets/cc_info_box.dart';
import '../../shared/widgets/cc_settings_tile.dart';
import 'live_sound_wave.dart';

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
    final autoOpenPaused = ref.watch(autoOpenPausedProvider);
    final streamState = ref.watch(streamingProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) => SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: listenerSettings.when(
          data: (settings) => _buildContent(
            context,
            ref,
            settings,
            autoOpenPaused,
            streamState,
          ),
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
    bool autoOpenPaused,
    StreamingState streamState,
  ) {
    final defaultAction = settings.defaultAction;
    final isStreaming = streamState.status == StreamingStatus.connected;
    final isConnecting = streamState.status == StreamingStatus.connecting;
    final showPlayerControls = isStreaming || isConnecting;

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

        // Player controls section (only when streaming)
        if (showPlayerControls) ...[
          _buildPlayerControls(context, ref, streamState, settings),
          const SizedBox(height: 20),
        ],

        CcSettingsTile(
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

        // Pause/Resume autoopen toggle (only when autoopen is enabled)
        if (defaultAction == ListenerDefaultAction.autoOpenStream) ...[
          const SizedBox(height: 12),
          CcSettingsTile(
            icon: autoOpenPaused ? Icons.pause_circle : Icons.play_circle,
            title: 'Auto-open status',
            subtitle: autoOpenPaused
                ? 'Paused - noise events will only notify'
                : 'Active - streams will open automatically',
            trailing: Switch(
              value: !autoOpenPaused,
              onChanged: (enabled) {
                ref.read(autoOpenPausedProvider.notifier).setPaused(!enabled);
              },
            ),
          ),
        ],

        const SizedBox(height: 16),

        // Volume control
        CcSettingsTile(
          icon: Icons.volume_up,
          title: 'Playback volume',
          subtitle: '${settings.playbackVolume}%',
          trailing: SizedBox(
            width: 150,
            child: Slider(
              value: settings.playbackVolume.toDouble().clamp(0, 200),
              min: 0,
              max: 200,
              divisions: 20,
              onChanged: (value) {
                ref
                    .read(listenerSettingsProvider.notifier)
                    .setPlaybackVolume(value.round());
              },
            ),
          ),
        ),

        const SizedBox(height: 20),

        const CcInfoBox(
          text: 'Noise sensitivity and cooldown are provided per monitor. '
              'Open a monitor card and tap Settings to adjust overrides for that monitor.',
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

  Widget _buildPlayerControls(
    BuildContext context,
    WidgetRef ref,
    StreamingState streamState,
    ListenerSettings settings,
  ) {
    final isStreaming = streamState.status == StreamingStatus.connected;
    final monitorName = streamState.monitorName ?? 'Monitor';
    final autoPlaySession = ref.watch(autoPlaySessionProvider);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.success.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isStreaming ? AppColors.success : AppColors.primary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isStreaming ? 'LIVE' : 'Connecting...',
                style: TextStyle(
                  color: isStreaming ? AppColors.success : AppColors.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  monitorName,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),

          // Auto-play countdown indicator
          if (autoPlaySession.isAutoPlay && autoPlaySession.willAutoStop) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.timer,
                  size: 14,
                  color: AppColors.warning,
                ),
                const SizedBox(width: 6),
                Text(
                  'Auto-stop in ${autoPlaySession.remainingSeconds}s',
                  style: TextStyle(
                    color: AppColors.warning,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ] else if (autoPlaySession.isAutoPlay && !autoPlaySession.willAutoStop) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.all_inclusive,
                  size: 14,
                  color: AppColors.success,
                ),
                const SizedBox(width: 6),
                Text(
                  'Streaming continuously',
                  style: TextStyle(
                    color: AppColors.success,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],

          if (isStreaming) ...[
            const SizedBox(height: 12),
            // Live waveform
            SizedBox(
              height: 50,
              child: LiveSoundWave(
                audioStream: ref.read(streamingProvider.notifier).audioDataStream,
                barCount: 30,
                height: 50,
              ),
            ),
          ],

          const SizedBox(height: 12),

          // Control buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Stop button
              Material(
                color: Colors.red.withValues(alpha: 0.9),
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: () {
                    ref.read(autoPlaySessionProvider.notifier).endSession();
                    ref.read(streamingProvider.notifier).endStream();
                  },
                  customBorder: const CircleBorder(),
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(Icons.stop, color: Colors.white, size: 24),
                  ),
                ),
              ),
              // Continue button (only for auto-play with timer)
              if (autoPlaySession.isAutoPlay && autoPlaySession.willAutoStop) ...[
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: () {
                    ref.read(autoPlaySessionProvider.notifier).continueStream();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Stream will continue indefinitely'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  icon: const Icon(Icons.all_inclusive, size: 18),
                  label: const Text('Continue'),
                ),
              ],
              if (isStreaming && !autoPlaySession.willAutoStop) ...[
                const SizedBox(width: 12),
                // Pin button (keep server-side alive)
                OutlinedButton.icon(
                  onPressed: () {
                    ref.read(streamingProvider.notifier).pinStream();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Stream pinned'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  icon: const Icon(Icons.push_pin, size: 18),
                  label: const Text('Pin'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
