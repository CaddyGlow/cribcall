import 'dart:convert';
import 'dart:typed_data';
import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';

import 'package:asn1lib/asn1lib.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import 'device_identity.dart';
import 'identity_store.dart';

class IdentityRepository {
  IdentityRepository({String? overrideDirectoryPath, IdentityStore? store})
    : _store =
          store ??
          IdentityStore.create(overrideDirectoryPath: overrideDirectoryPath);

  final IdentityStore _store;

  Future<DeviceIdentity> loadOrCreate() async {
    final data = await _store.read();
    if (data != null) {
      try {
        return await _deserialize(data);
      } catch (_) {
        // Fall through and rebuild a fresh identity if old data is incompatible.
        debugPrint(
          '[identity_repository] Stored identity invalid, regenerating',
        );
      }
    }
    debugPrint('[identity_repository] Generating new device identity');
    final identity = await DeviceIdentity.generate();
    try {
      await _store.write(await _serialize(identity));
      debugPrint('[identity_repository] Identity persisted');
    } catch (e) {
      debugPrint('[identity_repository] Failed to persist identity: $e');
      rethrow;
    }
    return identity;
  }

  Future<DeviceIdentity> _deserialize(Map<String, dynamic> data) async {
    final deviceId = data['deviceId'] as String;
    final privateKeyBytes = base64Decode(data['privateKey'] as String);
    final publicKeyBytes = base64Decode(data['publicKey'] as String);
    final certificateDer = base64Decode(data['certificateDer'] as String);
    final storedFingerprint = data['certFingerprint'] as String;

    final publicKey = SimplePublicKey(publicKeyBytes, type: KeyPairType.p256);
    final keyPair = SimpleKeyPairData(
      privateKeyBytes,
      publicKey: publicKey,
      type: KeyPairType.p256,
    );
    final fingerprint = _fingerprintHex(certificateDer);

    if (fingerprint != storedFingerprint) {
      throw const FormatException('Stored certificate fingerprint mismatch');
    }

    // Validate certificate structure: issuer must equal subject for self-signed
    // certificates to work correctly as trust anchors in mTLS.
    if (!_validateCertificateStructure(certificateDer)) {
      throw const FormatException(
        'Certificate has invalid structure (issuer != subject)',
      );
    }

    return DeviceIdentity(
      deviceId: deviceId,
      publicKey: publicKey,
      keyPair: keyPair,
      certificateDer: certificateDer,
      certFingerprint: fingerprint,
    );
  }

  Future<Map<String, dynamic>> _serialize(DeviceIdentity identity) async {
    final keyData = await identity.keyPair.extract() as SimpleKeyPairData;
    final privateKey = keyData.bytes;
    return <String, dynamic>{
      'deviceId': identity.deviceId,
      'privateKey': base64Encode(privateKey),
      'publicKey': base64Encode(identity.publicKeyUncompressed),
      'certificateDer': base64Encode(identity.certificateDer),
      'certFingerprint': identity.certFingerprint,
    };
  }

  String _fingerprintHex(List<int> bytes) {
    final digest = sha256.convert(bytes);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Validates that a certificate has issuer == subject (required for self-signed
  /// certificates to work as their own trust anchor in mTLS).
  /// Returns true if the certificate structure is valid, false otherwise.
  bool _validateCertificateStructure(List<int> certificateDer) {
    try {
      final parser = ASN1Parser(Uint8List.fromList(certificateDer));
      final cert = parser.nextObject() as ASN1Sequence;
      final tbsCertificate = cert.elements[0] as ASN1Sequence;

      // TBSCertificate structure (X.509 v3):
      // [0] version, serialNumber, signature, issuer, validity, subject, ...
      // For v3 certs, issuer is at index 3, subject is at index 5
      ASN1Sequence? issuer;
      ASN1Sequence? subject;

      int idx = 0;
      for (final element in tbsCertificate.elements) {
        // Skip version (tagged [0])
        if (element.tag == 0xa0) {
          continue;
        }
        if (idx == 0) {
          // serialNumber - skip
          idx++;
        } else if (idx == 1) {
          // signature algorithm - skip
          idx++;
        } else if (idx == 2) {
          // issuer
          issuer = element as ASN1Sequence;
          idx++;
        } else if (idx == 3) {
          // validity - skip
          idx++;
        } else if (idx == 4) {
          // subject
          subject = element as ASN1Sequence;
          break;
        }
      }

      if (issuer == null || subject == null) {
        debugPrint(
          '[identity_repository] Certificate parsing failed: '
          'issuer or subject not found',
        );
        return false;
      }

      // Compare encoded bytes of issuer and subject
      final issuerBytes = issuer.encodedBytes;
      final subjectBytes = subject.encodedBytes;

      if (issuerBytes.length != subjectBytes.length) {
        debugPrint(
          '[identity_repository] Certificate invalid: '
          'issuer/subject length mismatch '
          '(issuer=${issuerBytes.length}, subject=${subjectBytes.length})',
        );
        return false;
      }

      for (var i = 0; i < issuerBytes.length; i++) {
        if (issuerBytes[i] != subjectBytes[i]) {
          debugPrint(
            '[identity_repository] Certificate invalid: '
            'issuer != subject (self-signed cert requirement)',
          );
          return false;
        }
      }

      return true;
    } catch (e) {
      debugPrint('[identity_repository] Certificate validation error: $e');
      return false;
    }
  }
}
