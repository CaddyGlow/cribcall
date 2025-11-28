import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../routing/app_router.dart';
import '../state/app_state.dart';
import 'notification_service.dart';

/// Handles notification responses (taps and action buttons).
///
/// This class bridges notifications with the app's navigation and state
/// management. It must be initialized after the router and Riverpod
/// container are set up.
class NotificationActionHandler {
  NotificationActionHandler._();

  static final instance = NotificationActionHandler._();

  GoRouter? _router;
  WidgetRef? _ref;

  /// Initialize the handler with the router and a WidgetRef.
  ///
  /// Call this from a widget that has access to both the router
  /// and Riverpod ref (typically the root app widget).
  void initialize({
    required GoRouter router,
    required WidgetRef ref,
  }) {
    _router = router;
    _ref = ref;

    // Register the callback with NotificationService
    NotificationService.instance.onNotificationResponse = _handleResponse;

    _log('NotificationActionHandler initialized');
  }

  void _handleResponse(NotificationResponse response) {
    final payload = response.payload;
    final actionId = response.actionId;

    _log('Handling notification response: actionId=$actionId payload=$payload');

    if (payload == null || payload.isEmpty) {
      _log('No payload, ignoring');
      return;
    }

    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final type = data['type'] as String?;

      if (type == 'pairing') {
        _handlePairingResponse(
          actionId: actionId,
          sessionId: data['sessionId'] as String?,
        );
      } else {
        _log('Unknown notification type: $type');
      }
    } catch (e) {
      _log('Error parsing payload: $e');
    }
  }

  void _handlePairingResponse({
    String? actionId,
    String? sessionId,
  }) {
    final ref = _ref;
    final router = _router;

    if (ref == null || router == null) {
      _log('Handler not initialized, cannot process pairing response');
      return;
    }

    if (sessionId == null) {
      _log('No sessionId in pairing response');
      return;
    }

    switch (actionId) {
      case NotificationService.actionAccept:
        _log('Accept action tapped for session $sessionId');
        // Accept the pairing directly
        final success = ref
            .read(pairingServerProvider.notifier)
            .confirmSession(sessionId);
        if (success) {
          // Navigate to monitor to show result
          router.go(AppRoutes.monitor);
        }

      case NotificationService.actionDeny:
        _log('Deny action tapped for session $sessionId');
        // Reject the pairing
        ref.read(pairingServerProvider.notifier).rejectSession(sessionId);
        // No navigation needed - notification is auto-cancelled

      default:
        // Notification body was tapped (not an action button)
        _log('Notification body tapped, navigating to pairing drawer');
        // Navigate to monitor with pairing drawer open
        router.go(AppRoutes.monitorPairing);
    }
  }

  void _log(String message) {
    developer.log(message, name: 'notification_action_handler');
  }
}
