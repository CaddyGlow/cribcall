import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';

import '../../lib/src/control/http_transport.dart';
import '../../lib/src/identity/device_identity.dart';
import '../../lib/src/identity/identity_repository.dart';
import '../../lib/src/identity/identity_store.dart';
import '../../lib/src/identity/pem.dart';
import '../../lib/src/identity/pkcs8.dart';

void main() {
  runApp(const DebugShellApp());
}

class DebugShellApp extends StatelessWidget {
  const DebugShellApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CribCall Debug Shell',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const DebugShellHome(),
    );
  }
}

class DebugShellHome extends StatefulWidget {
  const DebugShellHome({super.key});

  @override
  State<DebugShellHome> createState() => _DebugShellHomeState();
}

class _DebugShellHomeState extends State<DebugShellHome> {
  DeviceIdentity? _identity;
  String? _identityPath;
  String? _status;
  HttpControlServer? _server;
  int? _port;
  final TextEditingController _portController = TextEditingController(
    text: '43621',
  );
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadIdentity();
  }

  Future<void> _loadIdentity() async {
    setState(() {
      _busy = true;
      _status = 'Loading identity...';
    });
    try {
      final store = IdentityStore.create();
      final repo = IdentityRepository(store: store);
      final identity = await repo.loadOrCreate();
      final path = await _identityFilePath(store);
      setState(() {
        _identity = identity;
        _identityPath = path;
        _status = 'Identity loaded';
      });
    } catch (e) {
      setState(() {
        _status = 'Identity load failed: $e';
      });
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }

  Future<String?> _identityFilePath(IdentityStore store) async {
    if (store is FileIdentityStore) {
      final file = await store.file();
      return file.path;
    }
    return null;
  }

  Future<void> _regenerateIdentity() async {
    setState(() {
      _busy = true;
      _status = 'Regenerating identity...';
    });
    try {
      if (_server != null) {
        await _server!.stop();
        _server = null;
        _port = null;
      }
      if (_identityPath != null) {
        final file = File(_identityPath!);
        if (await file.exists()) {
          await file.delete();
        }
      }
      await _loadIdentity();
    } catch (e) {
      setState(() {
        _status = 'Regeneration failed: $e';
      });
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }

  Future<void> _startServer() async {
    if (_identity == null) return;
    setState(() {
      _busy = true;
      _status = 'Starting HTTP control server...';
    });
    try {
      final server = HttpControlServer(
        bindAddress: '0.0.0.0',
        allowUntrustedClients: false,
      );
      final requestedPort = int.tryParse(_portController.text) ?? 0;
      await server.start(
        port: requestedPort,
        serverIdentity: _identity!,
        trustedListenerFingerprints: const [],
        trustedClientCertificates: [_identity!.certificateDer],
      );
      setState(() {
        _server = server;
        _port = server.boundPort;
        _status = 'Server running on port ${server.boundPort}';
      });
    } catch (e) {
      setState(() {
        _status = 'Server start failed: $e';
      });
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }

  Future<void> _stopServer() async {
    final server = _server;
    if (server == null) return;
    setState(() {
      _busy = true;
      _status = 'Stopping server...';
    });
    try {
      await server.stop();
    } catch (_) {
    } finally {
      setState(() {
        _server = null;
        _port = null;
        _status = 'Server stopped';
        _busy = false;
      });
    }
  }

  Future<void> _hitHealth() async {
    if (_identity == null || _port == null) {
      setState(() {
        _status = 'Start server first';
      });
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Calling /health with client cert...';
    });
    try {
      final ctx = await _buildSecurityContext(_identity!);
      final client = HttpClient(context: ctx);
      client.badCertificateCallback = (cert, host, port) => true;
      final req = await client.getUrl(
        Uri.parse('https://127.0.0.1:${_port}/health'),
      );
      final resp = await req.close();
      final body = await utf8.decodeStream(resp);
      setState(() {
        _status =
            'Health status=${resp.statusCode} body=${body.length > 200 ? body.substring(0, 200) : body}';
      });
      client.close(force: true);
    } catch (e) {
      setState(() {
        _status = 'Health call failed: $e';
      });
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }

  Future<void> _exportClientPem() async {
    if (_identity == null) {
      setState(() {
        _status = 'No identity loaded';
      });
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Exporting client cert/key...';
    });
    try {
      final certPem = encodePem('CERTIFICATE', _identity!.certificateDer);
      final extracted = await _identity!.keyPair.extract();
      final pkcs8 = p256PrivateKeyPkcs8(
        privateKeyBytes: (extracted as SimpleKeyPairData).bytes,
        publicKeyBytes: _identity!.publicKeyUncompressed,
      );
      final keyPem = encodePem('PRIVATE KEY', pkcs8);
      final outDir = Directory(
        '${Platform.environment['HOME']}/.local/share/com.cribcall.cribcall',
      );
      await outDir.create(recursive: true);
      final certPath = '${outDir.path}/client-cert.pem';
      final keyPath = '${outDir.path}/client-key.pem';
      await File(certPath).writeAsString(certPem);
      await File(keyPath).writeAsString(keyPem);
      setState(() {
        _status = 'Exported PEM to:\n$certPath\n$keyPath';
      });
    } catch (e) {
      setState(() {
        _status = 'Export failed: $e';
      });
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }

  Future<SecurityContext> _buildSecurityContext(DeviceIdentity identity) async {
    final ctx = SecurityContext(withTrustedRoots: false);
    final certPem = encodePem('CERTIFICATE', identity.certificateDer);
    final extracted = await identity.keyPair.extract();
    final pkcs8 = p256PrivateKeyPkcs8(
      privateKeyBytes: (extracted as SimpleKeyPairData).bytes,
      publicKeyBytes: identity.publicKeyUncompressed,
    );
    final keyPem = encodePem('PRIVATE KEY', pkcs8);
    ctx.useCertificateChainBytes(utf8.encode(certPem));
    ctx.usePrivateKeyBytes(utf8.encode(keyPem));
    return ctx;
  }

  @override
  Widget build(BuildContext context) {
    final identity = _identity;
    return Scaffold(
      appBar: AppBar(title: const Text('Debug Shell')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_status != null) Text(_status!),
            const SizedBox(height: 12),
            if (identity != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Device ID: ${identity.deviceId}'),
                      Text('Fingerprint: ${identity.certFingerprint}'),
                      if (_identityPath != null) Text('Path: $_identityPath'),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Server port',
                hintText: '43621',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _busy ? null : _loadIdentity,
                  child: const Text('Reload identity'),
                ),
                ElevatedButton(
                  onPressed: _busy ? null : _regenerateIdentity,
                  child: const Text('Regenerate identity'),
                ),
                ElevatedButton(
                  onPressed: _busy ? null : _startServer,
                  child: const Text('Start server'),
                ),
                ElevatedButton(
                  onPressed: _busy ? null : _stopServer,
                  child: const Text('Stop server'),
                ),
                ElevatedButton(
                  onPressed: _busy ? null : _exportClientPem,
                  child: const Text('Export client PEM'),
                ),
                ElevatedButton(
                  onPressed: _busy ? null : _hitHealth,
                  child: const Text('Test health (client mTLS)'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_port != null) Text('Server port: $_port'),
          ],
        ),
      ),
    );
  }
}
