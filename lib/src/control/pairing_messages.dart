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
    required this.deviceId,
    required this.deviceName,
    required this.certFingerprint,
    required this.certificateDer,
    required this.publicKey,
    this.protocolVersion = 2,
  });

  final String deviceId;
  final String deviceName;
  final String certFingerprint;
  final List<int> certificateDer;
  /// Base64-encoded P-256 identity public key (uncompressed, 65 bytes with 0x04 prefix)
  final String publicKey;
  final int protocolVersion;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'certFingerprint': certFingerprint,
        'certificateDer': base64Encode(certificateDer),
        'publicKey': publicKey,
        'protocolVersion': protocolVersion,
      };

  factory PairInitRequest.fromJson(Map<String, dynamic> json) {
    return PairInitRequest(
      deviceId: json['deviceId'] as String,
      deviceName: json['deviceName'] as String,
      certFingerprint: json['certFingerprint'] as String,
      certificateDer:
          base64Decode(json['certificateDer'] as String),
      publicKey: json['publicKey'] as String,
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
    this.remoteDeviceId,
    this.monitorName,
    this.certFingerprint,
    this.certificateDer,
    this.reason,
  });

  final PairConfirmStatus status;
  final String? remoteDeviceId;
  final String? monitorName;
  final String? certFingerprint;
  final List<int>? certificateDer;
  final String? reason;

  /// Legacy compatibility: returns true only if status is accepted
  bool get accepted => status == PairConfirmStatus.accepted;

  /// Returns true if status is pending (waiting for monitor user)
  bool get isPending => status == PairConfirmStatus.pending;

  Map<String, dynamic> toJson() => {
        'status': status.name,
        // Legacy field for backward compatibility
        'accepted': status == PairConfirmStatus.accepted,
        if (remoteDeviceId != null) 'remoteDeviceId': remoteDeviceId,
        if (monitorName != null) 'monitorName': monitorName,
        if (certFingerprint != null)
          'certFingerprint': certFingerprint,
        if (certificateDer != null)
          'certificateDer': base64Encode(certificateDer!),
        if (reason != null) 'reason': reason,
      };

  factory PairConfirmResponse.fromJson(Map<String, dynamic> json) {
    final certDerB64 = json['certificateDer'] as String?;
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
      remoteDeviceId: json['remoteDeviceId'] as String?,
      monitorName: json['monitorName'] as String?,
      certFingerprint: json['certFingerprint'] as String?,
      certificateDer:
          certDerB64 != null ? base64Decode(certDerB64) : null,
      reason: json['reason'] as String?,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  /// Create a successful pairing response
  factory PairConfirmResponse.accepted({
    required String remoteDeviceId,
    required String monitorName,
    required String certFingerprint,
    required List<int> certificateDer,
  }) {
    return PairConfirmResponse(
      status: PairConfirmStatus.accepted,
      remoteDeviceId: remoteDeviceId,
      monitorName: monitorName,
      certFingerprint: certFingerprint,
      certificateDer: certificateDer,
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
    required this.deviceId,
    required this.deviceName,
    required this.certFingerprint,
    required this.certificateDer,
  });

  /// One-time pairing token from QR code (base64url encoded 32 bytes)
  final String pairingToken;
  final String deviceId;
  final String deviceName;
  final String certFingerprint;
  final List<int> certificateDer;

  Map<String, dynamic> toJson() => {
        'pairingToken': pairingToken,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'certFingerprint': certFingerprint,
        'certificateDer': base64Encode(certificateDer),
      };

  factory PairTokenRequest.fromJson(Map<String, dynamic> json) {
    return PairTokenRequest(
      pairingToken: json['pairingToken'] as String,
      deviceId: json['deviceId'] as String,
      deviceName: json['deviceName'] as String,
      certFingerprint: json['certFingerprint'] as String,
      certificateDer:
          base64Decode(json['certificateDer'] as String),
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
    this.remoteDeviceId,
    this.monitorName,
    this.certFingerprint,
    this.certificateDer,
    this.reason,
  });

  final bool accepted;
  final String? remoteDeviceId;
  final String? monitorName;
  final String? certFingerprint;
  final List<int>? certificateDer;
  final String? reason;

  Map<String, dynamic> toJson() => {
        'accepted': accepted,
        if (remoteDeviceId != null) 'remoteDeviceId': remoteDeviceId,
        if (monitorName != null) 'monitorName': monitorName,
        if (certFingerprint != null)
          'certFingerprint': certFingerprint,
        if (certificateDer != null)
          'certificateDer': base64Encode(certificateDer!),
        if (reason != null) 'reason': reason,
      };

  factory PairTokenResponse.fromJson(Map<String, dynamic> json) {
    final certDerB64 = json['certificateDer'] as String?;
    return PairTokenResponse(
      accepted: json['accepted'] as bool,
      remoteDeviceId: json['remoteDeviceId'] as String?,
      monitorName: json['monitorName'] as String?,
      certFingerprint: json['certFingerprint'] as String?,
      certificateDer:
          certDerB64 != null ? base64Decode(certDerB64) : null,
      reason: json['reason'] as String?,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  /// Create a successful token pairing response
  factory PairTokenResponse.accepted({
    required String remoteDeviceId,
    required String monitorName,
    required String certFingerprint,
    required List<int> certificateDer,
  }) {
    return PairTokenResponse(
      accepted: true,
      remoteDeviceId: remoteDeviceId,
      monitorName: monitorName,
      certFingerprint: certFingerprint,
      certificateDer: certificateDer,
    );
  }

  /// Create a rejected token pairing response
  factory PairTokenResponse.rejected(String reason) {
    return PairTokenResponse(accepted: false, reason: reason);
  }
}
