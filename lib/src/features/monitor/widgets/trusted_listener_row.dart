import 'package:flutter/material.dart';

import '../../../theme.dart';

/// A row displaying a trusted listener's information with a revoke button.
class TrustedListenerRow extends StatelessWidget {
  const TrustedListenerRow({
    super.key,
    required this.name,
    required this.fingerprint,
    this.onRevoke,
  });

  final String name;
  final String fingerprint;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          const Icon(Icons.verified_user, size: 18, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            fingerprint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.muted,
            ),
          ),
          if (onRevoke != null) ...[
            const SizedBox(width: 8),
            TextButton(onPressed: onRevoke, child: const Text('Revoke')),
          ],
        ],
      ),
    );
  }
}
