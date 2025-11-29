import 'package:cribcall/src/lifecycle/service_coordinator.dart';
import 'package:cribcall/src/lifecycle/service_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ServiceCoordinator', () {
    late ServiceCoordinator coordinator;

    setUp(() {
      coordinator = ServiceCoordinator();
    });

    tearDown(() async {
      await coordinator.dispose();
    });

    group('registration', () {
      test('registers service', () {
        final service = _TestService('a');
        coordinator.registerService(service);

        expect(coordinator.getService('a'), equals(service));
      });

      test('throws on duplicate registration', () {
        coordinator.registerService(_TestService('a'));

        expect(
          () => coordinator.registerService(_TestService('a')),
          throwsA(isA<StateError>()),
        );
      });

      test('unregisters stopped service', () async {
        final service = _TestService('a');
        coordinator.registerService(service);

        coordinator.unregisterService('a');

        expect(coordinator.getService('a'), isNull);
      });

      test('throws when unregistering running service', () async {
        final service = _TestService('a');
        coordinator.registerService(service);
        await coordinator.startService('a');

        expect(
          () => coordinator.unregisterService('a'),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('startup ordering', () {
      test('starts services in dependency order', () async {
        final startOrder = <String>[];

        coordinator.registerService(_TestService('a', onStartCallback: () {
          startOrder.add('a');
        }));
        coordinator.registerService(_TestService('b', deps: ['a'], onStartCallback: () {
          startOrder.add('b');
        }));
        coordinator.registerService(_TestService('c', deps: ['a', 'b'], onStartCallback: () {
          startOrder.add('c');
        }));

        await coordinator.startAll();

        expect(startOrder, equals(['a', 'b', 'c']));
      });

      test('starts only requested service and its dependencies', () async {
        final startOrder = <String>[];

        coordinator.registerService(_TestService('a', onStartCallback: () {
          startOrder.add('a');
        }));
        coordinator.registerService(_TestService('b', deps: ['a'], onStartCallback: () {
          startOrder.add('b');
        }));
        coordinator.registerService(_TestService('c', onStartCallback: () {
          startOrder.add('c');
        }));

        await coordinator.startService('b');

        expect(startOrder, equals(['a', 'b']));
        expect(coordinator.getService('c')!.state, ServiceLifecycleState.uninitialized);
      });

      test('handles diamond dependencies', () async {
        final startOrder = <String>[];

        // Diamond: a -> b, a -> c, b -> d, c -> d
        coordinator.registerService(_TestService('a', deps: ['b', 'c'], onStartCallback: () {
          startOrder.add('a');
        }));
        coordinator.registerService(_TestService('b', deps: ['d'], onStartCallback: () {
          startOrder.add('b');
        }));
        coordinator.registerService(_TestService('c', deps: ['d'], onStartCallback: () {
          startOrder.add('c');
        }));
        coordinator.registerService(_TestService('d', onStartCallback: () {
          startOrder.add('d');
        }));

        await coordinator.startAll();

        // d must come first, then b and c (order between them doesn't matter), then a
        expect(startOrder.first, equals('d'));
        expect(startOrder.last, equals('a'));
        expect(startOrder.contains('b'), isTrue);
        expect(startOrder.contains('c'), isTrue);
      });

      test('does not restart already running service', () async {
        var startCount = 0;

        coordinator.registerService(_TestService('a', onStartCallback: () {
          startCount++;
        }));
        coordinator.registerService(_TestService('b', deps: ['a']));

        await coordinator.startService('a');
        await coordinator.startService('b');

        expect(startCount, equals(1));
      });
    });

    group('shutdown ordering', () {
      test('stops services in reverse dependency order', () async {
        final stopOrder = <String>[];

        coordinator.registerService(_TestService('a', onStopCallback: () {
          stopOrder.add('a');
        }));
        coordinator.registerService(_TestService('b', deps: ['a'], onStopCallback: () {
          stopOrder.add('b');
        }));
        coordinator.registerService(_TestService('c', deps: ['a', 'b'], onStopCallback: () {
          stopOrder.add('c');
        }));

        await coordinator.startAll();
        await coordinator.stopAll();

        expect(stopOrder, equals(['c', 'b', 'a']));
      });

      test('stops dependents when stopping a service', () async {
        final stopOrder = <String>[];

        coordinator.registerService(_TestService('a', onStopCallback: () {
          stopOrder.add('a');
        }));
        coordinator.registerService(_TestService('b', deps: ['a'], onStopCallback: () {
          stopOrder.add('b');
        }));
        coordinator.registerService(_TestService('c', deps: ['b'], onStopCallback: () {
          stopOrder.add('c');
        }));

        await coordinator.startAll();
        await coordinator.stopService('a');

        expect(stopOrder, equals(['c', 'b', 'a']));
      });

      test('stops only affected dependents', () async {
        final stopOrder = <String>[];

        coordinator.registerService(_TestService('a', onStopCallback: () {
          stopOrder.add('a');
        }));
        coordinator.registerService(_TestService('b', deps: ['a'], onStopCallback: () {
          stopOrder.add('b');
        }));
        coordinator.registerService(_TestService('c', onStopCallback: () {
          stopOrder.add('c');
        }));

        await coordinator.startAll();
        await coordinator.stopService('a');

        expect(stopOrder, equals(['b', 'a']));
        expect(coordinator.getService('c')!.state, ServiceLifecycleState.running);
      });
    });

    group('circular dependency detection', () {
      test('detects simple circular dependency', () async {
        // Use a separate coordinator for this test to avoid tearDown issues
        final testCoordinator = ServiceCoordinator();
        testCoordinator.registerService(_TestService('a', deps: ['b']));
        testCoordinator.registerService(_TestService('b', deps: ['a']));

        await expectLater(
          testCoordinator.startAll(),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Circular dependency'),
          )),
        );
        // Don't dispose - it would also throw
      });

      test('detects transitive circular dependency', () async {
        final testCoordinator = ServiceCoordinator();
        testCoordinator.registerService(_TestService('a', deps: ['b']));
        testCoordinator.registerService(_TestService('b', deps: ['c']));
        testCoordinator.registerService(_TestService('c', deps: ['a']));

        await expectLater(
          testCoordinator.startAll(),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Circular dependency'),
          )),
        );
      });

      test('detects self-dependency', () async {
        final testCoordinator = ServiceCoordinator();
        testCoordinator.registerService(_TestService('a', deps: ['a']));

        await expectLater(
          testCoordinator.startAll(),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Circular dependency'),
          )),
        );
      });
    });

    group('error handling', () {
      test('propagates start error', () async {
        coordinator.registerService(_TestService('a', shouldFailStart: true));

        await expectLater(
          coordinator.startService('a'),
          throwsA(isA<Exception>()),
        );

        expect(
          coordinator.getService('a')!.state,
          ServiceLifecycleState.error,
        );
      });

      test('does not start dependents when dependency fails', () async {
        var bStarted = false;

        coordinator.registerService(_TestService('a', shouldFailStart: true));
        coordinator.registerService(_TestService('b', deps: ['a'], onStartCallback: () {
          bStarted = true;
        }));

        await expectLater(
          coordinator.startAll(),
          throwsA(isA<Exception>()),
        );

        expect(bStarted, isFalse);
        expect(
          coordinator.getService('b')!.state,
          ServiceLifecycleState.uninitialized,
        );
      });

      test('continues shutdown on stop error', () async {
        final stopOrder = <String>[];

        coordinator.registerService(_TestService('a', onStopCallback: () {
          stopOrder.add('a');
        }));
        coordinator.registerService(_TestService('b', deps: ['a'], shouldFailStop: true, onStopCallback: () {
          stopOrder.add('b');
        }));
        coordinator.registerService(_TestService('c', deps: ['b'], onStopCallback: () {
          stopOrder.add('c');
        }));

        await coordinator.startAll();
        await coordinator.stopAll();

        // All services should be attempted to stop despite b failing
        expect(stopOrder, equals(['c', 'b', 'a']));
      });

      test('throws when dependency is unknown', () async {
        coordinator.registerService(_TestService('a', deps: ['unknown']));

        await expectLater(
          coordinator.startService('a'),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unknown service'),
          )),
        );
      });
    });

    group('restart', () {
      test('restart stops dependents and restarts full stack', () async {
        final events = <String>[];

        coordinator.registerService(_TestService(
          'a',
          onStartCallback: () => events.add('a:start'),
          onStopCallback: () => events.add('a:stop'),
        ));
        coordinator.registerService(_TestService(
          'b',
          deps: ['a'],
          onStartCallback: () => events.add('b:start'),
          onStopCallback: () => events.add('b:stop'),
        ));

        await coordinator.startAll();
        events.clear();

        await coordinator.restartService('a');

        expect(events, equals(['b:stop', 'a:stop', 'a:start', 'b:start']));
      });
    });

    group('status', () {
      test('getStatus returns all service states', () async {
        coordinator.registerService(_TestService('a'));
        coordinator.registerService(_TestService('b'));

        await coordinator.startService('a');

        final status = coordinator.getStatus();
        expect(status['a'], ServiceLifecycleState.running);
        expect(status['b'], ServiceLifecycleState.uninitialized);
      });

      test('getServicesInState filters correctly', () async {
        coordinator.registerService(_TestService('a'));
        coordinator.registerService(_TestService('b'));
        coordinator.registerService(_TestService('c'));

        await coordinator.startService('a');
        await coordinator.startService('b');

        final running = coordinator.getServicesInState(ServiceLifecycleState.running);
        expect(running.length, equals(2));
        expect(running.map((s) => s.serviceId), containsAll(['a', 'b']));
      });

      test('getDependencyGraph returns graph', () {
        coordinator.registerService(_TestService('a'));
        coordinator.registerService(_TestService('b', deps: ['a']));

        final graph = coordinator.getDependencyGraph();
        expect(graph['a'], isEmpty);
        expect(graph['b'], equals(['a']));
      });
    });

    group('MetaService', () {
      test('meta service groups dependencies', () async {
        final startOrder = <String>[];

        coordinator.registerService(_TestService('a', onStartCallback: () {
          startOrder.add('a');
        }));
        coordinator.registerService(_TestService('b', onStartCallback: () {
          startOrder.add('b');
        }));
        coordinator.registerService(MetaService(
          serviceId: 'stack',
          serviceName: 'Stack',
          dependencies: ['a', 'b'],
        ));

        await coordinator.startService('stack');

        expect(startOrder, containsAll(['a', 'b']));
        expect(coordinator.getService('stack')!.state, ServiceLifecycleState.running);
      });
    });
  });
}

class _TestService extends BaseManagedService {
  _TestService(
    String id, {
    List<String> deps = const [],
    this.onStartCallback,
    this.onStopCallback,
    this.shouldFailStart = false,
    this.shouldFailStop = false,
  })  : _deps = deps,
        super(id, 'Test $id');

  final List<String> _deps;
  final void Function()? onStartCallback;
  final void Function()? onStopCallback;
  final bool shouldFailStart;
  final bool shouldFailStop;

  @override
  List<String> get dependencies => _deps;

  @override
  Future<void> onStart() async {
    if (shouldFailStart) {
      throw Exception('Simulated start failure');
    }
    onStartCallback?.call();
  }

  @override
  Future<void> onStop() async {
    onStopCallback?.call();
    if (shouldFailStop) {
      throw Exception('Simulated stop failure');
    }
  }
}
