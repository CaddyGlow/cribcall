import 'dart:developer' as developer;
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:cribcall_quic/cribcall_quic.dart';

import '../../identity/device_identity.dart';
import '../../identity/pem.dart';
import '../../identity/pkcs8.dart';

class QuicheLibrary {
  QuicheLibrary({CribcallQuic? native}) : _native = native ?? CribcallQuic();

  final CribcallQuic _native;

  Future<QuicheConnectionResources> startClient({
    required String host,
    required int port,
    required String expectedServerFingerprint,
    required DeviceIdentity identity,
  }) async {
    _logQuic(
      'Starting QUIC client to $host:$port '
      '(expected server fp ${_shortFingerprint(expectedServerFingerprint)})',
    );
    _native.initLogging();
    final identityFiles = await _writeIdentity(identity);
    final config = _native.createConfig();
    final connection = await _native.startClient(
      config: config,
      host: host,
      port: port,
      serverName: host,
      expectedServerFingerprint: expectedServerFingerprint,
      certPemPath: identityFiles.certPath,
      keyPemPath: identityFiles.keyPath,
    );
    _logQuic(
      'QUIC client handle=${connection.handle} using identity dir '
      '${identityFiles.dir.path}',
    );
    return QuicheConnectionResources(
      native: connection,
      identityDir: identityFiles.dir,
    );
  }

  Future<QuicheConnectionResources> startServer({
    required int port,
    required DeviceIdentity identity,
    String bindAddress = '0.0.0.0',
    List<String> trustedFingerprints = const [],
  }) async {
    _logQuic(
      'Starting QUIC server on $bindAddress:$port '
      '(trusted allowlist count=${trustedFingerprints.length})',
    );
    _native.initLogging();
    final identityFiles = await _writeIdentity(identity);
    final config = _native.createConfig();
    final connection = await _native.startServer(
      config: config,
      bindAddress: bindAddress,
      port: port,
      certPemPath: identityFiles.certPath,
      keyPemPath: identityFiles.keyPath,
      trustedFingerprints: trustedFingerprints,
    );
    _logQuic(
      'QUIC server handle=${connection.handle} using identity dir '
      '${identityFiles.dir.path}',
    );
    return QuicheConnectionResources(
      native: connection,
      identityDir: identityFiles.dir,
    );
  }

  Future<_IdentityFiles> _writeIdentity(DeviceIdentity identity) async {
    final dir = await Directory.systemTemp.createTemp('cribcall-quic-');
    final certPem = encodePem('CERTIFICATE', identity.certificateDer);
    final certPath = '${dir.path}/identity.crt';
    await File(certPath).writeAsString(certPem, flush: true);

    final extracted = await identity.keyPair.extract() as SimpleKeyPairData;
    final pkcs8 = ed25519PrivateKeyPkcs8(extracted.bytes);
    final keyPem = encodePem('PRIVATE KEY', pkcs8);
    final keyPath = '${dir.path}/identity.key';
    await File(keyPath).writeAsString(keyPem, flush: true);

    return _IdentityFiles(certPath: certPath, keyPath: keyPath, dir: dir);
  }
}

class QuicheConnectionResources {
  QuicheConnectionResources({required this.native, required this.identityDir});

  final QuicNativeConnection native;
  final Directory identityDir;
}

class _IdentityFiles {
  _IdentityFiles({
    required this.certPath,
    required this.keyPath,
    required this.dir,
  });

  final String certPath;
  final String keyPath;
  final Directory dir;
}

void _logQuic(String message) {
  developer.log(message, name: 'quiche');
}

String _shortFingerprint(String fingerprint) {
  if (fingerprint.length <= 12) {
    return fingerprint;
  }
  final prefix = fingerprint.substring(0, 6);
  final suffix = fingerprint.substring(fingerprint.length - 4);
  return '$prefix...$suffix';
}
