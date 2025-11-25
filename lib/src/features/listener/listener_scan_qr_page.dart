import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../domain/models.dart';
import '../../pairing/qr_payload_parser.dart';
import '../../state/app_state.dart';
import '../../theme.dart';

class ListenerScanQrPage extends ConsumerStatefulWidget {
  const ListenerScanQrPage({super.key});

  @override
  ConsumerState<ListenerScanQrPage> createState() => _ListenerScanQrPageState();
}

class _ListenerScanQrPageState extends ConsumerState<ListenerScanQrPage> {
  final MobileScannerController _scannerController = MobileScannerController(
    autoStart: false,
  );
  final TextEditingController _manualInputController = TextEditingController();

  MonitorQrPayload? _payload;
  String? _payloadError;
  String? _scannerError;
  bool _scannerLocked = false;
  bool _startingScanner = false;

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
      ref.read(trustedMonitorsProvider.notifier).addMonitor(payload);
      return true;
    } catch (e) {
      setState(() {
        _payloadError = 'Invalid QR payload: $e';
      });
      return false;
    }
  }

  Future<void> _startScanner() async {
    setState(() {
      _startingScanner = true;
      _scannerError = null;
    });
    try {
      await _scannerController.start();
    } on MissingPluginException {
      setState(() {
        _scannerError =
            'Camera scanning is not available on this device. Paste the QR JSON instead.';
      });
    } on PlatformException catch (e) {
      setState(() {
        _scannerError =
            'Camera unavailable (${e.code}): ${e.message ?? 'check permissions'}';
      });
    } catch (e) {
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
    _scannerController.dispose();
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
                : MobileScanner(
                    controller: _scannerController,
                    fit: BoxFit.cover,
                    onDetect: _handleCapture,
                  ),
          ),
          if (_payload != null)
            _ResultCard(
              title: _payload!.monitorName,
              fingerprint: _payload!.monitorCertFingerprint,
              monitorId: _payload!.monitorId,
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
    required this.monitorId,
    required this.onUse,
  });

  final String title;
  final String fingerprint;
  final String monitorId;
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
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text('Monitor ID: $monitorId'),
          Text('Fingerprint: ${fingerprint.substring(0, 12)}'),
          const SizedBox(height: 10),
          FilledButton(onPressed: onUse, child: const Text('Use this monitor')),
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
