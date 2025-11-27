import 'dart:convert';

/// HTTP request/response models for the pairing server.
/// These are used for REST API calls, not WebSocket messages.

/// POST /pair/init request body
///
/// Protocol v2: Uses numeric comparison with identity P-256 keys.
/// The listener sends its identity public key; both sides derive the same
/// comparison code from ECDH shared secret using their identity keys.
class PairInitRequest {
  const PairInitRequest({
    required this.listenerId,
    required this.listenerName,
    required this.listenerCertFingerprint,
    required this.listenerCertificateDer,
    required this.listenerPublicKey,
    this.protocolVersion = 2,
  });

  final String listenerId;
  final String listenerName;
  final String listenerCertFingerprint;
  final List<int> listenerCertificateDer;
  /// Base64-encoded P-256 identity public key (uncompressed, 65 bytes with 0x04 prefix)
  final String listenerPublicKey;
  final int protocolVersion;

  Map<String, dynamic> toJson() => {
        'listenerId': listenerId,
        'listenerName': listenerName,
        'listenerCertFingerprint': listenerCertFingerprint,
        'listenerCertificateDer': base64Encode(listenerCertificateDer),
        'listenerPublicKey': listenerPublicKey,
        'protocolVersion': protocolVersion,
      };

  factory PairInitRequest.fromJson(Map<String, dynamic> json) {
    return PairInitRequest(
      listenerId: json['listenerId'] as String,
      listenerName: json['listenerName'] as String,
      listenerCertFingerprint: json['listenerCertFingerprint'] as String,
      listenerCertificateDer:
          base64Decode(json['listenerCertificateDer'] as String),
      listenerPublicKey: json['listenerPublicKey'] as String,
      protocolVersion: json['protocolVersion'] as int? ?? 2,
    );
  }

  String toJsonString() => jsonEncode(toJson());
}

/// POST /pair/init response body
///
/// Protocol v2: Uses numeric comparison instead of PIN entry.
/// Both sides derive the same 6-digit code from the ECDH shared secret
/// computed using their identity P-256 keys.
class PairInitResponse {
  const PairInitResponse({
    required this.pairingSessionId,
    required this.monitorPublicKey,
    required this.expiresInSec,
  });

  final String pairingSessionId;
  /// Base64-encoded P-256 identity public key (uncompressed, 65 bytes with 0x04 prefix)
  final String monitorPublicKey;
  final int expiresInSec;

  Map<String, dynamic> toJson() => {
        'pairingSessionId': pairingSessionId,
        'monitorPublicKey': monitorPublicKey,
        'expiresInSec': expiresInSec,
      };

  factory PairInitResponse.fromJson(Map<String, dynamic> json) {
    return PairInitResponse(
      pairingSessionId: json['pairingSessionId'] as String,
      monitorPublicKey: json['monitorPublicKey'] as String,
      expiresInSec: json['expiresInSec'] as int,
    );
  }

  String toJsonString() => jsonEncode(toJson());
}

/// POST /pair/confirm request body
///
/// Sent by the listener after user confirms the comparison codes match.
/// Contains an auth tag to prove the listener derived the same shared secret.
class PairConfirmRequest {
  const PairConfirmRequest({
    required this.pairingSessionId,
    required this.transcript,
    required this.authTag,
  });

  final String pairingSessionId;
  /// Transcript of the pairing session for verification
  final Map<String, dynamic> transcript;
  /// HMAC-SHA256 of canonical transcript, keyed by derived pairing key
  final String authTag;

  Map<String, dynamic> toJson() => {
        'pairingSessionId': pairingSessionId,
        'transcript': transcript,
        'authTag': authTag,
      };

  factory PairConfirmRequest.fromJson(Map<String, dynamic> json) {
    return PairConfirmRequest(
      pairingSessionId: json['pairingSessionId'] as String,
      transcript: (json['transcript'] as Map).cast<String, dynamic>(),
      authTag: json['authTag'] as String,
    );
  }

  String toJsonString() => jsonEncode(toJson());
}

/// Status for PIN-based pairing confirmation
enum PairConfirmStatus {
  /// Pairing accepted by monitor user
  accepted,
  /// Pairing rejected by monitor user or timed out
  rejected,
  /// Waiting for monitor user to accept/reject
  pending,
}

/// POST /pair/confirm response body
class PairConfirmResponse {
  const PairConfirmResponse({
    required this.status,
    this.monitorId,
    this.monitorName,
    this.monitorCertFingerprint,
    this.monitorCertificateDer,
    this.reason,
  });

  final PairConfirmStatus status;
  final String? monitorId;
  final String? monitorName;
  final String? monitorCertFingerprint;
  final List<int>? monitorCertificateDer;
  final String? reason;

  /// Legacy compatibility: returns true only if status is accepted
  bool get accepted => status == PairConfirmStatus.accepted;

  /// Returns true if status is pending (waiting for monitor user)
  bool get isPending => status == PairConfirmStatus.pending;

  Map<String, dynamic> toJson() => {
        'status': status.name,
        // Legacy field for backward compatibility
        'accepted': status == PairConfirmStatus.accepted,
        if (monitorId != null) 'monitorId': monitorId,
        if (monitorName != null) 'monitorName': monitorName,
        if (monitorCertFingerprint != null)
          'monitorCertFingerprint': monitorCertFingerprint,
        if (monitorCertificateDer != null)
          'monitorCertificateDer': base64Encode(monitorCertificateDer!),
        if (reason != null) 'reason': reason,
      };

  factory PairConfirmResponse.fromJson(Map<String, dynamic> json) {
    final certDerB64 = json['monitorCertificateDer'] as String?;
    // Support both new 'status' field and legacy 'accepted' field
    PairConfirmStatus status;
    if (json.containsKey('status')) {
      status = PairConfirmStatus.values.byName(json['status'] as String);
    } else {
      // Legacy: only accepted or rejected
      status = (json['accepted'] as bool)
          ? PairConfirmStatus.accepted
          : PairConfirmStatus.rejected;
    }
    return PairConfirmResponse(
      status: status,
      monitorId: json['monitorId'] as String?,
      monitorName: json['monitorName'] as String?,
      monitorCertFingerprint: json['monitorCertFingerprint'] as String?,
      monitorCertificateDer:
          certDerB64 != null ? base64Decode(certDerB64) : null,
      reason: json['reason'] as String?,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  /// Create a successful pairing response
  factory PairConfirmResponse.accepted({
    required String monitorId,
    required String monitorName,
    required String monitorCertFingerprint,
    required List<int> monitorCertificateDer,
  }) {
    return PairConfirmResponse(
      status: PairConfirmStatus.accepted,
      monitorId: monitorId,
      monitorName: monitorName,
      monitorCertFingerprint: monitorCertFingerprint,
      monitorCertificateDer: monitorCertificateDer,
    );
  }

  /// Create a rejected pairing response
  factory PairConfirmResponse.rejected(String reason) {
    return PairConfirmResponse(status: PairConfirmStatus.rejected, reason: reason);
  }

  /// Create a pending response (waiting for monitor user to accept)
  factory PairConfirmResponse.pending() {
    return const PairConfirmResponse(status: PairConfirmStatus.pending);
  }
}

/// Error response for pairing endpoints
class PairErrorResponse {
  const PairErrorResponse({
    required this.error,
    this.code,
  });

  final String error;
  final String? code;

  Map<String, dynamic> toJson() => {
        'error': error,
        if (code != null) 'code': code,
      };

  factory PairErrorResponse.fromJson(Map<String, dynamic> json) {
    return PairErrorResponse(
      error: json['error'] as String,
      code: json['code'] as String?,
    );
  }

  String toJsonString() => jsonEncode(toJson());
}

/// POST /pair/token request body
///
/// Used for QR code pairing with one-time token.
/// The listener sends the token from the QR code along with its identity.
/// If the token is valid, pairing completes immediately without user confirmation.
class PairTokenRequest {
  const PairTokenRequest({
    required this.pairingToken,
    required this.listenerId,
    required this.listenerName,
    required this.listenerCertFingerprint,
    required this.listenerCertificateDer,
  });

  /// One-time pairing token from QR code (base64url encoded 32 bytes)
  final String pairingToken;
  final String listenerId;
  final String listenerName;
  final String listenerCertFingerprint;
  final List<int> listenerCertificateDer;

  Map<String, dynamic> toJson() => {
        'pairingToken': pairingToken,
        'listenerId': listenerId,
        'listenerName': listenerName,
        'listenerCertFingerprint': listenerCertFingerprint,
        'listenerCertificateDer': base64Encode(listenerCertificateDer),
      };

  factory PairTokenRequest.fromJson(Map<String, dynamic> json) {
    return PairTokenRequest(
      pairingToken: json['pairingToken'] as String,
      listenerId: json['listenerId'] as String,
      listenerName: json['listenerName'] as String,
      listenerCertFingerprint: json['listenerCertFingerprint'] as String,
      listenerCertificateDer:
          base64Decode(json['listenerCertificateDer'] as String),
    );
  }

  String toJsonString() => jsonEncode(toJson());
}

/// POST /pair/token response body
///
/// Response for QR code token-based pairing.
class PairTokenResponse {
  const PairTokenResponse({
    required this.accepted,
    this.monitorId,
    this.monitorName,
    this.monitorCertFingerprint,
    this.monitorCertificateDer,
    this.reason,
  });

  final bool accepted;
  final String? monitorId;
  final String? monitorName;
  final String? monitorCertFingerprint;
  final List<int>? monitorCertificateDer;
  final String? reason;

  Map<String, dynamic> toJson() => {
        'accepted': accepted,
        if (monitorId != null) 'monitorId': monitorId,
        if (monitorName != null) 'monitorName': monitorName,
        if (monitorCertFingerprint != null)
          'monitorCertFingerprint': monitorCertFingerprint,
        if (monitorCertificateDer != null)
          'monitorCertificateDer': base64Encode(monitorCertificateDer!),
        if (reason != null) 'reason': reason,
      };

  factory PairTokenResponse.fromJson(Map<String, dynamic> json) {
    final certDerB64 = json['monitorCertificateDer'] as String?;
    return PairTokenResponse(
      accepted: json['accepted'] as bool,
      monitorId: json['monitorId'] as String?,
      monitorName: json['monitorName'] as String?,
      monitorCertFingerprint: json['monitorCertFingerprint'] as String?,
      monitorCertificateDer:
          certDerB64 != null ? base64Decode(certDerB64) : null,
      reason: json['reason'] as String?,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  /// Create a successful token pairing response
  factory PairTokenResponse.accepted({
    required String monitorId,
    required String monitorName,
    required String monitorCertFingerprint,
    required List<int> monitorCertificateDer,
  }) {
    return PairTokenResponse(
      accepted: true,
      monitorId: monitorId,
      monitorName: monitorName,
      monitorCertFingerprint: monitorCertFingerprint,
      monitorCertificateDer: monitorCertificateDer,
    );
  }

  /// Create a rejected token pairing response
  factory PairTokenResponse.rejected(String reason) {
    return PairTokenResponse(accepted: false, reason: reason);
  }
}
