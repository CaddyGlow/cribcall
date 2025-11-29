import 'dart:async';
import 'dart:developer' as developer;

import 'service_lifecycle.dart';

/// Configuration for service startup/shutdown behavior.
class ServiceCoordinatorConfig {
  const ServiceCoordinatorConfig({
    this.startupTimeout = const Duration(seconds: 30),
    this.shutdownTimeout = const Duration(seconds: 10),
  });

  /// Maximum time to wait for a service to start.
  final Duration startupTimeout;

  /// Maximum time to wait for a service to stop.
  final Duration shutdownTimeout;
}

/// Orchestrates service lifecycle with dependency resolution.
///
/// Services are started in topological order (dependencies first) and
/// stopped in reverse order (dependents first).
class ServiceCoordinator {
  ServiceCoordinator({
    ServiceCoordinatorConfig? config,
  }) : _config = config ?? const ServiceCoordinatorConfig();

  final ServiceCoordinatorConfig _config;
  final Map<String, ManagedService> _services = {};
  final Map<String, List<String>> _dependencyGraph = {};
  final Map<String, List<String>> _reverseDependencyGraph = {};
  bool _isShuttingDown = false;

  /// Register a service with the coordinator.
  ///
  /// Throws [StateError] if a service with the same ID is already registered.
  void registerService(ManagedService service) {
    if (_services.containsKey(service.serviceId)) {
      throw StateError('Service ${service.serviceId} already registered');
    }

    _services[service.serviceId] = service;
    _dependencyGraph[service.serviceId] = List.of(service.dependencies);

    // Build reverse dependency graph (who depends on me)
    for (final dep in service.dependencies) {
      _reverseDependencyGraph.putIfAbsent(dep, () => []);
      _reverseDependencyGraph[dep]!.add(service.serviceId);
    }

    _log('registered: ${service.serviceName} (${service.serviceId})');
  }

  /// Unregister a service from the coordinator.
  ///
  /// The service must be stopped before unregistering.
  void unregisterService(String serviceId) {
    final service = _services[serviceId];
    if (service == null) return;

    if (service.state == ServiceLifecycleState.running ||
        service.state == ServiceLifecycleState.starting) {
      throw StateError('Cannot unregister running service: $serviceId');
    }

    // Remove from reverse graph
    for (final dep in _dependencyGraph[serviceId] ?? []) {
      _reverseDependencyGraph[dep]?.remove(serviceId);
    }

    _services.remove(serviceId);
    _dependencyGraph.remove(serviceId);
    _reverseDependencyGraph.remove(serviceId);

    _log('unregistered: $serviceId');
  }

  /// Start all registered services in dependency order.
  Future<void> startAll() async {
    _log('starting all services...');
    _isShuttingDown = false;

    final startOrder = _topologicalSort();

    for (final serviceId in startOrder) {
      if (_isShuttingDown) {
        _log('shutdown requested, aborting startup');
        break;
      }
      await _startService(serviceId);
    }

    _log('all services started');
  }

  /// Start a specific service and its dependencies.
  ///
  /// Dependencies are started transitively in correct order.
  Future<void> startService(String serviceId) async {
    if (!_services.containsKey(serviceId)) {
      throw ArgumentError('Unknown service: $serviceId');
    }

    // Find all dependencies (transitive closure)
    final toStart = _getDependencyClosure(serviceId);
    final startOrder = _topologicalSort(subset: toStart);

    for (final id in startOrder) {
      await _startService(id);
    }
  }

  /// Stop all services in reverse dependency order.
  Future<void> stopAll() async {
    _isShuttingDown = true;
    _log('stopping all services...');

    final stopOrder = _topologicalSort().reversed.toList();

    for (final serviceId in stopOrder) {
      await _stopService(serviceId);
    }

    _log('all services stopped');
  }

  /// Stop a specific service and all its dependents.
  ///
  /// Dependents are stopped transitively in correct order.
  Future<void> stopService(String serviceId) async {
    if (!_services.containsKey(serviceId)) {
      throw ArgumentError('Unknown service: $serviceId');
    }

    // Find all dependents (reverse transitive closure)
    final toStop = _getDependentClosure(serviceId);
    final stopOrder = _topologicalSort(subset: toStop).reversed.toList();

    for (final id in stopOrder) {
      await _stopService(id);
    }
  }

  /// Restart a service and all its dependents.
  ///
  /// Stops the service and its dependents, then restarts them all in order.
  Future<void> restartService(String serviceId) async {
    // Get all dependents (services that depend on this one)
    final toRestart = _getDependentClosure(serviceId);

    // Stop in reverse order (dependents first)
    await stopService(serviceId);

    // Restart all in dependency order
    final startOrder = _topologicalSort(subset: toRestart);
    for (final id in startOrder) {
      await _startService(id);
    }
  }

  /// Get service by ID.
  ManagedService? getService(String serviceId) => _services[serviceId];

  /// Get all registered services.
  Iterable<ManagedService> get services => _services.values;

  /// Get all services in a specific state.
  List<ManagedService> getServicesInState(ServiceLifecycleState state) {
    return _services.values.where((s) => s.state == state).toList();
  }

  /// Get current status of all services.
  Map<String, ServiceLifecycleState> getStatus() {
    return Map.fromEntries(
      _services.entries.map((e) => MapEntry(e.key, e.value.state)),
    );
  }

  /// Get the dependency graph for debugging/visualization.
  Map<String, List<String>> getDependencyGraph() {
    return Map.unmodifiable(_dependencyGraph);
  }

  Future<void> _startService(String serviceId) async {
    final service = _services[serviceId];
    if (service == null) {
      throw StateError('Cannot start unknown service: $serviceId');
    }

    if (service.state == ServiceLifecycleState.running) {
      return;
    }

    // Wait for dependencies to be running
    await _waitForDependencies(serviceId);

    _log('starting ${service.serviceName}...');

    try {
      await service.start().timeout(_config.startupTimeout);
      _log('started ${service.serviceName}');
    } on TimeoutException {
      _log('timeout starting ${service.serviceName}');
      rethrow;
    } catch (e, stack) {
      _log('failed to start ${service.serviceName}: $e\n$stack');
      rethrow;
    }
  }

  Future<void> _stopService(String serviceId) async {
    final service = _services[serviceId];
    if (service == null) return;

    if (service.state == ServiceLifecycleState.stopped ||
        service.state == ServiceLifecycleState.uninitialized) {
      return;
    }

    _log('stopping ${service.serviceName}...');

    try {
      await service.stop().timeout(_config.shutdownTimeout);
      _log('stopped ${service.serviceName}');
    } on TimeoutException {
      _log('timeout stopping ${service.serviceName}');
      // Continue shutdown even on timeout
    } catch (e, stack) {
      _log('error stopping ${service.serviceName}: $e\n$stack');
      // Continue shutdown even on error
    }
  }

  Future<void> _waitForDependencies(String serviceId) async {
    final deps = _dependencyGraph[serviceId] ?? [];

    for (final depId in deps) {
      final depService = _services[depId];
      if (depService == null) {
        throw StateError(
          'Service $serviceId depends on unknown service $depId',
        );
      }

      if (depService.state == ServiceLifecycleState.running) {
        continue;
      }

      if (depService.state == ServiceLifecycleState.error) {
        throw StateError(
          'Dependency $depId is in error state, cannot start $serviceId',
        );
      }

      // Wait for dependency to be running
      _log('waiting for dependency $depId...');
      await depService.stateChanges
          .firstWhere((s) =>
              s == ServiceLifecycleState.running ||
              s == ServiceLifecycleState.error)
          .timeout(_config.startupTimeout);

      if (depService.state == ServiceLifecycleState.error) {
        throw StateError(
          'Dependency $depId failed to start, cannot start $serviceId',
        );
      }
    }
  }

  /// Topological sort for dependency-ordered startup.
  ///
  /// Throws [StateError] if a circular dependency is detected.
  List<String> _topologicalSort({Set<String>? subset}) {
    final workingSet = subset ?? _services.keys.toSet();
    final sorted = <String>[];
    final visited = <String>{};
    final visiting = <String>{};

    void visit(String serviceId) {
      if (!workingSet.contains(serviceId)) return;
      if (visited.contains(serviceId)) return;

      if (visiting.contains(serviceId)) {
        throw StateError('Circular dependency detected involving $serviceId');
      }

      visiting.add(serviceId);

      for (final dep in _dependencyGraph[serviceId] ?? []) {
        if (workingSet.contains(dep)) {
          visit(dep);
        }
      }

      visiting.remove(serviceId);
      visited.add(serviceId);
      sorted.add(serviceId);
    }

    for (final serviceId in workingSet) {
      visit(serviceId);
    }

    return sorted;
  }

  /// Get transitive closure of dependencies.
  Set<String> _getDependencyClosure(String serviceId) {
    final closure = <String>{serviceId};
    final toVisit = [serviceId];

    while (toVisit.isNotEmpty) {
      final current = toVisit.removeLast();
      for (final dep in _dependencyGraph[current] ?? []) {
        if (closure.add(dep)) {
          toVisit.add(dep);
        }
      }
    }

    return closure;
  }

  /// Get transitive closure of dependents.
  Set<String> _getDependentClosure(String serviceId) {
    final closure = <String>{serviceId};
    final toVisit = [serviceId];

    while (toVisit.isNotEmpty) {
      final current = toVisit.removeLast();
      for (final dependent in _reverseDependencyGraph[current] ?? []) {
        if (closure.add(dependent)) {
          toVisit.add(dependent);
        }
      }
    }

    return closure;
  }

  void _log(String message) {
    developer.log(message, name: 'coordinator');
  }

  /// Dispose all services and coordinator resources.
  Future<void> dispose() async {
    await stopAll();

    for (final service in _services.values) {
      await service.dispose();
    }

    _services.clear();
    _dependencyGraph.clear();
    _reverseDependencyGraph.clear();
  }
}
