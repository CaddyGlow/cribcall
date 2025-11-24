import 'dart:math';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

class DeviceIdentity {
  DeviceIdentity({
    required this.deviceId,
    required this.publicKey,
    required this.keyPair,
    required this.certificateDer,
    required this.certFingerprint,
  });

  final String deviceId;
  final SimplePublicKey publicKey;
  final KeyPair keyPair;
  final List<int> certificateDer;
  final String certFingerprint;

  static const _ed25519Oid = [1, 3, 101, 112];
  static const _subjectAltNameOid = [2, 5, 29, 17];

  static Future<DeviceIdentity> generate({String? deviceId}) async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final id = deviceId ?? const Uuid().v4();
    final certificateDer = await _buildSelfSignedCertificate(
      deviceId: id,
      publicKey: publicKey,
      keyPair: keyPair,
    );
    final fingerprint = _fingerprintHex(certificateDer);

    return DeviceIdentity(
      deviceId: id,
      publicKey: publicKey,
      keyPair: keyPair,
      certificateDer: certificateDer,
      certFingerprint: fingerprint,
    );
  }

  static String _fingerprintHex(List<int> bytes) {
    final digest = sha256.convert(bytes);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<List<int>> _buildSelfSignedCertificate({
    required String deviceId,
    required SimplePublicKey publicKey,
    required KeyPair keyPair,
    Duration validity = const Duration(days: 365),
  }) async {
    final now = DateTime.now().toUtc();
    final notBefore = now.subtract(const Duration(hours: 1));
    final notAfter = now.add(validity);

    final tbs = ASN1Sequence();

    final version = ASN1Sequence(tag: 0xa0);
    version.add(ASN1Integer(BigInt.from(2))); // v3
    tbs.add(version);

    final serial = BigInt.from(Random.secure().nextInt(1 << 31));
    tbs.add(ASN1Integer(serial));

    final algorithmIdentifier = _ed25519AlgorithmIdentifier();
    tbs.add(algorithmIdentifier);

    tbs.add(_buildName('CribCall'));

    tbs.add(_buildValidity(notBefore, notAfter));

    tbs.add(_buildName('cribcall-$deviceId'));

    tbs.add(_buildSubjectPublicKeyInfo(publicKey));

    final extensionsWrapper = ASN1Sequence(tag: 0xa3);
    final extensions = ASN1Sequence();
    extensions.add(_buildSubjectAltNameExtension(deviceId));
    extensionsWrapper.add(extensions);
    tbs.add(extensionsWrapper);

    final tbsBytes = tbs.encodedBytes;
    final signature = await Ed25519().sign(tbsBytes, keyPair: keyPair);

    final certificate = ASN1Sequence();
    certificate.add(tbs);
    certificate.add(algorithmIdentifier);
    certificate.add(ASN1BitString(Uint8List.fromList(signature.bytes)));

    return Uint8List.fromList(certificate.encodedBytes);
  }

  static ASN1Sequence _ed25519AlgorithmIdentifier() {
    final sequence = ASN1Sequence();
    sequence.add(ASN1ObjectIdentifier.fromComponents(_ed25519Oid));
    return sequence;
  }

  static ASN1Sequence _buildName(String commonName) {
    final name = ASN1Sequence();
    final rdnSet = ASN1Set();
    final cnSeq = ASN1Sequence();
    cnSeq.add(ASN1ObjectIdentifier.fromComponents([2, 5, 4, 3])); // CN
    cnSeq.add(ASN1UTF8String(commonName));
    rdnSet.add(cnSeq);
    name.add(rdnSet);
    return name;
  }

  static ASN1Sequence _buildValidity(DateTime notBefore, DateTime notAfter) {
    final validitySeq = ASN1Sequence();
    validitySeq.add(ASN1UtcTime(notBefore));
    validitySeq.add(ASN1UtcTime(notAfter));
    return validitySeq;
  }

  static ASN1Sequence _buildSubjectPublicKeyInfo(SimplePublicKey publicKey) {
    final spki = ASN1Sequence();
    spki.add(_ed25519AlgorithmIdentifier());
    spki.add(ASN1BitString(Uint8List.fromList(publicKey.bytes)));
    return spki;
  }

  static ASN1Sequence _buildSubjectAltNameExtension(String deviceId) {
    final sanNames = ASN1Sequence();
    sanNames.add(ASN1IA5String('cribcall:$deviceId', tag: 0x86)); // URI
    final sanBytes = sanNames.encodedBytes;

    final ext = ASN1Sequence();
    ext.add(ASN1ObjectIdentifier.fromComponents(_subjectAltNameOid));
    ext.add(ASN1OctetString(sanBytes));
    return ext;
  }
}
