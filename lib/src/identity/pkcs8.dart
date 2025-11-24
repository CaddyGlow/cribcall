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
  seq.add(ASN1OctetString(Uint8List.fromList(seedBytes)));
  return Uint8List.fromList(seq.encodedBytes);
}
