import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';

class ListenerPinPage extends ConsumerStatefulWidget {
  const ListenerPinPage({super.key, required this.advertisement});

  final MdnsAdvertisement advertisement;

  @override
  ConsumerState<ListenerPinPage> createState() => _ListenerPinPageState();
}

class _ListenerPinPageState extends ConsumerState<ListenerPinPage> {
  final _pinController = TextEditingController();
  String? _status;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityProvider);
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
            '${widget.advertisement.monitorName} • ${_shortFingerprint(widget.advertisement.monitorCertFingerprint)}',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pinController,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(
              labelText: 'Enter 6-digit PIN from monitor',
              counterText: '',
            ),
          ),
          if (_status != null) ...[
            const SizedBox(height: 6),
            Text(
              _status!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.red),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () async {
                    if (_pinController.text.length != 6) {
                      setState(() {
                        _status = 'PIN must be 6 digits';
                      });
                      return;
                    }
                    if (!identity.hasValue) {
                      setState(() {
                        _status = 'Identity still loading';
                      });
                      return;
                    }
                    try {
                      final result = await ref
                          .read(pinSessionProvider.notifier)
                          .submitPin(
                            pairingSessionId:
                                ref.read(pinSessionProvider)?.sessionId ??
                                widget.advertisement.monitorId,
                            pin: _pinController.text,
                            advertisement: widget.advertisement,
                            listenerIdentity: identity.requireValue,
                            listenerName: 'Listener',
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
                    } catch (_) {
                      setState(() {
                        _status = 'PIN pairing failed. Try again in a moment.';
                      });
                    }
                  },
                  child: const Text('Submit PIN'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _shortFingerprint(String fingerprint) {
    if (fingerprint.length <= 12) return fingerprint;
    return fingerprint.substring(0, 12);
  }
}
