import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../domain/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';

class ListenerScanQrPage extends ConsumerStatefulWidget {
  const ListenerScanQrPage({super.key});

  @override
  ConsumerState<ListenerScanQrPage> createState() => _ListenerScanQrPageState();
}

class _ListenerScanQrPageState extends ConsumerState<ListenerScanQrPage> {
  MonitorQrPayload? _payload;
  String? _error;
  bool _handled = false;

  void _handleCapture(BarcodeCapture capture) {
    if (_handled) return;
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw == null) continue;
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final payload = MonitorQrPayload.fromJson(decoded);
        setState(() {
          _payload = payload;
          _handled = true;
        });
        ref.read(trustedMonitorsProvider.notifier).addMonitor(payload);
        return;
      } catch (e) {
        setState(() {
          _error = 'Invalid QR payload: $e';
          _handled = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan monitor QR')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(fit: BoxFit.cover, onDetect: _handleCapture),
          ),
          if (_payload != null)
            _ResultCard(
              title: _payload!.monitorName,
              fingerprint: _payload!.monitorCertFingerprint,
              monitorId: _payload!.monitorId,
              onUse: () => Navigator.of(context).pop(_payload),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            )
          else
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Point the camera at a CribCall monitor QR.'),
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
