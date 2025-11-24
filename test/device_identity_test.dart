import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:cribcall/src/identity/device_identity.dart';
import 'package:cribcall/src/identity/pkcs8.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generates Ed25519 self-signed certificate with fingerprint', () async {
    final identity = await DeviceIdentity.generate(deviceId: 'test-device');

    expect(identity.certFingerprint.length, 64);
    final parser = ASN1Parser(Uint8List.fromList(identity.certificateDer));
    final certSeq = parser.nextObject() as ASN1Sequence;
    final certElements = certSeq.elements;
    expect(certElements.length, 3);

    final tbs = certElements[0] as ASN1Sequence;
    final tbsElements = tbs.elements;
    final spki = tbsElements[6] as ASN1Sequence;
    final algId = spki.elements[0] as ASN1Sequence;
    final oid = algId.elements[0] as ASN1ObjectIdentifier;
    expect(oid.identifier, '1.3.101.112'); // Ed25519

    final extensionsWrapper = tbsElements[7];
    final extParser = ASN1Parser(extensionsWrapper.valueBytes());
    final extSeq = extParser.nextObject() as ASN1Sequence;
    final sanExt =
        extSeq.elements.firstWhere(
              (el) =>
                  el is ASN1Sequence &&
                  (el.elements[0] as ASN1ObjectIdentifier).identifier ==
                      '2.5.29.17',
            )
            as ASN1Sequence;
    final sanOctets = sanExt.elements[1] as ASN1OctetString;
    final sanParser = ASN1Parser(Uint8List.fromList(sanOctets.octets));
    final generalNames = sanParser.nextObject() as ASN1Sequence;
    final uriObj = generalNames.elements.first;
    expect(String.fromCharCodes(uriObj.valueBytes()), 'cribcall:test-device');
  });

  test('encodes Ed25519 private key as RFC8410-wrapped PKCS#8', () {
    final seed = List<int>.generate(32, (i) => i);
    final pkcs8 = ed25519PrivateKeyPkcs8(seed);

    final parser = ASN1Parser(Uint8List.fromList(pkcs8));
    final seq = parser.nextObject() as ASN1Sequence;
    expect(seq.elements.length, 3);

    final privateKeyOctetString = seq.elements[2] as ASN1OctetString;
    final wrapped = privateKeyOctetString.octets;
    expect(wrapped[0], 0x04);
    expect(wrapped[1], seed.length);
    expect(wrapped.sublist(2), seed);
  });
}
