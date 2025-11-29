import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show protected;

/// Lifecycle states for managed services.
enum ServiceLifecycleState {
  /// Service has never been started.
  uninitialized,

  /// Service is starting up.
  starting,

  /// Service is fully operational.
  running,

  /// Service is shutting down.
  stopping,

  /// Service has been stopped.
  stopped,

  /// Service encountered an error.
  error,
}

/// Standard lifecycle interface for all managed services.
///
/// Services declare their dependencies via [dependencies], and the
/// [ServiceCoordinator] ensures correct startup/shutdown ordering.
abstract class ManagedService {
  /// Unique identifier for this service (e.g., 'control_server').
  String get serviceId;

  /// Human-readable name for logging.
  String get serviceName;

  /// Current lifecycle state.
  ServiceLifecycleState get state;

  /// Stream of state changes for reactive monitoring.
  Stream<ServiceLifecycleState> get stateChanges;

  /// List of service IDs this service depends on.
  /// Dependencies will be started before this service.
  List<String> get dependencies;

  /// Start the service and its resources.
  /// Only called when all dependencies are running.
  Future<void> start();

  /// Stop the service gracefully.
  /// Called before any dependents are stopped.
  Future<void> stop();

  /// Dispose of resources (called after stop, only once).
  Future<void> dispose();
}

/// Base implementation of [ManagedService] with state management.
///
/// Controllers should extend this class and implement [onStart] and [onStop].
abstract class BaseManagedService implements ManagedService {
  BaseManagedService(this.serviceId, this.serviceName);

  @override
  final String serviceId;

  @override
  final String serviceName;

  ServiceLifecycleState _state = ServiceLifecycleState.uninitialized;
  final _stateController = StreamController<ServiceLifecycleState>.broadcast();
  bool _disposed = false;

  @override
  ServiceLifecycleState get state => _state;

  @override
  Stream<ServiceLifecycleState> get stateChanges => _stateController.stream;

  @override
  List<String> get dependencies => const [];

  /// Update state and notify listeners.
  @protected
  void setState(ServiceLifecycleState newState) {
    if (_disposed) return;
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
      _log('state -> ${newState.name}');
    }
  }

  @override
  Future<void> start() async {
    if (_disposed) {
      throw StateError('Cannot start disposed service: $serviceName');
    }
    if (_state == ServiceLifecycleState.running) {
      _log('already running');
      return;
    }
    if (_state == ServiceLifecycleState.starting) {
      _log('already starting, waiting...');
      await stateChanges.firstWhere(
        (s) => s == ServiceLifecycleState.running || s == ServiceLifecycleState.error,
      );
      return;
    }

    setState(ServiceLifecycleState.starting);
    try {
      await onStart();
      setState(ServiceLifecycleState.running);
    } catch (e, stack) {
      _log('start failed: $e\n$stack');
      setState(ServiceLifecycleState.error);
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    if (_state == ServiceLifecycleState.stopped ||
        _state == ServiceLifecycleState.uninitialized) {
      return;
    }
    if (_state == ServiceLifecycleState.stopping) {
      _log('already stopping, waiting...');
      await stateChanges.firstWhere(
        (s) => s == ServiceLifecycleState.stopped || s == ServiceLifecycleState.error,
      );
      return;
    }

    setState(ServiceLifecycleState.stopping);
    try {
      await onStop();
      setState(ServiceLifecycleState.stopped);
    } catch (e, stack) {
      _log('stop failed: $e\n$stack');
      setState(ServiceLifecycleState.error);
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    if (_state == ServiceLifecycleState.running ||
        _state == ServiceLifecycleState.starting) {
      await stop();
    }

    await _stateController.close();
  }

  /// Override to implement service startup logic.
  @protected
  Future<void> onStart();

  /// Override to implement service shutdown logic.
  @protected
  Future<void> onStop();

  void _log(String message) {
    developer.log('[$serviceName] $message', name: 'lifecycle');
  }
}

/// A meta-service that groups other services without doing any work itself.
///
/// Useful for creating logical service stacks (e.g., 'monitor_stack').
class MetaService extends BaseManagedService {
  MetaService({
    required String serviceId,
    required String serviceName,
    required List<String> dependencies,
  })  : _dependencies = dependencies,
        super(serviceId, serviceName);

  final List<String> _dependencies;

  @override
  List<String> get dependencies => _dependencies;

  @override
  Future<void> onStart() async {
    // No-op: dependencies are started by coordinator
  }

  @override
  Future<void> onStop() async {
    // No-op: dependents are stopped by coordinator
  }
}
