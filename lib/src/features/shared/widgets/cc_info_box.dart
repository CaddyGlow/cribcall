import 'package:flutter/material.dart';

import '../../../theme.dart';

/// An info/hint box with icon and text.
///
/// Used to display helpful information or tips in settings screens.
class CcInfoBox extends StatelessWidget {
  const CcInfoBox({
    super.key,
    required this.text,
    this.icon = Icons.info_outline,
    this.color,
  });

  /// Warning variant with amber color.
  const CcInfoBox.warning({
    super.key,
    required this.text,
    this.icon = Icons.warning_amber_rounded,
  }) : color = AppColors.warning;

  final String text;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? AppColors.primary;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: effectiveColor.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: effectiveColor.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
