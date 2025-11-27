import 'package:flutter/material.dart';

import '../../../theme.dart';

/// Badge style variants.
enum CcBadgeVariant {
  /// Semi-transparent background (12% alpha).
  subtle,

  /// Outlined border, transparent background.
  outlined,

  /// Solid background color.
  filled,
}

/// Badge size variants.
enum CcBadgeSize {
  small,
  medium,
  large,
}

/// A status badge with configurable color, variant, and size.
class CcBadge extends StatelessWidget {
  const CcBadge({
    super.key,
    required this.label,
    this.color,
    this.variant = CcBadgeVariant.subtle,
    this.size = CcBadgeSize.medium,
    this.icon,
  });

  final String label;
  final Color? color;
  final CcBadgeVariant variant;
  final CcBadgeSize size;
  final IconData? icon;

  /// Creates a success badge (green).
  factory CcBadge.success(String label, {CcBadgeSize size = CcBadgeSize.medium}) {
    return CcBadge(label: label, color: AppColors.success, size: size);
  }

  /// Creates a warning badge (orange).
  factory CcBadge.warning(String label, {CcBadgeSize size = CcBadgeSize.medium}) {
    return CcBadge(label: label, color: AppColors.warning, size: size);
  }

  /// Creates a primary badge (blue).
  factory CcBadge.primary(String label, {CcBadgeSize size = CcBadgeSize.medium}) {
    return CcBadge(label: label, color: AppColors.primary, size: size);
  }

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? AppColors.primary;

    final EdgeInsets padding;
    final double fontSize;
    final double iconSize;

    switch (size) {
      case CcBadgeSize.small:
        padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 2);
        fontSize = 10;
        iconSize = 10;
      case CcBadgeSize.medium:
        padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 6);
        fontSize = 12;
        iconSize = 14;
      case CcBadgeSize.large:
        padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8);
        fontSize = 14;
        iconSize = 16;
    }

    final Color backgroundColor;
    final Color textColor;
    final BoxBorder? border;

    switch (variant) {
      case CcBadgeVariant.subtle:
        backgroundColor = effectiveColor.withValues(alpha: 0.12);
        textColor = effectiveColor;
        border = null;
      case CcBadgeVariant.outlined:
        backgroundColor = Colors.transparent;
        textColor = effectiveColor;
        border = Border.all(color: effectiveColor);
      case CcBadgeVariant.filled:
        backgroundColor = effectiveColor;
        textColor = Colors.white;
        border = null;
    }

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: border,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: iconSize, color: textColor),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.w700,
              fontSize: fontSize,
            ),
          ),
        ],
      ),
    );
  }
}
