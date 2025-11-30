import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../pairing/pin_pairing_controller.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../util/format_utils.dart';
import '../shared/widgets/cc_pairing_code_box.dart';

void _logPairingPage(String message) {
  developer.log(message, name: 'listener_pairing_page');
  debugPrint('[listener_pairing_page] $message');
}

/// Page for numeric comparison pairing with a monitor.
///
/// Flow:
/// 1. Initiates pairing with monitor -> receives comparison code
/// 2. Displays comparison code for user to verify
/// 3. User confirms codes match -> completes pairing
class ListenerPinPage extends ConsumerStatefulWidget {
  const ListenerPinPage({super.key, required this.advertisement});

  final MdnsAdvertisement advertisement;

  @override
  ConsumerState<ListenerPinPage> createState() => _ListenerPinPageState();
}

class _ListenerPinPageState extends ConsumerState<ListenerPinPage> {
  String? _status;
  bool _connecting = false;
  bool _confirming = false;
  // Save notifier reference for safe disposal (ref.read is unsafe in dispose)
  PairingController? _pairingNotifier;

  @override
  void initState() {
    super.initState();
    _pairingNotifier = ref.read(pairingSessionProvider.notifier);
    _logPairingPage(
      'Pairing page opened for remoteDeviceId=${widget.advertisement.remoteDeviceId} '
      'name=${widget.advertisement.monitorName} '
      'ip=${widget.advertisement.ip ?? 'unknown'} '
      'fingerprint=${shortFingerprint(widget.advertisement.certFingerprint)}',
    );
    _initiatePairing();
  }

  Future<void> _initiatePairing() async {
    final identity = ref.read(identityProvider);
    if (!identity.hasValue) {
      _logPairingPage('Waiting for identity to load before initiating pairing');
      setState(() {
        _status = 'Loading identity...';
      });
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final identityRetry = ref.read(identityProvider);
      if (!identityRetry.hasValue) {
        setState(() {
          _status = 'Identity not available';
        });
        return;
      }
    }

    setState(() {
      _connecting = true;
      _status = 'Connecting to monitor...';
    });

    _logPairingPage('Initiating pairing protocol...');
    final result = await ref
        .read(pairingSessionProvider.notifier)
        .initiatePairing(
          advertisement: widget.advertisement,
          listenerIdentity: ref.read(identityProvider).requireValue,
          listenerName: 'Listener',
        );

    if (!mounted) return;

    if (result.error != null) {
      _logPairingPage('Pairing initiation failed: ${result.error}');
      setState(() {
        _connecting = false;
        _status = result.error;
      });
    } else {
      _logPairingPage('Pairing initiated - comparison code: ${result.comparisonCode}');
      setState(() {
        _connecting = false;
        _status = null;
      });
    }
  }

  Future<void> _confirmPairing() async {
    final identity = ref.read(identityProvider);
    if (!identity.hasValue) {
      setState(() {
        _status = 'Identity not available';
      });
      return;
    }

    setState(() {
      _confirming = true;
      _status = 'Waiting for monitor to accept...';
    });

    _logPairingPage('Confirming pairing...');

    // confirmPairing uses confirmPairingWithPolling internally, which polls
    // for up to 60 seconds waiting for monitor acceptance
    final error = await ref
        .read(pairingSessionProvider.notifier)
        .confirmPairing(listenerIdentity: identity.requireValue);

    if (!mounted) return;

    if (error == null) {
      // Success
      _logPairingPage('Pairing confirmed successfully');
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pairing successful')),
      );
      return;
    }

    // Failed
    _logPairingPage('Pairing confirmation failed: $error');
    setState(() {
      _confirming = false;
      _status = error;
    });
  }

  void _cancelPairing() {
    ref.read(pairingSessionProvider.notifier).cancelPairing();
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _logPairingPage('Pairing page disposed');
    _pairingNotifier?.closeConnection();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(pairingSessionProvider);
    final hasSession = session != null;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Pair with Monitor',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            '${widget.advertisement.monitorName} - ${shortFingerprint(widget.advertisement.certFingerprint)}',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.muted),
          ),
          const SizedBox(height: 16),
          if (_connecting) ...[
            const Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text('Connecting to monitor...'),
              ],
            ),
            const SizedBox(height: 12),
          ] else if (hasSession) ...[
            CcPairingCodeBox(
              comparisonCode: session.comparisonCode,
              remainingSeconds:
                  session.expiresAt.difference(DateTime.now()).inSeconds,
              helperText: 'Verify this code matches the monitor',
            ),
            const SizedBox(height: 16),
            if (_confirming)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 12),
                      Text('Waiting for monitor to accept...'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Please tap "Accept" on the monitor device',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                    ),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _confirmPairing,
                      child: const Text('Codes Match'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _cancelPairing,
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
          ],
          if (_status != null && !_connecting && !_confirming) ...[
            const SizedBox(height: 8),
            Text(
              _status!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.red),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _initiatePairing,
              child: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }
}
