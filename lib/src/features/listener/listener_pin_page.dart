import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';

void _logPinPage(String message) {
  developer.log(message, name: 'listener_pin_page');
  debugPrint('[listener_pin_page] $message');
}

class ListenerPinPage extends ConsumerStatefulWidget {
  const ListenerPinPage({super.key, required this.advertisement});

  final MdnsAdvertisement advertisement;

  @override
  ConsumerState<ListenerPinPage> createState() => _ListenerPinPageState();
}

class _ListenerPinPageState extends ConsumerState<ListenerPinPage> {
  final _pinController = TextEditingController();
  String? _status;
  bool _connecting = false;
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    _logPinPage(
      'PIN page opened for monitor=${widget.advertisement.monitorId} '
      'name=${widget.advertisement.monitorName} '
      'ip=${widget.advertisement.ip ?? 'unknown'} '
      'fingerprint=${_shortFingerprint(widget.advertisement.monitorCertFingerprint)}',
    );
    // Initiate PIN pairing protocol
    _initiatePairing();
  }

  Future<void> _initiatePairing() async {
    final identity = ref.read(identityProvider);
    if (!identity.hasValue) {
      _logPinPage('Waiting for identity to load before initiating pairing');
      setState(() {
        _status = 'Loading identity...';
      });
      // Wait a bit and retry
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

    _logPinPage('Initiating PIN pairing protocol...');
    final error = await ref
        .read(pinSessionProvider.notifier)
        .initiatePinPairing(
          advertisement: widget.advertisement,
          listenerIdentity: ref.read(identityProvider).requireValue,
          listenerName: 'Listener',
        );

    if (!mounted) return;

    if (error != null) {
      _logPinPage('PIN pairing initiation failed: $error');
      setState(() {
        _connecting = false;
        _status = error;
      });
    } else {
      _logPinPage('PIN pairing initiated successfully - session hydrated');
      setState(() {
        _connecting = false;
        _connected = true;
        _status = null;
      });
    }
  }

  @override
  void dispose() {
    _logPinPage('PIN page disposed');
    // Close the connection when the page is closed
    ref.read(pinSessionProvider.notifier).closeConnection();
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityProvider);
    final session = ref.watch(pinSessionProvider);
    final canSubmit = _connected && !_connecting && session != null;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Pair with PIN',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            '${widget.advertisement.monitorName} - ${_shortFingerprint(widget.advertisement.monitorCertFingerprint)}',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
          ),
          const SizedBox(height: 12),
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
          ],
          TextField(
            controller: _pinController,
            keyboardType: TextInputType.number,
            maxLength: 6,
            enabled: canSubmit,
            decoration: InputDecoration(
              labelText: canSubmit
                  ? 'Enter 6-digit PIN from monitor'
                  : 'Waiting for connection...',
              counterText: '',
            ),
          ),
          if (_status != null) ...[
            const SizedBox(height: 6),
            Text(
              _status!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(
                    color: _connecting ? AppColors.muted : Colors.red,
                  ),
            ),
          ],
          if (session != null) ...[
            const SizedBox(height: 6),
            Text(
              'Session ready (expires in ${session.expiresAt.difference(DateTime.now()).inSeconds}s)',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.success),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: canSubmit ? _submitPin : null,
                  child: const Text('Submit PIN'),
                ),
              ),
              if (!_connected && !_connecting) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _initiatePairing,
                  child: const Text('Retry'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _submitPin() async {
    final identity = ref.read(identityProvider);
    _logPinPage('Submit PIN button pressed');
    if (_pinController.text.length != 6) {
      _logPinPage('PIN validation failed: length=${_pinController.text.length}');
      setState(() {
        _status = 'PIN must be 6 digits';
      });
      return;
    }
    if (!identity.hasValue) {
      _logPinPage('Identity not ready');
      setState(() {
        _status = 'Identity still loading';
      });
      return;
    }
    // Log session state before submit
    final currentSession = ref.read(pinSessionProvider);
    final sessionId = currentSession?.sessionId ?? widget.advertisement.monitorId;
    _logPinPage(
      'Attempting submitPin:\n'
      '  sessionFromProvider=${currentSession?.sessionId ?? 'NULL'}\n'
      '  fallbackToMonitorId=${currentSession == null}\n'
      '  effectiveSessionId=$sessionId\n'
      '  monitorId=${widget.advertisement.monitorId}',
    );
    try {
      final result = await ref
          .read(pinSessionProvider.notifier)
          .submitPin(
            pairingSessionId: sessionId,
            pin: _pinController.text,
            advertisement: widget.advertisement,
            listenerIdentity: identity.requireValue,
            listenerName: 'Listener',
          );
      _logPinPage(
        'submitPin result: success=${result.success} message=${result.message}',
      );
      if (result.success) {
        if (!mounted) return;
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PIN pairing accepted'),
          ),
        );
      } else {
        setState(() {
          _status = 'Pairing failed: ${result.message}';
        });
      }
    } catch (e, stack) {
      _logPinPage('submitPin exception: $e\n$stack');
      setState(() {
        _status = 'PIN pairing failed. Try again in a moment.';
      });
    }
  }

  String _shortFingerprint(String fingerprint) {
    if (fingerprint.length <= 12) return fingerprint;
    return fingerprint.substring(0, 12);
  }
}
