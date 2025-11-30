import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../control/control_service.dart';
import '../../../state/app_state.dart';
import '../../../theme.dart';
import '../../shared/widgets/cc_pairing_code_box.dart';

/// Shows a modal bottom sheet for pairing confirmation.
///
/// The drawer displays the comparison code and allows the user to
/// accept or reject the pairing request.
void showPairingConfirmationDrawer(
  BuildContext context,
  WidgetRef ref, {
  VoidCallback? onDismissed,
}) {
  final session = ref.read(pairingServerProvider).activeSession;
  if (session == null) return;

  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (context) => _PairingConfirmationSheet(
      session: session,
      onDismissed: onDismissed,
    ),
  );
}

class _PairingConfirmationSheet extends ConsumerStatefulWidget {
  const _PairingConfirmationSheet({
    required this.session,
    this.onDismissed,
  });

  final ActivePairingSession session;
  final VoidCallback? onDismissed;

  @override
  ConsumerState<_PairingConfirmationSheet> createState() =>
      _PairingConfirmationSheetState();
}

class _PairingConfirmationSheetState
    extends ConsumerState<_PairingConfirmationSheet> {
  Timer? _countdownTimer;
  int _remainingSeconds = 0;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _updateRemaining();
    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateRemaining(),
    );
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _updateRemaining() {
    final remaining =
        widget.session.expiresAt.difference(DateTime.now()).inSeconds;
    if (remaining <= 0) {
      // Session expired - close the drawer
      _countdownTimer?.cancel();
      if (mounted) {
        Navigator.of(context).pop();
        widget.onDismissed?.call();
      }
      return;
    }
    if (mounted) {
      setState(() {
        _remainingSeconds = remaining;
      });
    }
  }

  Future<void> _handleAccept() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    final success = ref
        .read(pairingServerProvider.notifier)
        .confirmSession(widget.session.sessionId);

    if (mounted) {
      Navigator.of(context).pop();
      widget.onDismissed?.call();

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Pairing accepted. Waiting for confirmation...'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _handleReject() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    ref
        .read(pairingServerProvider.notifier)
        .rejectSession(widget.session.sessionId);

    if (mounted) {
      Navigator.of(context).pop();
      widget.onDismissed?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch for session changes (e.g., if session is cleared externally)
    final currentSession = ref.watch(
      pairingServerProvider.select((s) => s.activeSession),
    );

    // If session was cleared (completed or expired), close the drawer
    if (currentSession == null ||
        currentSession.sessionId != widget.session.sessionId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).pop();
          widget.onDismissed?.call();
        }
      });
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.45,
      minChildSize: 0.35,
      maxChildSize: 0.6,
      expand: false,
      builder: (context, scrollController) {
        return SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Header icon
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.phonelink_lock,
                  color: AppColors.primary,
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),

              // Title
              Text(
                'Pairing Request',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 8),

              // Listener name
              Text(
                '${widget.session.listenerName} wants to pair',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.muted,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // Comparison code container
              CcPairingCodeBox(
                comparisonCode: widget.session.comparisonCode,
                remainingSeconds: _remainingSeconds,
              ),
              const SizedBox(height: 12),

              // Session ID
              Text(
                'Session ${widget.session.sessionId.substring(0, 8)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted.withValues(alpha: 0.7),
                      fontFamily: 'monospace',
                    ),
              ),
              const SizedBox(height: 24),

              // Action buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isProcessing ? null : _handleReject,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Deny'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _isProcessing ? null : _handleAccept,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: _isProcessing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Accept'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
