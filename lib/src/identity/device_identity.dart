import 'dart:math';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' as pc;
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
  Uint8List get publicKeyUncompressed => _uncompressedPublicKeyBytes(publicKey);

  static const _ecPublicKeyOid = [1, 2, 840, 10045, 2, 1];
  static const _prime256v1Oid = [1, 2, 840, 10045, 3, 1, 7];
  static const _ecdsaWithSha256Oid = [1, 2, 840, 10045, 4, 3, 2];
  static const _subjectAltNameOid = [2, 5, 29, 17];
  static const _basicConstraintsOid = [2, 5, 29, 19];
  static const _keyUsageOid = [2, 5, 29, 15];
  static const _extendedKeyUsageOid = [2, 5, 29, 37];
  static const _ekuServerAuth = [1, 3, 6, 1, 5, 5, 7, 3, 1];
  static const _ekuClientAuth = [1, 3, 6, 1, 5, 5, 7, 3, 2];

  static Future<DeviceIdentity> generate({String? deviceId}) async {
    final keyMaterial = _generateP256KeyMaterial();
    final id = deviceId ?? const Uuid().v4();
    final certificateDer = await _buildSelfSignedCertificate(
      deviceId: id,
      publicKey: keyMaterial.simplePublicKey,
      privateKey: keyMaterial.privateKey,
    );
    final fingerprint = _fingerprintHex(certificateDer);

    return DeviceIdentity(
      deviceId: id,
      publicKey: keyMaterial.simplePublicKey,
      keyPair: keyMaterial.keyPair,
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
    required pc.ECPrivateKey privateKey,
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

    final algorithmIdentifier = _ecdsaWithSha256AlgorithmIdentifier();
    tbs.add(algorithmIdentifier);

    // Issuer and subject must match for a self-signed certificate
    // to work correctly as its own trust anchor in mTLS validation.
    final subjectName = _buildName('cribcall-$deviceId');
    tbs.add(subjectName); // Issuer

    tbs.add(_buildValidity(notBefore, notAfter));

    tbs.add(subjectName); // Subject (same as issuer for self-signed)

    tbs.add(_buildSubjectPublicKeyInfo(publicKey));

    final extensionsWrapper = ASN1Sequence(tag: 0xa3);
    final extensions = ASN1Sequence();
    extensions.add(_buildBasicConstraintsCaExtension());
    extensions.add(_buildKeyUsageExtension());
    extensions.add(_buildExtendedKeyUsageExtension());
    extensions.add(_buildSubjectAltNameExtension(deviceId));
    extensionsWrapper.add(extensions);
    tbs.add(extensionsWrapper);

    final tbsBytes = Uint8List.fromList(tbs.encodedBytes);
    final signature = _signWithP256(tbsBytes: tbsBytes, privateKey: privateKey);

    final certificate = ASN1Sequence();
    certificate.add(tbs);
    certificate.add(algorithmIdentifier);
    certificate.add(ASN1BitString(_ecdsaDerSignature(signature)));

    return Uint8List.fromList(certificate.encodedBytes);
  }

  static ASN1Sequence _ecdsaWithSha256AlgorithmIdentifier() {
    final sequence = ASN1Sequence();
    sequence.add(ASN1ObjectIdentifier.fromComponents(_ecdsaWithSha256Oid));
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
    final algId = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponents(_ecPublicKeyOid))
      ..add(ASN1ObjectIdentifier.fromComponents(_prime256v1Oid));
    spki.add(algId);
    spki.add(ASN1BitString(_uncompressedPublicKeyBytes(publicKey)));
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

  static ASN1Sequence _buildBasicConstraintsCaExtension() {
    final bcSeq = ASN1Sequence()..add(ASN1Boolean(true));
    final ext = ASN1Sequence();
    ext.add(ASN1ObjectIdentifier.fromComponents(_basicConstraintsOid));
    ext.add(ASN1Boolean(true)); // critical
    ext.add(ASN1OctetString(bcSeq.encodedBytes));
    return ext;
  }

  static ASN1Sequence _buildKeyUsageExtension() {
    // digitalSignature (bit 0 / 0x80), keyCertSign (bit 5 / 0x04)
    final usageBits = Uint8List.fromList([0x84]);
    final bitString = ASN1BitString(usageBits);
    final ext = ASN1Sequence();
    ext.add(ASN1ObjectIdentifier.fromComponents(_keyUsageOid));
    ext.add(ASN1Boolean(true)); // critical
    ext.add(ASN1OctetString(bitString.encodedBytes));
    return ext;
  }

  static ASN1Sequence _buildExtendedKeyUsageExtension() {
    final ekuSeq = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponents(_ekuServerAuth))
      ..add(ASN1ObjectIdentifier.fromComponents(_ekuClientAuth));
    final ext = ASN1Sequence();
    ext.add(ASN1ObjectIdentifier.fromComponents(_extendedKeyUsageOid));
    ext.add(ASN1OctetString(ekuSeq.encodedBytes));
    return ext;
  }

  static Uint8List _ecdsaDerSignature(List<int> rawSignature) {
    if (rawSignature.length != 64) {
      throw ArgumentError.value(
        rawSignature.length,
        'rawSignature.length',
        'Expected 64-byte raw P-256 signature (r||s)',
      );
    }
    final r = rawSignature.sublist(0, 32);
    final s = rawSignature.sublist(32);
    final seq = ASN1Sequence()
      ..add(ASN1Integer(BigInt.parse(_bytesToHex(r), radix: 16)))
      ..add(ASN1Integer(BigInt.parse(_bytesToHex(s), radix: 16)));
    return Uint8List.fromList(seq.encodedBytes);
  }

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _uncompressedPublicKeyBytes(SimplePublicKey publicKey) {
    final bytes = publicKey.bytes;
    if (bytes.isNotEmpty && bytes.first == 0x04) {
      return Uint8List.fromList(bytes);
    }
    if (bytes.length == 64) {
      return Uint8List.fromList([0x04, ...bytes]);
    }
    return Uint8List.fromList(bytes);
  }

  static SimplePublicKey _simpleFromEcPublicKey(EcPublicKey ecPublicKey) {
    final x = _ensureLength(ecPublicKey.x, 32);
    final y = _ensureLength(ecPublicKey.y, 32);
    final uncompressed = Uint8List.fromList([0x04, ...x, ...y]);
    return SimplePublicKey(uncompressed, type: KeyPairType.p256);
  }

  static _P256KeyMaterial _generateP256KeyMaterial() {
    final domain = pc.ECDomainParameters('prime256v1');
    final generator = pc.ECKeyGenerator()
      ..init(
        pc.ParametersWithRandom(
          pc.ECKeyGeneratorParameters(domain),
          _secureRandom(),
        ),
      );
    final pair = generator.generateKeyPair();
    final privateKey = pair.privateKey as pc.ECPrivateKey;
    final publicKey = pair.publicKey as pc.ECPublicKey;
    final uncompressed = _encodeEcPoint(publicKey.Q!);
    final simplePublicKey = SimplePublicKey(
      uncompressed,
      type: KeyPairType.p256,
    );
    final privateBytes = _bigIntToFixedLength(privateKey.d!, 32);
    final simpleKeyPair = SimpleKeyPairData(
      privateBytes,
      publicKey: simplePublicKey,
      type: KeyPairType.p256,
    );
    return _P256KeyMaterial(
      simplePublicKey: simplePublicKey,
      keyPair: simpleKeyPair,
      privateKey: privateKey,
    );
  }

  static Uint8List _signWithP256({
    required Uint8List tbsBytes,
    required pc.ECPrivateKey privateKey,
  }) {
    final signer = pc.Signer('SHA-256/ECDSA');
    signer.init(
      true,
      pc.ParametersWithRandom(
        pc.PrivateKeyParameter<pc.ECPrivateKey>(privateKey),
        _secureRandom(),
      ),
    );
    final sig = signer.generateSignature(tbsBytes) as pc.ECSignature;
    final r = _bigIntToFixedLength(sig.r, 32);
    final s = _bigIntToFixedLength(sig.s, 32);
    return Uint8List.fromList([...r, ...s]);
  }

  static Uint8List _encodeEcPoint(pc.ECPoint point) {
    final x = _bigIntToFixedLength(point.x!.toBigInteger()!, 32);
    final y = _bigIntToFixedLength(point.y!.toBigInteger()!, 32);
    return Uint8List.fromList([0x04, ...x, ...y]);
  }

  static Uint8List _bigIntToFixedLength(BigInt value, int length) {
    final hex = value
        .toUnsigned(length * 8)
        .toRadixString(16)
        .padLeft(length * 2, '0');
    final result = Uint8List(length);
    for (var i = 0; i < length; i++) {
      final start = i * 2;
      result[i] = int.parse(hex.substring(start, start + 2), radix: 16);
    }
    return result;
  }

  static pc.SecureRandom _secureRandom() {
    final random = pc.FortunaRandom();
    final seed = Uint8List(32);
    final rng = Random.secure();
    for (var i = 0; i < seed.length; i++) {
      seed[i] = rng.nextInt(256);
    }
    random.seed(pc.KeyParameter(seed));
    return random;
  }

  static List<int> _ensureLength(List<int> bytes, int length) {
    if (bytes.length == length) return List<int>.from(bytes);
    if (bytes.length > length) {
      return bytes.sublist(bytes.length - length);
    }
    final padding = List<int>.filled(length - bytes.length, 0);
    return [...padding, ...bytes];
  }
}

class _P256KeyMaterial {
  _P256KeyMaterial({
    required this.simplePublicKey,
    required this.keyPair,
    required this.privateKey,
  });

  final SimplePublicKey simplePublicKey;
  final SimpleKeyPairData keyPair;
  final pc.ECPrivateKey privateKey;
}
