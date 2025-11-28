import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/models.dart';
import '../features/landing/role_selection_page.dart';
import '../state/app_state.dart';

/// Route paths used throughout the app.
abstract final class AppRoutes {
  static const monitor = '/monitor';
  static const monitorPairing = '/monitor/pairing';
  static const listener = '/listener';
}

/// Global key for accessing the navigator from outside the widget tree.
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Provider for the GoRouter instance.
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: AppRoutes.monitor,
    debugLogDiagnostics: true,
    routes: [
      // Shell route wrapping both tabs
      ShellRoute(
        builder: (context, state, child) {
          // Determine initial tab and whether to show pairing drawer
          final showPairingDrawer =
              state.uri.path == AppRoutes.monitorPairing;
          final initialIndex =
              state.uri.path.startsWith(AppRoutes.monitor) ? 0 : 1;

          return RoleSelectionShell(
            initialIndex: initialIndex,
            showPairingDrawer: showPairingDrawer,
            child: child,
          );
        },
        routes: [
          GoRoute(
            path: AppRoutes.monitor,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: _MonitorPlaceholder(),
            ),
          ),
          GoRoute(
            path: AppRoutes.monitorPairing,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: _MonitorPlaceholder(),
            ),
          ),
          GoRoute(
            path: AppRoutes.listener,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: _ListenerPlaceholder(),
            ),
          ),
        ],
      ),
    ],
    redirect: (context, state) {
      // Redirect root to monitor
      if (state.uri.path == '/') {
        return AppRoutes.monitor;
      }
      return null;
    },
  );
});

/// Shell widget that provides the tab navigation structure.
/// The actual content is rendered by [RoleSelectionPage] based on the route.
class RoleSelectionShell extends ConsumerStatefulWidget {
  const RoleSelectionShell({
    super.key,
    required this.initialIndex,
    required this.showPairingDrawer,
    required this.child,
  });

  final int initialIndex;
  final bool showPairingDrawer;
  final Widget child;

  @override
  ConsumerState<RoleSelectionShell> createState() => _RoleSelectionShellState();
}

class _RoleSelectionShellState extends ConsumerState<RoleSelectionShell> {
  late int _selectedIndex;
  bool _sessionRestored = false;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex;
    _restoreSession();
  }

  @override
  void didUpdateWidget(RoleSelectionShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Update tab when route changes externally (e.g., from notification)
    if (widget.initialIndex != oldWidget.initialIndex) {
      setState(() {
        _selectedIndex = widget.initialIndex;
      });
    }
  }

  Future<void> _restoreSession() async {
    final session = await ref.read(appSessionProvider.future);

    if (!mounted) return;

    setState(() {
      // Only restore from session if we weren't navigated here explicitly
      if (widget.initialIndex == 0 && session.lastRole == DeviceRole.listener) {
        _selectedIndex = 1;
      }
      _sessionRestored = true;
    });

    // Restore monitoring status
    ref
        .read(monitoringStatusProvider.notifier)
        .restoreFromSession(session.monitoringEnabled);

    // Restore role
    if (session.lastRole != null) {
      ref.read(roleProvider.notifier).restoreFromSession(session.lastRole);
    }
  }

  void _onTabSelected(int index) {
    setState(() {
      _selectedIndex = index;
    });
    // Navigate to the appropriate route
    final path = index == 0 ? AppRoutes.monitor : AppRoutes.listener;
    context.go(path);
  }

  @override
  Widget build(BuildContext context) {
    // Keep roleProvider in sync
    final currentRole =
        _selectedIndex == 0 ? DeviceRole.monitor : DeviceRole.listener;

    if (_sessionRestored) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final role = ref.read(roleProvider);
        if (role != currentRole) {
          ref.read(roleProvider.notifier).select(currentRole);
        }
      });
    }

    return RoleSelectionPage(
      selectedIndex: _selectedIndex,
      onTabSelected: _onTabSelected,
      showPairingDrawer: widget.showPairingDrawer,
    );
  }
}

/// Placeholder widgets - the actual content is rendered by RoleSelectionPage
class _MonitorPlaceholder extends StatelessWidget {
  const _MonitorPlaceholder();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _ListenerPlaceholder extends StatelessWidget {
  const _ListenerPlaceholder();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
