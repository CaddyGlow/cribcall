import 'dart:convert';

import '../domain/models.dart';

MonitorQrPayload parseMonitorQrPayload(String raw) {
  final dynamic decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('QR payload must be a JSON object');
  }
  return MonitorQrPayload.fromJson(decoded.cast<String, dynamic>());
}
