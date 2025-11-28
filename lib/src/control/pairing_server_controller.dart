/// Pairing Server Controller for Monitor side (TLS only).
///
/// Manages the pairing server lifecycle and handles pairing session flow.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../identity/device_identity.dart';
import '../notifications/notification_service.dart';
import '../state/app_state.dart';
import '../util/format_utils.dart';
import '../utils/logger.dart';
import 'pairing_server.dart';

const _log = Logger('pairing_ctrl');

// -----------------------------------------------------------------------------
// State Types
// -----------------------------------------------------------------------------

enum PairingServerStatus { stopped, starting, running, error }

/// Info about an active pairing session awaiting confirmation.
class ActivePairingSession {
  const ActivePairingSession({
    required this.sessionId,
    required this.listenerName,
    required this.comparisonCode,
    required this.expiresAt,
  });

  final String sessionId;

  /// Name of the device requesting to pair.
  final String listenerName;

  /// 6-digit comparison code to display to the user
  final String comparisonCode;
  final DateTime expiresAt;

  bool get expired => DateTime.now().isAfter(expiresAt);
}

class PairingServerState {
  const PairingServerState._({
    required this.status,
    this.port,
    this.fingerprint,
    this.error,
    this.activeSession,
  });

  const PairingServerState.stopped()
    : this._(status: PairingServerStatus.stopped);

  const PairingServerState.starting({
    required int port,
    required String fingerprint,
  }) : this._(
         status: PairingServerStatus.starting,
         port: port,
         fingerprint: fingerprint,
       );

  const PairingServerState.running({
    required int port,
    required String fingerprint,
    ActivePairingSession? activeSession,
  }) : this._(
         status: PairingServerStatus.running,
         port: port,
         fingerprint: fingerprint,
         activeSession: activeSession,
       );

  const PairingServerState.error({
    required String error,
    int? port,
    String? fingerprint,
  }) : this._(
         status: PairingServerStatus.error,
         port: port,
         fingerprint: fingerprint,
         error: error,
       );

  final PairingServerStatus status;
  final int? port;
  final String? fingerprint;
  final String? error;

  /// Active pairing session awaiting user confirmation (if any)
  final ActivePairingSession? activeSession;

  /// Creates a copy with updated active session
  PairingServerState copyWithSession(ActivePairingSession? session) {
    return PairingServerState._(
      status: status,
      port: port,
      fingerprint: fingerprint,
      error: error,
      activeSession: session,
    );
  }
}

// -----------------------------------------------------------------------------
// Controller
// -----------------------------------------------------------------------------

class PairingServerController extends Notifier<PairingServerState> {
  PairingServer? _server;
  bool _starting = false;

  @override
  PairingServerState build() {
    ref.onDispose(_shutdown);
    return const PairingServerState.stopped();
  }

  Future<void> start({
    required DeviceIdentity identity,
    required int port,
    required String monitorName,
  }) async {
    if (_starting) return;

    final current = state;
    if (current.status == PairingServerStatus.running &&
        current.port == port &&
        current.fingerprint == identity.certFingerprint) {
      _log(
        'Pairing server already running with same config, skipping restart',
      );
      return;
    }

    _starting = true;

    _log(
      'Starting pairing server port=$port '
      'fingerprint=${shortFingerprint(identity.certFingerprint)}',
    );

    state = PairingServerState.starting(
      port: port,
      fingerprint: identity.certFingerprint,
    );

    try {
      await _shutdown();
      _server = PairingServer(
        onPairingComplete: _onPairingComplete,
        onSessionCreated: _onSessionCreated,
        onSessionRejected: _onSessionRejected,
        onSessionConfirmed: _onSessionConfirmed,
      );

      await _server!.start(
        port: port,
        identity: identity,
        monitorName: monitorName,
      );

      final actualPort = _server!.boundPort ?? port;
      _log(
        'Pairing server running on port $actualPort '
        'fingerprint=${shortFingerprint(identity.certFingerprint)}',
      );

      state = PairingServerState.running(
        port: actualPort,
        fingerprint: identity.certFingerprint,
      );
    } catch (e) {
      _log('Pairing server start failed: $e');
      state = PairingServerState.error(
        error: '$e',
        port: port,
        fingerprint: identity.certFingerprint,
      );
    } finally {
      _starting = false;
    }
  }

  void _onSessionCreated(
    String sessionId,
    String listenerName,
    String comparisonCode,
    DateTime expiresAt,
  ) {
    _log(
      'Pairing session created: sessionId=$sessionId '
      'listenerName=$listenerName comparisonCode=$comparisonCode '
      'expiresAt=$expiresAt',
    );

    // Show system notification for pairing request
    NotificationService.instance.showPairingRequest(
      listenerName: listenerName,
      comparisonCode: comparisonCode,
      sessionId: sessionId,
    );

    // Update state with active session
    state = state.copyWithSession(
      ActivePairingSession(
        sessionId: sessionId,
        listenerName: listenerName,
        comparisonCode: comparisonCode,
        expiresAt: expiresAt,
      ),
    );
  }

  void _onSessionConfirmed(String sessionId) {
    _log('Pairing session confirmed by monitor: sessionId=$sessionId');
    // Cancel notification - user has responded via the app
    NotificationService.instance.cancelPairingRequest();
  }

  void _onSessionRejected(String sessionId) {
    _log('Pairing session rejected by monitor: sessionId=$sessionId');
    // Cancel notification and clear the session from UI
    NotificationService.instance.cancelPairingRequest();
    state = state.copyWithSession(null);
  }

  void _onPairingComplete(TrustedPeer peer) {
    _log(
      'Pairing complete: deviceId=${peer.remoteDeviceId} '
      'name=${peer.name} '
      'fingerprint=${shortFingerprint(peer.certFingerprint)}',
    );
    // Cancel notification and clear active session, persist trusted listener
    NotificationService.instance.cancelPairingRequest();
    state = state.copyWithSession(null);
    ref.read(trustedListenersProvider.notifier).addListener(peer);
  }

  /// Monitor user confirms the pairing request.
  /// Returns true if the session was successfully confirmed.
  bool confirmSession(String sessionId) {
    final srv = _server;
    if (srv == null) {
      _log('Cannot confirm session: server not running');
      return false;
    }
    return srv.confirmSession(sessionId);
  }

  /// Monitor user rejects the pairing request.
  /// Returns true if the session was successfully rejected.
  bool rejectSession(String sessionId) {
    final srv = _server;
    if (srv == null) {
      _log('Cannot reject session: server not running');
      return false;
    }
    return srv.rejectSession(sessionId);
  }

  /// Clears the active pairing session (e.g., if user cancels or session expires)
  void clearSession() {
    final session = state.activeSession;
    if (session != null) {
      // Also reject it on the server side
      _server?.rejectSession(session.sessionId);
    }
    // Cancel notification
    NotificationService.instance.cancelPairingRequest();
    state = state.copyWithSession(null);
  }

  /// Generate a new one-time pairing token for QR code flow.
  /// Invalidates any previous token.
  /// Returns null if server is not running.
  String? generatePairingToken() {
    final srv = _server;
    if (srv == null) {
      _log('Cannot generate pairing token: server not running');
      return null;
    }
    return srv.generatePairingToken();
  }

  /// Invalidate the current pairing token.
  void invalidatePairingToken() {
    _server?.invalidateToken();
  }

  /// Check if the server has a valid pairing token.
  bool get hasValidPairingToken => _server?.hasValidToken ?? false;

  Future<void> stop() => _shutdown();

  Future<void> _shutdown() async {
    _log('Stopping pairing server');
    try {
      await _server?.stop();
    } catch (_) {}
    _server = null;
    if (state.status != PairingServerStatus.stopped) {
      state = const PairingServerState.stopped();
    }
  }
}
