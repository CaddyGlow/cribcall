import 'package:flutter/material.dart';

import '../../../control/control_service.dart';
import '../../../theme.dart';

/// A banner displaying an active pairing session with comparison code
/// and Accept/Reject buttons for the monitor user.
class PairingSessionBanner extends StatelessWidget {
  const PairingSessionBanner({
    super.key,
    required this.session,
    required this.onAccept,
    required this.onReject,
  });

  final ActivePairingSession session;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final remaining = session.expiresAt.difference(DateTime.now()).inSeconds;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pairing Request',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Verify this code matches the listener device:',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                session.comparisonCode,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  letterSpacing: 4,
                  fontWeight: FontWeight.w900,
                  fontFamily: 'monospace',
                ),
              ),
              Text(
                'Expires in ${remaining.clamp(0, 60)}s',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Session ${session.sessionId.substring(0, 8)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: onAccept,
                  child: const Text('Accept'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: onReject,
                  child: const Text('Reject'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
