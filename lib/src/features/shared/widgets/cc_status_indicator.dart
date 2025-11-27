import 'package:flutter/material.dart';

import '../../../theme.dart';

/// Status types for the indicator.
enum CcStatusType {
  online,
  offline,
  connecting,
  error,
}

/// A colored dot indicator with optional label showing connection status.
class CcStatusIndicator extends StatelessWidget {
  const CcStatusIndicator({
    super.key,
    required this.status,
    this.label,
    this.showLabel = true,
    this.size = 10,
  });

  final CcStatusType status;
  final String? label;
  final bool showLabel;
  final double size;

  Color get _color {
    switch (status) {
      case CcStatusType.online:
        return AppColors.success;
      case CcStatusType.offline:
        return AppColors.muted;
      case CcStatusType.connecting:
        return AppColors.warning;
      case CcStatusType.error:
        return Colors.red;
    }
  }

  String get _defaultLabel {
    switch (status) {
      case CcStatusType.online:
        return 'Online';
      case CcStatusType.offline:
        return 'Offline';
      case CcStatusType.connecting:
        return 'Connecting';
      case CcStatusType.error:
        return 'Error';
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveLabel = label ?? _defaultLabel;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: _color,
            shape: BoxShape.circle,
          ),
        ),
        if (showLabel) ...[
          const SizedBox(width: 6),
          Text(
            effectiveLabel,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}
