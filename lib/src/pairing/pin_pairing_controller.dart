import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../control/control_message.dart';
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
  }

  Future<PinSubmitResult> submitPin({
    required String pairingSessionId,
    required String pin,
    required MdnsAdvertisement advertisement,
    required DeviceIdentity listenerIdentity,
    required String listenerName,
  }) async {
    final current = state;
    if (current == null || current.sessionId != pairingSessionId) {
      return const PinSubmitResult.failure('NO_SESSION');
    }
    if (current.expired) {
      state = null;
      return const PinSubmitResult.failure('EXPIRED');
    }
    if (current.attemptsUsed >= current.maxAttempts) {
      state = null;
      return const PinSubmitResult.failure('LOCKED');
    }

    final hasKnownPin = current.hasPin;
    if (hasKnownPin && pin != current.pin) {
      final updated = current.incrementAttempt();
      if (updated.attemptsUsed >= updated.maxAttempts) {
        state = null;
        return const PinSubmitResult.failure('LOCKED');
      }
      state = updated;
      return const PinSubmitResult.failure('INVALID_PIN');
    }

    if (!hasKnownPin) {
      final updated = current.incrementAttempt();
      if (updated.attemptsUsed > updated.maxAttempts) {
        state = null;
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
      ref.read(trustedMonitorsProvider.notifier).addMonitor(
            MonitorQrPayload(
              monitorId: advertisement.monitorId,
              monitorName: advertisement.monitorName,
              monitorCertFingerprint: advertisement.monitorCertFingerprint,
              service: QrServiceInfo(
                protocol: 'baby-monitor',
                version: advertisement.version,
                defaultPort: advertisement.servicePort,
              ),
            ),
          );
      state = null;
    }
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
