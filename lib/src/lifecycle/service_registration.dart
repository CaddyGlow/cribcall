/// Service registration for the ServiceCoordinator.
///
/// Registers all managed services with the coordinator and sets up
/// the reactive lifecycle provider that orchestrates service startup/shutdown.
library;

import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/build_flags.dart';
import '../domain/models.dart';
import '../fcm/fcm_service.dart';
import '../notifications/notification_service.dart';
import '../state/app_state.dart';
import 'riverpod_integration.dart';
import 'service_coordinator.dart';
import 'service_lifecycle.dart';

void _log(String message) {
  developer.log(message, name: 'lifecycle');
}

/// Registers all managed services with the coordinator.
///
/// Call this once during app initialization after the coordinator is created.
void registerAllServices(ServiceCoordinator coordinator, Ref ref) {
  _log('Registering services...');

  // Core infrastructure services (singletons, no dependencies)
  coordinator.registerService(NotificationService.instance);
  coordinator.registerService(FcmService.instance);

  // Monitor stack services
  coordinator.registerService(RiverpodManagedService(
    serviceId: 'pairing_server',
    serviceName: 'Pairing Server',
    ref: ref,
    dependencies: ['notifications'],
    onStartAction: () async {
      final identity = await ref.read(identityProvider.future);
      final session = await ref.read(appSessionProvider.future);
      await ref.read(pairingServerProvider.notifier).start(
            identity: identity,
            port: kPairingDefaultPort,
            monitorName: session.deviceName,
          );
    },
    onStopAction: () async {
      await ref.read(pairingServerProvider.notifier).stop();
    },
  ));

  coordinator.registerService(RiverpodManagedService(
    serviceId: 'control_server',
    serviceName: 'Control Server',
    ref: ref,
    dependencies: [],
    onStartAction: () async {
      final identity = await ref.read(identityProvider.future);
      final listeners = await ref.read(trustedListenersProvider.future);
      await ref.read(controlServerProvider.notifier).start(
            identity: identity,
            port: kControlDefaultPort,
            trustedPeers: listeners,
          );
    },
    onStopAction: () async {
      await ref.read(controlServerProvider.notifier).stop();
    },
  ));

  coordinator.registerService(RiverpodManagedService(
    serviceId: 'audio_capture',
    serviceName: 'Audio Capture',
    ref: ref,
    dependencies: ['control_server'],
    onStartAction: () async {
      final identity = await ref.read(identityProvider.future);
      final session = await ref.read(appSessionProvider.future);
      final settings = await ref.read(monitorSettingsProvider.future);
      final controlState = ref.read(controlServerProvider);
      final pairingState = ref.read(pairingServerProvider);
      final builder = ref.read(serviceIdentityProvider);

      final mdnsAd = builder.buildMdnsAdvertisement(
        identity: identity,
        monitorName: session.deviceName,
        controlPort: controlState.port ?? kControlDefaultPort,
        pairingPort: pairingState.port ?? kPairingDefaultPort,
      );

      await ref.read(audioCaptureProvider.notifier).start(
            settings: settings.noise,
            mdnsAdvertisement: mdnsAd,
            inputDeviceId: settings.audioInputDeviceId,
            inputGainPercent: settings.audioInputGain,
            onNoise: (event) {
              ref.read(controlServerProvider.notifier).broadcastNoiseEvent(
                    timestampMs: event.timestampMs,
                    peakLevel: event.peakLevel,
                  );
            },
          );
    },
    onStopAction: () async {
      await ref.read(audioCaptureProvider.notifier).stop();
    },
  ));

  // Listener stack services
  coordinator.registerService(RiverpodManagedService(
    serviceId: 'control_client',
    serviceName: 'Control Client',
    ref: ref,
    dependencies: ['fcm'],
    onStartAction: () async {
      // Control client is user-initiated, not auto-started
      // This service just ensures FCM is ready before connection
    },
    onStopAction: () async {
      await ref.read(controlClientProvider.notifier).disconnect();
    },
  ));

  // Meta-services for logical groupings
  coordinator.registerService(MetaService(
    serviceId: 'monitor_stack',
    serviceName: 'Monitor Stack',
    dependencies: [
      'notifications',
      'fcm',
      'pairing_server',
      'control_server',
      'audio_capture',
    ],
  ));

  coordinator.registerService(MetaService(
    serviceId: 'listener_stack',
    serviceName: 'Listener Stack',
    dependencies: [
      'notifications',
      'fcm',
      'control_client',
    ],
  ));

  _log('Services registered: ${coordinator.services.map((s) => s.serviceId).join(", ")}');
}

/// Derived provider that only emits when the trusted listener FINGERPRINTS change.
/// This prevents server restarts when only metadata (like FCM tokens) are updated.
final _trustedListenerFingerprintsProvider = Provider<Set<String>?>((ref) {
  final listeners = ref.watch(trustedListenersProvider);
  final data = listeners.asData?.value;
  if (data == null) return null;
  return data.map((p) => p.certFingerprint).toSet();
});

/// Provider that orchestrates service lifecycle based on app state.
///
/// This replaces the old controlServerAutoStartProvider and audioCaptureAutoStartProvider.
/// It watches the role and monitoring status to determine which services to run.
final serviceLifecycleProvider = Provider<void>((ref) {
  final coordinator = ref.watch(serviceCoordinatorProvider);

  // Register services on first access
  ensureServicesRegistered(coordinator, ref, registerAllServices);
  final role = ref.watch(roleProvider);
  final monitoringEnabled = ref.watch(monitoringStatusProvider);
  final identity = ref.watch(identityProvider);
  final appSession = ref.watch(appSessionProvider);

  // For monitor mode, also watch trusted listeners and settings
  final trustedFingerprints = ref.watch(_trustedListenerFingerprintsProvider);
  final monitorSettings = ref.watch(monitorSettingsProvider);

  // Determine target state
  final shouldRunMonitorStack = role == DeviceRole.monitor &&
      monitoringEnabled &&
      identity.hasValue &&
      appSession.hasValue &&
      trustedFingerprints != null &&
      monitorSettings.hasValue;

  final shouldRunListenerStack = role == DeviceRole.listener &&
      identity.hasValue;

  _log(
    'Lifecycle check: role=${role?.name} '
    'monitoring=$monitoringEnabled '
    'shouldMonitor=$shouldRunMonitorStack '
    'shouldListen=$shouldRunListenerStack',
  );

  // Use microtask to avoid modifying state during build
  Future.microtask(() async {
    try {
      if (shouldRunMonitorStack) {
        // Start monitor stack (coordinator handles idempotency)
        await coordinator.startService('monitor_stack');
      } else if (shouldRunListenerStack) {
        // Stop monitor services if switching from monitor to listener
        final monitorServices = ['audio_capture', 'control_server', 'pairing_server'];
        for (final svc in monitorServices) {
          final service = coordinator.getService(svc);
          if (service != null && service.state == ServiceLifecycleState.running) {
            await coordinator.stopService(svc);
          }
        }
        // Start listener stack
        await coordinator.startService('listener_stack');
      } else {
        // No active role or monitoring disabled - stop all services
        await coordinator.stopAll();
      }
    } catch (e, stack) {
      _log('Service lifecycle error: $e\n$stack');
    }
  });
});
