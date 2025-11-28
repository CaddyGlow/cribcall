import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../domain/models.dart';
import '../../pairing/qr_payload_parser.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../util/format_utils.dart';

class ListenerScanQrPage extends ConsumerStatefulWidget {
  const ListenerScanQrPage({super.key});

  @override
  ConsumerState<ListenerScanQrPage> createState() => _ListenerScanQrPageState();
}

class _ListenerScanQrPageState extends ConsumerState<ListenerScanQrPage> {
  MobileScannerController? _scannerController;
  final TextEditingController _manualInputController = TextEditingController();

  MonitorQrPayload? _payload;
  String? _payloadError;
  String? _scannerError;
  bool _scannerLocked = false;
  bool _startingScanner = false;
  bool _tokenPairingInProgress = false;
  bool _scannerReady = false;

  void _handleCapture(BarcodeCapture capture) {
    if (_scannerLocked) return;
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw == null) continue;
      final handled = _usePayloadString(raw, lockScanner: true);
      if (handled) return;
    }
  }

  bool _usePayloadString(String raw, {bool lockScanner = false}) {
    try {
      final payload = parseMonitorQrPayload(raw);
      setState(() {
        _payload = payload;
        _payloadError = null;
        if (lockScanner) _scannerLocked = true;
      });

      // Check if payload has a token for auto-pairing
      if (payload.hasToken) {
        _performTokenPairing(payload);
      } else {
        // Legacy flow - just add monitor (will need PIN pairing later)
        ref.read(trustedMonitorsProvider.notifier).addMonitor(payload);
      }
      return true;
    } catch (e) {
      setState(() {
        _payloadError = 'Invalid QR payload: $e';
      });
      return false;
    }
  }

  /// Perform token-based pairing (auto-pairing from QR code).
  Future<void> _performTokenPairing(MonitorQrPayload payload) async {
    final identity = ref.read(identityProvider).asData?.value;
    final appSession = ref.read(appSessionProvider).asData?.value;

    if (identity == null || appSession == null) {
      setState(() {
        _payloadError = 'Identity not ready. Please try again.';
        _scannerLocked = false;
      });
      return;
    }

    setState(() {
      _tokenPairingInProgress = true;
      _payloadError = null;
    });

    final error = await ref.read(pairingSessionProvider.notifier).pairWithToken(
      payload: payload,
      listenerIdentity: identity,
      listenerName: appSession.deviceName,
    );

    if (!mounted) return;

    if (error != null) {
      setState(() {
        _payloadError = error;
        _tokenPairingInProgress = false;
        _scannerLocked = false;
      });
    } else {
      // Success - navigate back with the payload
      if (mounted) {
        Navigator.of(context).pop(payload);
      }
    }
  }

  Future<void> _startScanner() async {
    setState(() {
      _startingScanner = true;
      _scannerError = null;
    });
    try {
      // Create controller only when starting - this defers plugin initialization
      // until we're ready to handle errors
      _scannerController = MobileScannerController(autoStart: false);
      await _scannerController!.start();
      if (mounted) {
        setState(() {
          _scannerReady = true;
        });
      }
    } on MissingPluginException {
      _scannerController?.dispose();
      _scannerController = null;
      setState(() {
        _scannerError =
            'Camera scanning is not available on this device. Paste the QR JSON instead.';
      });
    } on PlatformException catch (e) {
      _scannerController?.dispose();
      _scannerController = null;
      setState(() {
        _scannerError =
            'Camera unavailable (${e.code}): ${e.message ?? 'check permissions'}';
      });
    } catch (e) {
      _scannerController?.dispose();
      _scannerController = null;
      setState(() {
        _scannerError = 'Camera unavailable: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _startingScanner = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _startScanner();
  }

  @override
  void dispose() {
    _scannerController?.dispose();
    _manualInputController.dispose();
    super.dispose();
  }

  void _handleManualSubmit() {
    final raw = _manualInputController.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _payloadError = 'Paste a QR JSON payload first.';
      });
      return;
    }
    FocusScope.of(context).unfocus();
    _usePayloadString(raw, lockScanner: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan monitor QR')),
      body: Column(
        children: [
          Expanded(
            child: _scannerError != null
                ? _ScannerUnavailableMessage(
                    message: _scannerError!,
                    isLoading: _startingScanner,
                  )
                : _scannerReady && _scannerController != null
                    ? MobileScanner(
                        controller: _scannerController!,
                        fit: BoxFit.cover,
                        onDetect: _handleCapture,
                      )
                    : _ScannerUnavailableMessage(
                        message: 'Starting camera...',
                        isLoading: true,
                      ),
          ),
          if (_tokenPairingInProgress)
            _PairingProgressCard(
              title: _payload?.monitorName ?? 'Monitor',
              fingerprint: _payload?.certFingerprint ?? '',
            )
          else if (_payload != null)
            _ResultCard(
              title: _payload!.monitorName,
              fingerprint: _payload!.certFingerprint,
              remoteDeviceId: _payload!.remoteDeviceId,
              ips: _payload!.ips,
              hasToken: _payload!.hasToken,
              onUse: () => Navigator.of(context).pop(_payload),
            )
          else if (_payloadError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _payloadError!,
                style: const TextStyle(color: Colors.red),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Point the camera at a CribCall monitor QR.'),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No camera? Paste the QR JSON payload.',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _manualInputController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: '{"type":"monitor_pair_v1", ...}',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _handleManualSubmit(),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          setState(() {
                            _manualInputController.clear();
                            _payloadError = null;
                          });
                        },
                        child: const Text('Clear input'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _handleManualSubmit,
                        icon: const Icon(Icons.check),
                        label: const Text('Use QR payload'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.title,
    required this.fingerprint,
    required this.remoteDeviceId,
    required this.onUse,
    this.ips,
    this.hasToken = false,
  });

  final String title;
  final String fingerprint;
  final String remoteDeviceId;
  final List<String>? ips;
  final bool hasToken;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              if (hasToken)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Paired',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppColors.success,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text('Monitor ID: $remoteDeviceId'),
          Text('Fingerprint: ${shortFingerprint(fingerprint)}'),
          if (ips != null && ips!.isNotEmpty)
            Text('IPs: ${ips!.join(', ')}'),
          const SizedBox(height: 10),
          FilledButton(onPressed: onUse, child: const Text('Use this monitor')),
        ],
      ),
    );
  }
}

class _PairingProgressCard extends StatelessWidget {
  const _PairingProgressCard({
    required this.title,
    required this.fingerprint,
  });

  final String title;
  final String fingerprint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          if (fingerprint.isNotEmpty)
            Text('Fingerprint: ${shortFingerprint(fingerprint)}'),
          const SizedBox(height: 16),
          Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text(
                'Pairing with monitor...',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScannerUnavailableMessage extends StatelessWidget {
  const _ScannerUnavailableMessage({
    required this.message,
    required this.isLoading,
  });

  final String message;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.04),
      padding: const EdgeInsets.all(24),
      width: double.infinity,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.videocam_off, size: 48, color: AppColors.muted),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (isLoading) const SizedBox(height: 8),
          if (isLoading) const CircularProgressIndicator(),
        ],
      ),
    );
  }
}
