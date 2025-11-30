import 'package:flutter/material.dart';

import '../../../theme.dart';

/// A slider with label, current value display, and helper text.
///
/// Supports two modes:
/// - Simple mode: Just shows the value and allows changing it
/// - Override mode: Shows base value, current override, and allows clearing
class CcSettingsSlider extends StatelessWidget {
  /// Simple mode constructor - just value and onChanged.
  const CcSettingsSlider({
    super.key,
    required this.label,
    this.helper,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.displayValue,
    required this.onChanged,
  })  : baseValue = null,
        baseDisplayValue = null,
        hasOverride = false,
        onClear = null;

  /// Override mode constructor - shows base value and allows clearing override.
  const CcSettingsSlider.withOverride({
    super.key,
    required this.label,
    this.helper,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.displayValue,
    required this.onChanged,
    required double this.baseValue,
    required String this.baseDisplayValue,
    required this.hasOverride,
    required VoidCallback this.onClear,
  });

  final String label;
  final String? helper;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String displayValue;
  final ValueChanged<double> onChanged;

  // Override mode fields
  final double? baseValue;
  final String? baseDisplayValue;
  final bool hasOverride;
  final VoidCallback? onClear;

  bool get _isOverrideMode => baseValue != null;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayValue,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: _isOverrideMode && hasOverride
                        ? AppColors.primary
                        : AppColors.muted,
                    fontWeight: _isOverrideMode && hasOverride
                        ? FontWeight.w700
                        : null,
                  ),
                ),
                if (_isOverrideMode && hasOverride) ...[
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: onClear,
                    child: const Icon(
                      Icons.close,
                      size: 16,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
        if (_isOverrideMode)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              hasOverride
                  ? 'Override (default: $baseDisplayValue)'
                  : 'Using monitor default',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
              ),
            ),
          ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: displayValue,
          onChanged: onChanged,
        ),
        if (helper != null)
          Text(
            helper!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.muted,
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}
