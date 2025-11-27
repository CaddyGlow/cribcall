import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/app_state.dart';
import '../../../theme.dart';

/// Shows the count of active listeners currently connected to the monitor.
///
/// Displays a visual indicator with the number of connected listeners.
/// When count is > 0, shows a pulsing animation to indicate active connections.
class ListeningIndicator extends ConsumerWidget {
  const ListeningIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controlState = ref.watch(controlServerProvider);
    final count = controlState.activeConnectionsCount;
    final isActive = count > 0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isActive
            ? AppColors.success.withValues(alpha: 0.12)
            : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive
              ? AppColors.success.withValues(alpha: 0.3)
              : Colors.grey.shade300,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PulsingDot(isActive: isActive),
          const SizedBox(width: 8),
          Text(
            count == 0
                ? 'No listeners'
                : count == 1
                    ? '1 listener connected'
                    : '$count listeners connected',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: isActive ? AppColors.success : AppColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A dot that pulses when active to indicate live connections.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.isActive});

  final bool isActive;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _animation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    if (widget.isActive) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_PulsingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _controller.repeat(reverse: true);
    } else if (!widget.isActive && oldWidget.isActive) {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: widget.isActive
                ? AppColors.success.withValues(alpha: _animation.value)
                : AppColors.muted.withValues(alpha: 0.5),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}
