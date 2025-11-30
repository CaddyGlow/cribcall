import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../control/control_service.dart';
import '../../domain/models.dart';
import '../../fcm/fcm_service.dart';
import '../../notifications/notification_service.dart';
import '../../state/app_state.dart';
import '../../state/connected_monitor_settings.dart';
import '../../webrtc/webrtc_controller.dart';

/// Widget that listens for noise events and triggers auto-play or notifications.
/// Wrap your main content with this to enable auto-open stream on noise.
class NoiseEventHandler extends ConsumerStatefulWidget {
  const NoiseEventHandler({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<NoiseEventHandler> createState() => _NoiseEventHandlerState();
}

class _NoiseEventHandlerState extends ConsumerState<NoiseEventHandler> {
  StreamSubscription<NoiseEventData>? _noiseSubscription;

  @override
  void initState() {
    super.initState();
    _subscribeToNoiseEvents();
  }

  void _subscribeToNoiseEvents() {
    // Subscribe after first frame to ensure providers are ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _log('Not mounted, skipping subscription');
        return;
      }

      try {
        final controlClient = ref.read(controlClientProvider.notifier);
        _noiseSubscription?.cancel();
        _noiseSubscription = controlClient.noiseEvents.listen(
          _handleNoiseEvent,
          onError: (e) => _log('Noise event stream error: $e'),
          onDone: () => _log('Noise event stream done'),
        );
        _log('Subscribed to noise events stream');
      } catch (e) {
        _log('Error subscribing to noise events: $e');
      }
    });
  }

  void _handleNoiseEvent(NoiseEventData event) {
    _log(
      'Noise event received: remoteDeviceId=${event.remoteDeviceId} peak=${event.peakLevel}',
    );

    if (!mounted) return;

    // Check per-monitor settings first (monitor defaults + listener overrides)
    final connectedSettingsState = ref
        .read(connectedMonitorSettingsProvider)
        .asData
        ?.value;
    final monitorSettings = connectedSettingsState?.getOrDefault(
      event.remoteDeviceId,
    );

    // Check if notifications are enabled for this monitor
    if (monitorSettings?.notificationsEnabled == false) {
      _log('Notifications disabled for monitor ${event.remoteDeviceId}');
      return;
    }

    // Check if autoopen is paused globally
    final autoOpenPaused = ref.read(autoOpenPausedProvider);

    // Check if auto-play on noise is enabled for this monitor
    if (monitorSettings?.autoPlayOnNoise == true && !autoOpenPaused) {
      _startAutoPlay(event, monitorSettings!.autoPlayDurationSec);
      return;
    }

    // Fall back to global listener settings
    final listenerSettings = ref.read(listenerSettingsProvider).asData?.value;
    final defaultAction =
        listenerSettings?.defaultAction ?? ListenerDefaultAction.notify;

    if (defaultAction == ListenerDefaultAction.autoOpenStream && !autoOpenPaused) {
      _startAutoPlay(event, monitorSettings?.autoPlayDurationSec ?? 15);
    } else {
      _showNoiseNotification(event);
    }
  }

  Future<void> _startAutoPlay(NoiseEventData event, int durationSec) async {
    final streamState = ref.read(streamingProvider);
    final controlClientState = ref.read(controlClientProvider);

    // Don't interrupt existing streams
    if (streamState.status == StreamingStatus.connected ||
        streamState.status == StreamingStatus.connecting) {
      _log('Stream already active, ignoring auto-play');
      return;
    }

    _log('Starting auto-play for noise event (duration: ${durationSec}s)');

    // If not connected, try to connect first
    if (controlClientState.status != ControlClientStatus.connected) {
      _log(
        'Not connected, attempting to connect to monitor ${event.remoteDeviceId}',
      );

      final connected = await _connectToMonitor(event.remoteDeviceId);
      if (!connected) {
        _log('Failed to connect, showing notification instead');
        _showNoiseNotification(event);
        return;
      }
    }

    // Request stream
    ref.read(streamingProvider.notifier).requestStream();

    // Start auto-play session with timer via provider
    ref.read(autoPlaySessionProvider.notifier).startSession(
      monitorName: event.monitorName,
      durationSeconds: durationSec,
      onAutoStop: () {
        final currentState = ref.read(streamingProvider);
        if (currentState.status == StreamingStatus.connected) {
          ref.read(streamingProvider.notifier).endStream();
        }
      },
    );

    // Show notification about auto-play
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.play_circle, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Auto-playing ${event.monitorName} for ${durationSec}s',
                ),
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'Continue',
            onPressed: () {
              ref.read(autoPlaySessionProvider.notifier).continueStream();
            },
          ),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Connect to a monitor by ID. Returns true if successful.
  Future<bool> _connectToMonitor(String remoteDeviceId) async {
    try {
      // Get trusted monitor
      final trustedMonitors = await ref.read(trustedMonitorsProvider.future);
      final monitor = trustedMonitors
          .where((m) => m.remoteDeviceId == remoteDeviceId)
          .firstOrNull;

      if (monitor == null) {
        _log('Monitor $remoteDeviceId not in trusted list');
        return false;
      }

      // Get identity
      final identity = await ref.read(identityProvider.future);

      // Try to find monitor via mDNS first
      final advertisements = ref.read(discoveredMonitorsProvider);
      var ad = advertisements
          .where((a) => a.remoteDeviceId == remoteDeviceId)
          .firstOrNull;

      // Fall back to last known address if not discovered
      if (ad == null && monitor.lastKnownIp != null) {
        ad = MdnsAdvertisement(
          remoteDeviceId: monitor.remoteDeviceId,
          monitorName: monitor.monitorName,
          certFingerprint: monitor.certFingerprint,
          controlPort: monitor.controlPort,
          pairingPort: monitor.pairingPort,
          version: monitor.serviceVersion,
          transport: monitor.transport,
          ip: monitor.lastKnownIp,
        );
      }

      if (ad == null) {
        _log('No connection info for monitor $remoteDeviceId');
        return false;
      }

      // Connect
      final failure = await ref
          .read(controlClientProvider.notifier)
          .connectToMonitor(
            advertisement: ad,
            monitor: monitor,
            identity: identity,
          );

      if (failure != null) {
        _log('Connection failed: $failure');
        return false;
      }

      return true;
    } catch (e) {
      _log('Error connecting to monitor: $e');
      return false;
    }
  }

  void _showNoiseNotification(NoiseEventData event) {
    NotificationService.instance.showNoiseAlert(
      monitorName: event.monitorName,
      peakLevel: event.peakLevel,
    );
  }

  @override
  void dispose() {
    _noiseSubscription?.cancel();
    super.dispose();
  }

  void _log(String message) {
    developer.log(message, name: 'noise_handler');
    debugPrint('[noise_handler] $message');
  }

  @override
  Widget build(BuildContext context) {
    // Re-subscribe when control client changes
    ref.listen(controlClientProvider, (previous, next) {
      if (previous?.status != ControlClientStatus.connected &&
          next.status == ControlClientStatus.connected) {
        _subscribeToNoiseEvents();
      }
    });

    return widget.child;
  }
}
