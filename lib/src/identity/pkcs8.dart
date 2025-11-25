import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';

const _ed25519Oid = [1, 3, 101, 112];
const _ecPublicKeyOid = [1, 2, 840, 10045, 2, 1];
const _prime256v1Oid = [1, 2, 840, 10045, 3, 1, 7];

/// Encodes an Ed25519 private key seed into PKCS#8 DER bytes.
Uint8List ed25519PrivateKeyPkcs8(List<int> seedBytes) {
  if (seedBytes.length != 32) {
    throw ArgumentError.value(
      seedBytes.length,
      'seedBytes.length',
      'Ed25519 seed must be 32 bytes',
    );
  }
  final seq = ASN1Sequence();
  seq.add(ASN1Integer(BigInt.zero));
  final algId = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponents(_ed25519Oid));
  seq.add(algId);
  // RFC 8410: privateKey OCTET STRING wraps the raw seed with an inner octet
  // string tag/length (0x04 <len> || seed).
  final wrappedSeed = Uint8List(seedBytes.length + 2);
  wrappedSeed
    ..[0] = 0x04
    ..[1] = seedBytes.length
    ..setRange(2, wrappedSeed.length, seedBytes);
  seq.add(ASN1OctetString(wrappedSeed));
  return Uint8List.fromList(seq.encodedBytes);
}

/// Encodes a P-256 private key (raw 32-byte scalar) into PKCS#8 DER bytes.
Uint8List p256PrivateKeyPkcs8({
  required List<int> privateKeyBytes,
  required List<int> publicKeyBytes,
}) {
  if (privateKeyBytes.length != 32) {
    throw ArgumentError.value(
      privateKeyBytes.length,
      'privateKeyBytes.length',
      'P-256 private key must be 32 bytes',
    );
  }
  // ECPrivateKey (RFC 5915)
  final ecPrivateKey = ASN1Sequence();
  ecPrivateKey.add(ASN1Integer(BigInt.one)); // version
  ecPrivateKey.add(ASN1OctetString(Uint8List.fromList(privateKeyBytes)));
  final params = ASN1ObjectIdentifier.fromComponents(_prime256v1Oid);
  final paramsWrapper = ASN1Sequence(tag: 0xa0)..add(params);
  ecPrivateKey.add(paramsWrapper);
  final pubKeyBitString = ASN1Sequence(tag: 0xa1)
    ..add(ASN1BitString(Uint8List.fromList(publicKeyBytes)));
  ecPrivateKey.add(pubKeyBitString);

  // PrivateKeyInfo (PKCS#8)
  final pkcs8 = ASN1Sequence();
  pkcs8.add(ASN1Integer(BigInt.zero)); // version
  final algId = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponents(_ecPublicKeyOid))
    ..add(ASN1ObjectIdentifier.fromComponents(_prime256v1Oid));
  pkcs8.add(algId);
  pkcs8.add(ASN1OctetString(ecPrivateKey.encodedBytes));
  return Uint8List.fromList(pkcs8.encodedBytes);
}
