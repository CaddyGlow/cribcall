import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';

const _ed25519Oid = [1, 3, 101, 112];

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
