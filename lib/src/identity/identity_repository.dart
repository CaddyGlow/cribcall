import 'dart:convert';

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
      return _deserialize(data);
    }
    final identity = await DeviceIdentity.generate();
    await _store.write(await _serialize(identity));
    return identity;
  }

  Future<DeviceIdentity> _deserialize(Map<String, dynamic> data) async {
    final deviceId = data['deviceId'] as String;
    final privateKeySeed = base64Decode(data['privateKeySeed'] as String);
    final certificateDer = base64Decode(data['certificateDer'] as String);
    final storedFingerprint = data['certFingerprint'] as String;

    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(privateKeySeed);
    final publicKey = await keyPair.extractPublicKey();
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
      'privateKeySeed': base64Encode(privateKey),
      'certificateDer': base64Encode(identity.certificateDer),
      'certFingerprint': identity.certFingerprint,
    };
  }

  String _fingerprintHex(List<int> bytes) {
    final digest = sha256.convert(bytes);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
