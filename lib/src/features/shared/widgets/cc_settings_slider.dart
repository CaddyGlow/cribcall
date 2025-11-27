import 'package:flutter/material.dart';

import '../../../theme.dart';

/// A slider with label, current value display, and helper text.
class CcSettingsSlider extends StatelessWidget {
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
  });

  final String label;
  final String? helper;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String displayValue;
  final ValueChanged<double> onChanged;

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
            Text(
              displayValue,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
              ),
            ),
          ],
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
