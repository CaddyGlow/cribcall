import 'package:flutter/material.dart';

import '../../../theme.dart';

/// A styled box displaying a pairing comparison code.
///
/// Used by both monitor and listener during pairing to show the
/// verification code that users must compare.
class CcPairingCodeBox extends StatelessWidget {
  const CcPairingCodeBox({
    super.key,
    required this.comparisonCode,
    required this.remainingSeconds,
    this.helperText = 'Verify this code matches',
  });

  final String comparisonCode;
  final int remainingSeconds;
  final String helperText;

  @override
  Widget build(BuildContext context) {
    final isExpiringSoon = remainingSeconds <= 10;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: 24,
        vertical: 20,
      ),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        children: [
          Text(
            helperText,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                ),
          ),
          const SizedBox(height: 12),
          Text(
            comparisonCode,
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  letterSpacing: 8,
                  fontWeight: FontWeight.w900,
                  fontFamily: 'monospace',
                  color: AppColors.textPrimary,
                ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.timer_outlined,
                size: 16,
                color: isExpiringSoon ? AppColors.warning : AppColors.muted,
              ),
              const SizedBox(width: 4),
              Text(
                'Expires in ${remainingSeconds}s',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isExpiringSoon ? AppColors.warning : AppColors.muted,
                      fontWeight: isExpiringSoon ? FontWeight.w600 : FontWeight.normal,
                    ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
