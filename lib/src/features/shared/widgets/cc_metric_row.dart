import 'package:flutter/material.dart';

import '../../../theme.dart';

/// A two-column label-value display row.
///
/// The label is displayed in muted color with a fixed width,
/// and the value is displayed in bold primary color.
class CcMetricRow extends StatelessWidget {
  const CcMetricRow({
    super.key,
    required this.label,
    this.value,
    this.valueWidget,
    this.labelWidth = 140,
  }) : assert(value != null || valueWidget != null);

  final String label;
  final String? value;
  final Widget? valueWidget;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.muted,
              ),
            ),
          ),
          Expanded(
            child: valueWidget ??
                Text(
                  value!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
          ),
        ],
      ),
    );
  }
}
