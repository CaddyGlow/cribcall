import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../theme.dart';
import '../../shared/widgets/cc_metric_row.dart';

/// Shows a modal bottom sheet with the pairing QR code.
void showPairingQrSheet(
  BuildContext context, {
  required String payload,
  required Map<String, dynamic> payloadJson,
}) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (context) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pairing QR',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: QrImageView(
                  data: payload,
                  size: 220,
                  backgroundColor: Colors.white,
                  padding: const EdgeInsets.all(12),
                ),
              ),
              const SizedBox(height: 12),
              CcMetricRow(
                label: 'Payload size',
                value: '${payload.length} bytes',
              ),
              CcMetricRow(
                label: 'Monitor',
                value: payloadJson['monitorName'] as String? ?? '',
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Text(
                  const JsonEncoder.withIndent('  ').convert(payloadJson),
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
