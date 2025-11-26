import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../control/control_service.dart';
import '../../domain/models.dart';
import '../../fcm/fcm_service.dart';
import '../../state/app_state.dart';
import 'listener_stream_page.dart';

/// Widget that listens for noise events and shows the streaming page.
/// Wrap your main content with this to enable auto-open stream on noise.
class NoiseEventHandler extends ConsumerStatefulWidget {
  const NoiseEventHandler({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  ConsumerState<NoiseEventHandler> createState() => _NoiseEventHandlerState();
}

class _NoiseEventHandlerState extends ConsumerState<NoiseEventHandler> {
  StreamSubscription<NoiseEventData>? _noiseSubscription;
  bool _streamPageOpen = false;

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
    _log('Noise event received: monitorId=${event.monitorId} peak=${event.peakLevel}');

    if (!mounted) return;

    // Check if auto-open is enabled
    final listenerSettings = ref.read(listenerSettingsProvider).asData?.value;
    final defaultAction = listenerSettings?.defaultAction ?? ListenerDefaultAction.notify;

    if (defaultAction == ListenerDefaultAction.autoOpenStream) {
      _openStreamPage(event);
    } else {
      _showNoiseNotification(event);
    }
  }

  void _openStreamPage(NoiseEventData event) {
    if (_streamPageOpen) {
      _log('Stream page already open, ignoring');
      return;
    }

    _log('Opening stream page for noise event');
    _streamPageOpen = true;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ListenerStreamPage(
          monitorName: event.monitorName,
          autoStart: true,
        ),
      ),
    ).then((_) {
      _streamPageOpen = false;
    });
  }

  void _showNoiseNotification(NoiseEventData event) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.notifications_active, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Noise detected',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    event.monitorName,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'Listen',
          onPressed: () => _openStreamPage(event),
        ),
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
      ),
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
