import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../config/build_flags.dart';
import '../control/control_message.dart';
import '../control/control_transport.dart';
import '../control/http_transport.dart';
import '../domain/models.dart';
import '../identity/device_identity.dart';
import '../state/app_state.dart';
import '../utils/canonical_json.dart';
import '../utils/hmac.dart';

class PinSessionState {
  PinSessionState({
    required this.sessionId,
    required this.pakeMsgA,
    required this.expiresAt,
    required this.maxAttempts,
    required this.attemptsUsed,
    this.pin,
    this.monitorIdentity,
  });

  final String sessionId;
  final String? pin;
  final String pakeMsgA;
  final DateTime expiresAt;
  final int maxAttempts;
  final int attemptsUsed;
  final DeviceIdentity? monitorIdentity;

  bool get expired => DateTime.now().isAfter(expiresAt);
  bool get hasPin => pin != null;

  PinSessionState incrementAttempt() => PinSessionState(
    sessionId: sessionId,
    pin: pin,
    pakeMsgA: pakeMsgA,
    expiresAt: expiresAt,
    maxAttempts: maxAttempts,
    attemptsUsed: attemptsUsed + 1,
    monitorIdentity: monitorIdentity,
  );
}

class PinPairingController extends Notifier<PinSessionState?> {
  static const _expiry = Duration(seconds: 60);
  static const _maxAttempts = 3;

  @override
  PinSessionState? build() => null;

  Future<PinRequiredMessage> startSession(DeviceIdentity identity) async {
    final random = Random.secure();
    final pin = List.generate(6, (_) => random.nextInt(10)).join();
    _logPairing(
      'Starting PIN session for monitor=${identity.deviceId} '
      'fingerprint=${_shortFingerprint(identity.certFingerprint)}',
    );
    return _startWithPin(identity: identity, pin: pin);
  }

  void acceptPinRequired(PinRequiredMessage message) {
    state = PinSessionState(
      sessionId: message.pairingSessionId,
      pakeMsgA: message.pakeMsgA,
      expiresAt: DateTime.now().add(Duration(seconds: message.expiresInSec)),
      maxAttempts: message.maxAttempts,
      attemptsUsed: 0,
    );
    _logPairing(
      'Hydrated PIN_REQUIRED session=${message.pairingSessionId} '
      'expiresIn=${message.expiresInSec}s '
      'maxAttempts=${message.maxAttempts}',
    );
  }

  /// Initiates the PIN pairing protocol by connecting to the monitor and
  /// sending PIN_PAIRING_INIT, then waiting for PIN_REQUIRED response.
  /// Returns null on success (session hydrated), or error message on failure.
  Future<String?> initiatePinPairing({
    required MdnsAdvertisement advertisement,
    required DeviceIdentity listenerIdentity,
    required String listenerName,
  }) async {
    final ip = advertisement.ip;
    if (ip == null) {
      _logPairing('initiatePinPairing failed: monitor IP is null');
      return 'Monitor IP address unknown';
    }

    _logPairing(
      'Initiating PIN pairing protocol:\n'
      '  monitor=${advertisement.monitorId}\n'
      '  name=${advertisement.monitorName}\n'
      '  ip=$ip:${advertisement.servicePort}\n'
      '  fingerprint=${_shortFingerprint(advertisement.monitorCertFingerprint)}',
    );

    ControlConnection? connection;

    try {
      final endpoint = ControlEndpoint(
        host: ip,
        port: advertisement.servicePort,
        expectedServerFingerprint: advertisement.monitorCertFingerprint,
        transport: kTransportHttpWs,
      );

      // Use allowUnpinned=true because we may not know the fingerprint yet
      // (mDNS advertisement might not include it). PAKE will verify trust.
      final needsUnpinned = advertisement.monitorCertFingerprint.isEmpty;
      _logPairing(
        'Connecting to monitor control server... '
        '(allowUnpinned=$needsUnpinned)',
      );

      final client = HttpControlClient();
      connection = await client.connect(
        endpoint: endpoint,
        clientIdentity: listenerIdentity,
        allowUnpinned: needsUnpinned,
      );
      _logPairing('Connected to monitor, sending PIN_PAIRING_INIT...');

      // Send PIN_PAIRING_INIT
      final initMessage = PinPairingInitMessage(
        listenerId: listenerIdentity.deviceId,
        listenerName: listenerName,
        protocolVersion: 1,
        listenerCertFingerprint: listenerIdentity.certFingerprint,
      );
      await connection.sendMessage(initMessage);
      _logPairing('PIN_PAIRING_INIT sent, waiting for PIN_REQUIRED...');

      // Wait for PIN_REQUIRED response with timeout
      final completer = Completer<PinRequiredMessage?>();
      final subscription = connection.receiveMessages().listen(
        (message) {
          _logPairing('Received message: ${message.type.name}');
          if (message is PinRequiredMessage) {
            if (!completer.isCompleted) {
              completer.complete(message);
            }
          } else if (message is PairRejectedMessage) {
            if (!completer.isCompleted) {
              _logPairing('Received PAIR_REJECTED: ${message.reason}');
              completer.complete(null);
            }
          }
        },
        onError: (e) {
          _logPairing('Message stream error: $e');
          if (!completer.isCompleted) {
            completer.complete(null);
          }
        },
      );

      try {
        final pinRequired = await completer.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            _logPairing('Timeout waiting for PIN_REQUIRED');
            return null;
          },
        );

        if (pinRequired == null) {
          _logPairing('Failed to receive PIN_REQUIRED from monitor');
          return 'Monitor did not respond with PIN session';
        }

        // Hydrate the session
        acceptPinRequired(pinRequired);
        _logPairing(
          'PIN pairing protocol initiated successfully:\n'
          '  sessionId=${pinRequired.pairingSessionId}\n'
          '  expiresIn=${pinRequired.expiresInSec}s',
        );
        return null; // Success
      } finally {
        await subscription.cancel();
      }
    } catch (e, stack) {
      _logPairing('initiatePinPairing error: $e\n$stack');
      return 'Connection failed: $e';
    } finally {
      // Keep connection open for PIN_SUBMIT later
      // The connection will be closed when the page is disposed or pairing completes
      _activeConnection = connection;
    }
  }

  /// The active connection used during PIN pairing (kept open for PIN_SUBMIT).
  ControlConnection? _activeConnection;

  /// Gets the active connection for sending PIN_SUBMIT.
  ControlConnection? get activeConnection => _activeConnection;

  /// Closes the active pairing connection.
  Future<void> closeConnection() async {
    final conn = _activeConnection;
    _activeConnection = null;
    if (conn != null) {
      _logPairing('Closing active pairing connection');
      await conn.close();
    }
  }

  Future<PinSubmitResult> submitPin({
    required String pairingSessionId,
    required String pin,
    required MdnsAdvertisement advertisement,
    required DeviceIdentity listenerIdentity,
    required String listenerName,
  }) async {
    final current = state;
    _logPairing(
      'submitPin called:\n'
      '  requestedSessionId=$pairingSessionId\n'
      '  currentState=${current == null ? 'NULL' : 'exists'}\n'
      '  currentSessionId=${current?.sessionId ?? 'N/A'}\n'
      '  sessionIdMatch=${current?.sessionId == pairingSessionId}\n'
      '  monitorId=${advertisement.monitorId}\n'
      '  monitorName=${advertisement.monitorName}',
    );
    if (current == null || current.sessionId != pairingSessionId) {
      final reason = current == null
          ? 'state is NULL - acceptPinRequired() was never called'
          : 'sessionId mismatch: current=${current.sessionId} != requested=$pairingSessionId';
      _logPairing(
        'PIN submit rejected (NO_SESSION):\n'
        '  reason: $reason\n'
        '  FIX: Listener must receive PIN_REQUIRED from monitor and call acceptPinRequired()\n'
        '  FLOW: Listener->PIN_PAIRING_INIT->Monitor->PIN_REQUIRED->Listener->acceptPinRequired()',
      );
      return const PinSubmitResult.failure('NO_SESSION');
    }
    if (current.expired) {
      state = null;
      _logPairing(
        'PIN session expired session=$pairingSessionId '
        'monitor=${advertisement.monitorId}',
      );
      return const PinSubmitResult.failure('EXPIRED');
    }
    if (current.attemptsUsed >= current.maxAttempts) {
      state = null;
      _logPairing(
        'PIN session locked session=$pairingSessionId '
        'monitor=${advertisement.monitorId}',
      );
      return const PinSubmitResult.failure('LOCKED');
    }

    final hasKnownPin = current.hasPin;
    if (hasKnownPin && pin != current.pin) {
      final updated = current.incrementAttempt();
      if (updated.attemptsUsed >= updated.maxAttempts) {
        state = null;
        _logPairing(
          'PIN locked after invalid attempt '
          'session=$pairingSessionId monitor=${advertisement.monitorId}',
        );
        return const PinSubmitResult.failure('LOCKED');
      }
      state = updated;
      _logPairing(
        'PIN invalid attempt=${updated.attemptsUsed}/${updated.maxAttempts} '
        'session=$pairingSessionId monitor=${advertisement.monitorId}',
      );
      return const PinSubmitResult.failure('INVALID_PIN');
    }

    if (!hasKnownPin) {
      final updated = current.incrementAttempt();
      if (updated.attemptsUsed > updated.maxAttempts) {
        state = null;
        _logPairing(
          'PIN locked (unknown pin) session=$pairingSessionId '
          'monitor=${advertisement.monitorId}',
        );
        return const PinSubmitResult.failure('LOCKED');
      }
      state = updated;
    }

    final engine = ref.read(pakeEngineProvider);
    final response = await engine.respond(pin: pin, pakeMsgA: current.pakeMsgA);

    final transcript = {
      'monitorId': advertisement.monitorId,
      'listenerId': listenerIdentity.deviceId,
      'listenerPublicKey': '',
      'listenerCertFingerprint': listenerIdentity.certFingerprint,
      'monitorCertFingerprint': advertisement.monitorCertFingerprint,
      'pairingSessionId': pairingSessionId,
    };

    final pairingKey = response.pairingKey;
    final authTag = computeHmacSha256(
      key: pairingKey,
      message: canonicalizeJson(transcript).codeUnits,
    );

    final result = PinSubmitResult.success(
      PinSubmitMessage(
        pairingSessionId: pairingSessionId,
        pakeMsgB: response.pakeMsgB,
        transcript: transcript,
        authTag: authTag,
      ),
    );
    if (hasKnownPin) {
      await ref
          .read(trustedMonitorsProvider.notifier)
          .addMonitor(
            MonitorQrPayload(
              monitorId: advertisement.monitorId,
              monitorName: advertisement.monitorName,
              monitorCertFingerprint: advertisement.monitorCertFingerprint,
              service: QrServiceInfo(
                protocol: 'baby-monitor',
                version: advertisement.version,
                defaultPort: advertisement.servicePort,
                transport: advertisement.transport,
              ),
            ),
          );
      state = null;
    }
    _logPairing(
      'PIN submit succeeded session=$pairingSessionId '
      'monitor=${advertisement.monitorId} '
      'ip=${advertisement.ip ?? 'unknown'} '
      'fingerprint=${_shortFingerprint(advertisement.monitorCertFingerprint)} '
      'trustedPersisted=$hasKnownPin',
    );
    return result;
  }

  Future<PinRequiredMessage> _startWithPin({
    required DeviceIdentity identity,
    required String pin,
  }) async {
    final pake = ref.read(pakeEngineProvider);
    final start = await pake.start(pin: pin);
    final session = PinSessionState(
      sessionId: const Uuid().v4(),
      pin: pin,
      pakeMsgA: start.pakeMsgA,
      expiresAt: DateTime.now().add(_expiry),
      maxAttempts: _maxAttempts,
      attemptsUsed: 0,
      monitorIdentity: identity,
    );
    state = session;
    _logPairing(
      'Issued PIN_REQUIRED session=${session.sessionId} '
      'expiresIn=${_expiry.inSeconds}s '
      'fingerprint=${_shortFingerprint(identity.certFingerprint)}',
    );
    return PinRequiredMessage(
      pairingSessionId: session.sessionId,
      pakeMsgA: session.pakeMsgA,
      expiresInSec: _expiry.inSeconds,
      maxAttempts: _maxAttempts,
    );
  }
}

class PinSubmitResult {
  const PinSubmitResult._(this.success, this.message, this.pinSubmitMessage);

  final bool success;
  final String message;
  final PinSubmitMessage? pinSubmitMessage;

  const PinSubmitResult.failure(String reason) : this._(false, reason, null);

  const PinSubmitResult.success(PinSubmitMessage msg) : this._(true, 'OK', msg);
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
