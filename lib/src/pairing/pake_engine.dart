import 'dart:convert';

import 'package:cryptography/cryptography.dart';

class PakeStart {
  const PakeStart({required this.pakeMsgA});
  final String pakeMsgA;
}

class PakeResponse {
  const PakeResponse({required this.pakeMsgB, required this.pairingKey});
  final String pakeMsgB;
  final List<int> pairingKey;
}

abstract class PakeEngine {
  Future<PakeStart> start({required String pin});

  Future<PakeResponse> respond({required String pin, required String pakeMsgA});
}

class X25519PakeEngine implements PakeEngine {
  @override
  Future<PakeStart> start({required String pin}) async {
    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final public = await keyPair.extractPublicKey();
    final encoded = base64Encode(public.bytes);
    return PakeStart(pakeMsgA: encoded);
  }

  @override
  Future<PakeResponse> respond({
    required String pin,
    required String pakeMsgA,
  }) async {
    final algorithm = X25519();
    final remotePublic = SimplePublicKey(
      base64Decode(pakeMsgA),
      type: KeyPairType.x25519,
    );
    final keyPair = await algorithm.newKeyPair();
    final shared = await algorithm.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: remotePublic,
    );
    final sharedBytes = await shared.extractBytes();
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(sharedBytes),
      info: utf8.encode('cribcall-pake-$pin'),
    );
    final pairingKey = await derived.extractBytes();
    final public = await keyPair.extractPublicKey();
    final pakeMsgB = base64Encode(public.bytes);
    return PakeResponse(pakeMsgB: pakeMsgB, pairingKey: pairingKey);
  }
}
