import 'package:flutter/material.dart';

import '../../../theme.dart';

class PinnedBadge extends StatelessWidget {
  const PinnedBadge({super.key, this.fingerprint});

  final String? fingerprint;

  @override
  Widget build(BuildContext context) {
    final display = fingerprint == null
        ? 'Pinned certs'
        : 'This device ${fingerprint!.substring(0, 12)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        display,
        style: const TextStyle(
          color: AppColors.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
