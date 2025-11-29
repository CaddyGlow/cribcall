/// Integration layer between ServiceCoordinator and Riverpod.
///
/// Provides adapters that wrap Riverpod providers/notifiers as ManagedServices,
/// allowing the ServiceCoordinator to orchestrate their lifecycle.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'service_coordinator.dart';
import 'service_lifecycle.dart';

/// A managed service that wraps a Riverpod provider.
///
/// This allows Riverpod-based services to be coordinated by the ServiceCoordinator
/// without requiring the underlying providers to change their implementation.
class RiverpodManagedService<T> extends BaseManagedService {
  RiverpodManagedService({
    required String serviceId,
    required String serviceName,
    required this.ref,
    required this.onStartAction,
    this.onStopAction,
    List<String> dependencies = const [],
  })  : _dependencies = dependencies,
        super(serviceId, serviceName);

  final Ref ref;
  final Future<void> Function() onStartAction;
  final Future<void> Function()? onStopAction;
  final List<String> _dependencies;

  @override
  List<String> get dependencies => _dependencies;

  @override
  Future<void> onStart() async {
    await onStartAction();
  }

  @override
  Future<void> onStop() async {
    await onStopAction?.call();
  }
}

/// Provider for a ServiceCoordinator that manages the app's service lifecycle.
///
/// Services are registered lazily when serviceLifecycleProvider is first watched.
final serviceCoordinatorProvider = Provider<ServiceCoordinator>((ref) {
  final coordinator = ServiceCoordinator();

  ref.onDispose(() {
    coordinator.dispose();
  });

  return coordinator;
});

/// Whether services have been registered with the coordinator.
bool _servicesRegistered = false;

/// Ensures services are registered with the coordinator.
/// This is called from serviceLifecycleProvider on first access.
void ensureServicesRegistered(
  ServiceCoordinator coordinator,
  Ref ref,
  void Function(ServiceCoordinator, Ref) registrationFn,
) {
  if (!_servicesRegistered) {
    registrationFn(coordinator, ref);
    _servicesRegistered = true;
  }
}
