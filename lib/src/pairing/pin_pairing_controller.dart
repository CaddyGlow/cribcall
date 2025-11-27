import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../control/pairing_client.dart';
import '../domain/models.dart';
import '../identity/device_identity.dart';
import '../state/app_state.dart';

/// State for a numeric comparison pairing session.
///
/// Protocol v2 uses numeric comparison instead of PIN entry.
/// Both devices derive the same comparison code from ECDH shared secret.
class PairingSessionState {
  PairingSessionState({
    required this.sessionId,
    required this.comparisonCode,
    required this.pairingKey,
    required this.expiresAt,
    required this.advertisement,
  });

  final String sessionId;
  /// 6-digit comparison code displayed on both devices
  final String comparisonCode;
  /// Derived key for auth tag computation (kept internal)
  final List<int> pairingKey;
  final DateTime expiresAt;
  final MdnsAdvertisement advertisement;

  bool get expired => DateTime.now().isAfter(expiresAt);
}

/// Controller for numeric comparison pairing protocol.
///
/// Protocol v2 flow:
/// 1. Listener calls initiatePairing() -> receives comparison code
/// 2. Both devices display the same 6-digit comparison code
/// 3. User verifies the codes match on both devices
/// 4. Listener calls confirmPairing() -> pairing completes
class PairingController extends Notifier<PairingSessionState?> {
  @override
  PairingSessionState? build() => null;

  /// The HTTP RPC client for pairing requests.
  PairingClient? _pairingClient;

  /// Initiates the numeric comparison pairing protocol.
  ///
  /// Returns the 6-digit comparison code on success, or error message on failure.
  /// The comparison code should be displayed to the user so they can verify
  /// it matches the code shown on the monitor.
  Future<({String? comparisonCode, String? error})> initiatePairing({
    required MdnsAdvertisement advertisement,
    required DeviceIdentity listenerIdentity,
    required String listenerName,
  }) async {
    final ip = advertisement.ip;
    if (ip == null) {
      _logPairing('initiatePairing failed: monitor IP is null');
      return (comparisonCode: null, error: 'Monitor IP address unknown');
    }

    _logPairing(
      'Initiating numeric comparison pairing (HTTP RPC):\n'
      '  monitor=${advertisement.monitorId}\n'
      '  name=${advertisement.monitorName}\n'
      '  ip=$ip:${advertisement.pairingPort}\n'
      '  fingerprint=${_shortFingerprint(advertisement.monitorCertFingerprint)}',
    );

    try {
      final needsUnpinned = advertisement.monitorCertFingerprint.isEmpty;
      _logPairing('Calling POST /pair/init... (allowUnpinned=$needsUnpinned)');

      _pairingClient = PairingClient();
      final result = await _pairingClient!.initPairing(
        host: ip,
        port: advertisement.pairingPort,
        expectedFingerprint: advertisement.monitorCertFingerprint,
        listenerIdentity: listenerIdentity,
        listenerName: listenerName,
        allowUnpinned: needsUnpinned,
      );

      // Store session state
      state = PairingSessionState(
        sessionId: result.sessionId,
        comparisonCode: result.comparisonCode,
        pairingKey: result.pairingKey,
        expiresAt: result.expiresAt,
        advertisement: advertisement,
      );

      _logPairing(
        'Pairing session initialized:\n'
        '  sessionId=${result.sessionId}\n'
        '  comparisonCode=${result.comparisonCode}\n'
        '  expiresAt=${result.expiresAt}',
      );

      return (comparisonCode: result.comparisonCode, error: null);
    } catch (e, stack) {
      _logPairing('initiatePairing error: $e\n$stack');
      return (comparisonCode: null, error: 'Connection failed: $e');
    }
  }

  /// Confirms pairing after user has verified the comparison codes match.
  ///
  /// Returns null on success, or error message on failure.
  Future<String?> confirmPairing({
    required DeviceIdentity listenerIdentity,
  }) async {
    final current = state;
    if (current == null) {
      _logPairing('confirmPairing failed: no active session');
      return 'No active pairing session';
    }

    if (current.expired) {
      state = null;
      _logPairing('confirmPairing failed: session expired');
      return 'Session expired';
    }

    final ip = current.advertisement.ip;
    if (ip == null) {
      _logPairing('confirmPairing failed: monitor IP is null');
      return 'Monitor IP address unknown';
    }

    _logPairing('Confirming pairing session=${current.sessionId}...');

    try {
      final client = _pairingClient ?? PairingClient();
      _pairingClient = client;

      final response = await client.confirmPairing(
        host: ip,
        port: current.advertisement.pairingPort,
        expectedFingerprint: current.advertisement.monitorCertFingerprint,
        listenerIdentity: listenerIdentity,
        sessionId: current.sessionId,
        pairingKey: current.pairingKey,
        allowUnpinned: current.advertisement.monitorCertFingerprint.isEmpty,
      );

      if (!response.accepted) {
        state = null;
        _logPairing('Pairing rejected: ${response.reason}');
        return response.reason ?? 'Pairing rejected';
      }

      // Pairing accepted - persist trusted monitor
      _logPairing(
        'Pairing accepted:\n'
        '  monitorId=${response.monitorId}\n'
        '  monitorName=${response.monitorName}\n'
        '  fingerprint=${_shortFingerprint(response.monitorCertFingerprint ?? '')}',
      );

      await ref.read(trustedMonitorsProvider.notifier).addMonitor(
        MonitorQrPayload(
          monitorId: response.monitorId ?? current.advertisement.monitorId,
          monitorName: response.monitorName ?? current.advertisement.monitorName,
          monitorCertFingerprint: response.monitorCertFingerprint ??
              current.advertisement.monitorCertFingerprint,
          service: QrServiceInfo(
            protocol: 'baby-monitor',
            version: current.advertisement.version,
            controlPort: current.advertisement.controlPort,
            pairingPort: current.advertisement.pairingPort,
            transport: current.advertisement.transport,
          ),
        ),
        lastKnownIp: ip,
      );

      state = null;
      _logPairing('Pairing completed successfully');
      return null; // Success
    } catch (e, stack) {
      _logPairing('confirmPairing error: $e\n$stack');
      return 'Connection error: $e';
    }
  }

  /// Cancels the current pairing session.
  void cancelPairing() {
    state = null;
    _pairingClient?.close();
    _pairingClient = null;
    _logPairing('Pairing cancelled');
  }

  /// Closes the pairing client connection.
  void closeConnection() {
    _pairingClient?.close();
    _pairingClient = null;
    _logPairing('Pairing client closed');
  }
}

/// Result of a pairing confirmation attempt.
class PairingResult {
  const PairingResult._(this.success, this.message);

  final bool success;
  final String message;

  const PairingResult.failure(String reason) : this._(false, reason);
  const PairingResult.success() : this._(true, 'OK');
}

void _logPairing(String message) {
  developer.log(message, name: 'pairing');
}

String _shortFingerprint(String fingerprint) {
  if (fingerprint.length <= 12) return fingerprint;
  final prefix = fingerprint.substring(0, 6);
  final suffix = fingerprint.substring(fingerprint.length - 4);
  return '$prefix...$suffix';
}
