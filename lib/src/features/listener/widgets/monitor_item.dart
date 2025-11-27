import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models.dart';
import '../../../theme.dart';
import '../../../webrtc/webrtc_controller.dart';
import '../../shared/widgets/widgets.dart';
import 'live_sound_wave.dart';

/// Data for a monitor item display.
class MonitorItemData {
  MonitorItemData({
    required this.monitorId,
    required this.name,
    required this.status,
    required this.fingerprint,
    required this.trusted,
    this.lastNoiseEpochMs,
    this.lastSeenEpochMs,
    this.lastKnownIp,
    this.trustedMonitor,
    this.advertisement,
    this.connectTarget,
    this.alertCount,
    this.isConnected = false,
    this.isConnecting = false,
    this.onConnect,
    this.onDisconnect,
    this.onListen,
    this.onStop,
    this.onForget,
    this.onPair,
    this.onSettings,
  });

  final String monitorId;
  final String name;
  final String status;
  final String fingerprint;
  final bool trusted;
  final int? lastNoiseEpochMs;
  final int? lastSeenEpochMs;
  final String? lastKnownIp;
  final TrustedMonitor? trustedMonitor;
  final MdnsAdvertisement? advertisement;
  final MdnsAdvertisement? connectTarget;
  final int? alertCount;

  /// Whether currently connected to this monitor's control server.
  final bool isConnected;

  /// Whether currently connecting to this monitor.
  final bool isConnecting;

  /// Callback to connect to the monitor (for notifications).
  final VoidCallback? onConnect;

  /// Callback to disconnect from the monitor.
  final VoidCallback? onDisconnect;

  final VoidCallback? onListen;
  final VoidCallback? onStop;
  final VoidCallback? onForget;
  final VoidCallback? onPair;
  final VoidCallback? onSettings;

  bool get isOnline => status.toLowerCase() == 'online';
}

/// A trusted monitor item card with integrated playback controls.
///
/// Shows monitor info on the left, streaming controls on the right.
class TrustedMonitorItem extends ConsumerWidget {
  const TrustedMonitorItem({
    super.key,
    required this.data,
    required this.isActive,
  });

  final MonitorItemData data;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final streamState = ref.watch(streamingProvider);
    final isConnected = streamState.status == StreamingStatus.connected;
    final isConnecting = streamState.status == StreamingStatus.connecting;
    final showStreamingUI = isActive && (isConnected || isConnecting);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: showStreamingUI
            ? AppColors.success.withValues(alpha: 0.05)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: showStreamingUI
              ? AppColors.success.withValues(alpha: 0.3)
              : Colors.grey.shade200,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left side: Monitor info
            Expanded(child: _buildInfo(context)),

            const SizedBox(width: 12),

            // Right side: Stream controls or action buttons
            _buildRightSide(context, ref, showStreamingUI, isConnected, isConnecting),
          ],
        ),
      ),
    );
  }

  Widget _buildInfo(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header row with name and badges
        Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: data.isOnline
                  ? AppColors.success.withValues(alpha: 0.16)
                  : AppColors.warning.withValues(alpha: 0.16),
              child: Icon(
                data.isOnline ? Icons.podcasts : Icons.podcasts_outlined,
                color: data.isOnline ? AppColors.success : AppColors.warning,
                size: 16,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                data.name,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        // Status badge row
        Row(
          children: [
            CcBadge(
              label: data.status,
              color: data.isOnline ? AppColors.success : AppColors.warning,
              size: CcBadgeSize.small,
            ),
            if (data.alertCount != null && data.alertCount! > 0) ...[
              const SizedBox(width: 6),
              CcBadge(
                label: '${data.alertCount} alerts',
                color: AppColors.primary,
                size: CcBadgeSize.small,
              ),
            ],
          ],
        ),

        const SizedBox(height: 6),

        // Fingerprint
        Row(
          children: [
            const Icon(Icons.fingerprint, size: 12, color: AppColors.muted),
            const SizedBox(width: 4),
            Text(
              data.fingerprint.length > 12
                  ? data.fingerprint.substring(0, 12)
                  : data.fingerprint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
            ),
          ],
        ),

        // IP
        if (data.lastKnownIp != null) ...[
          const SizedBox(height: 2),
          Row(
            children: [
              const Icon(Icons.lan, size: 12, color: AppColors.muted),
              const SizedBox(width: 4),
              Text(
                data.lastKnownIp!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                      fontSize: 11,
                    ),
              ),
            ],
          ),
        ],

        // Last noise
        const SizedBox(height: 4),
        Row(
          children: [
            const Icon(Icons.notifications_active, size: 12, color: AppColors.primary),
            const SizedBox(width: 4),
            Text(
              'Last noise: ${_formatTimestamp(data.lastNoiseEpochMs)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    fontSize: 11,
                  ),
            ),
          ],
        ),

        // Last seen (only show when offline)
        if (!data.isOnline && data.lastSeenEpochMs != null) ...[
          const SizedBox(height: 2),
          Row(
            children: [
              const Icon(Icons.visibility, size: 12, color: AppColors.muted),
              const SizedBox(width: 4),
              Text(
                'Last seen: ${_formatTimestamp(data.lastSeenEpochMs)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                      fontSize: 11,
                    ),
              ),
            ],
          ),
        ],

        // Action buttons row
        const SizedBox(height: 8),
        Row(
          children: [
            if (data.onSettings != null)
              _SmallIconButton(
                icon: Icons.settings,
                tooltip: 'Settings',
                onPressed: data.onSettings,
              ),
            if (data.onForget != null)
              _SmallIconButton(
                icon: Icons.delete_outline,
                tooltip: 'Forget',
                onPressed: data.onForget,
                color: Colors.red,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildRightSide(
    BuildContext context,
    WidgetRef ref,
    bool showStreamingUI,
    bool isStreamConnected,
    bool isStreamConnecting,
  ) {
    final hasConnection = data.isOnline || data.connectTarget != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Connection toggle (for notifications)
        _buildConnectionToggle(context, hasConnection),

        const SizedBox(height: 8),

        // Audio streaming controls (only when control connection is established)
        if (data.isConnected)
          _buildStreamingControls(
              context, ref, showStreamingUI, isStreamConnected, isStreamConnecting)
        else if (data.isConnecting)
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }

  Widget _buildConnectionToggle(BuildContext context, bool hasConnection) {
    // Connected state - show disconnect option
    if (data.isConnected) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.success,
                  ),
                ),
                const SizedBox(width: 4),
                const Text(
                  'Connected',
                  style: TextStyle(
                    color: AppColors.success,
                    fontWeight: FontWeight.w600,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          _SmallIconButton(
            icon: Icons.link_off,
            tooltip: 'Disconnect',
            onPressed: data.onDisconnect,
            color: AppColors.muted,
          ),
        ],
      );
    }

    // Connecting state
    if (data.isConnecting) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 6),
            Text(
              'Connecting...',
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
                fontSize: 10,
              ),
            ),
          ],
        ),
      );
    }

    // Disconnected state - show connect button
    final canConnect = hasConnection && data.onConnect != null;
    return OutlinedButton.icon(
      onPressed: canConnect ? data.onConnect : null,
      icon: const Icon(Icons.link, size: 14),
      label: Text(data.isOnline ? 'Connect' : 'Try connect'),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        textStyle: const TextStyle(fontSize: 11),
        minimumSize: Size.zero,
      ),
    );
  }

  Widget _buildStreamingControls(
    BuildContext context,
    WidgetRef ref,
    bool showStreamingUI,
    bool isConnected,
    bool isConnecting,
  ) {
    // Currently streaming
    if (showStreamingUI) {
      final audioStream =
          ref.read(streamingProvider.notifier).audioDataStream;

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Live indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isConnected
                  ? AppColors.success.withValues(alpha: 0.15)
                  : AppColors.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isConnecting)
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
                    ),
                  )
                else
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.success,
                    ),
                  ),
                const SizedBox(width: 6),
                Text(
                  isConnected ? 'LIVE' : 'Starting...',
                  style: TextStyle(
                    color: isConnected ? AppColors.success : AppColors.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),

          // Sound wave visualization
          if (isConnected) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: 100,
              child: LiveSoundWave(
                audioStream: audioStream,
                barCount: 20,
                height: 50,
              ),
            ),
          ],

          const SizedBox(height: 6),

          // Stop button
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Material(
                color: Colors.red.withValues(alpha: 0.9),
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: data.onStop,
                  customBorder: const CircleBorder(),
                  child: const SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(Icons.stop, color: Colors.white, size: 22),
                  ),
                ),
              ),
              if (isConnected) ...[
                const SizedBox(width: 6),
                _SmallIconButton(
                  icon: Icons.push_pin,
                  tooltip: 'Keep alive',
                  onPressed: () {
                    ref.read(streamingProvider.notifier).pinStream();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Stream pinned'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ],
      );
    }

    // Not streaming - show play button
    return Material(
      color: AppColors.primary,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: data.onListen,
        customBorder: const CircleBorder(),
        child: const SizedBox(
          width: 40,
          height: 40,
          child: Icon(Icons.play_arrow, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

/// A discovered (unpaired) monitor item - simpler card.
class DiscoveredMonitorItem extends StatelessWidget {
  const DiscoveredMonitorItem({
    super.key,
    required this.data,
  });

  final MonitorItemData data;

  @override
  Widget build(BuildContext context) {
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
          // Monitor icon
          CircleAvatar(
            radius: 16,
            backgroundColor: AppColors.primary.withValues(alpha: 0.1),
            child: const Icon(
              Icons.podcasts,
              color: AppColors.primary,
              size: 16,
            ),
          ),

          const SizedBox(width: 10),

          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.name,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.fingerprint, size: 12, color: AppColors.muted),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        data.fingerprint.isNotEmpty
                            ? data.fingerprint
                            : '(no fingerprint)',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppColors.muted,
                              fontFamily: 'monospace',
                              fontSize: 10,
                            ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (data.lastKnownIp != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    data.lastKnownIp!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.muted,
                          fontSize: 10,
                        ),
                  ),
                ],
              ],
            ),
          ),

          // Pair button
          OutlinedButton.icon(
            onPressed: data.onPair,
            icon: const Icon(Icons.link, size: 16),
            label: const Text('Pair'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallIconButton extends StatelessWidget {
  const _SmallIconButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      style: IconButton.styleFrom(
        foregroundColor: color ?? AppColors.muted,
        padding: const EdgeInsets.all(6),
        minimumSize: const Size(28, 28),
      ),
    );
  }
}

String _formatTimestamp(int? epochMs) {
  if (epochMs == null || epochMs == 0) return 'Never';
  final ts = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final diff = DateTime.now().difference(ts);
  if (diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} hr ago';
  return '${diff.inDays} d ago';
}
