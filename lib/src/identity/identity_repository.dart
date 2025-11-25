import 'dart:convert';
import '../foundation/foundation_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';

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
}
