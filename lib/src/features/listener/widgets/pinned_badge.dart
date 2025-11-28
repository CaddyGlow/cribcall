import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../../util/format_utils.dart';

class PinnedBadge extends StatelessWidget {
  const PinnedBadge({super.key, this.fingerprint});

  final String? fingerprint;

  @override
  Widget build(BuildContext context) {
    final display = fingerprint == null
        ? 'Pinned certs'
        : 'This device ${shortFingerprint(fingerprint!)}';
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
