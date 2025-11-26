import 'dart:async';
import 'dart:io';

import 'package:cribcall/src/cli/cli_harness.dart';
import 'package:cribcall/src/config/build_flags.dart';
import 'package:cribcall/src/identity/identity_repository.dart';
import 'package:cribcall/src/identity/service_identity.dart';
import 'package:cribcall/src/storage/trusted_listeners_repository.dart';

void main(List<String> args) async {
  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    _printUsage();
    exit(0);
  }

  final command = args.first;
  final rest = args.skip(1).toList();

  switch (command) {
    case 'monitor':
      await _runMonitor(rest);
      break;
    case 'listener':
      await _runListener(rest);
      break;
    default:
      stderr.writeln('Unknown command "$command".');
      _printUsage();
      exit(64);
  }
}

Future<void> _runMonitor(List<String> args) async {
  final options = _parseOptions(args);
  final controlPort =
      int.tryParse(options['control-port'] ?? options['port'] ?? '') ??
          kControlDefaultPort;
  final pairingPort =
      int.tryParse(options['pairing-port'] ?? '') ?? kPairingDefaultPort;
  final dataDir = options['data-dir'] ?? _defaultDataDir('monitor');
  final monitorName = options['name'] ?? 'CLI Monitor';
  void logger(String msg) => stdout.writeln('[monitor] $msg');

  final identityRepo = IdentityRepository(overrideDirectoryPath: dataDir);
  final identity = await identityRepo.loadOrCreate();

  final trustedRepo = TrustedListenersRepository(
    overrideDirectoryPath: dataDir,
  );
  final trustedPeers = await trustedRepo.load();

  final harness = MonitorCliHarness(
    identity: identity,
    monitorName: monitorName,
    controlPort: controlPort,
    pairingPort: pairingPort,
    trustedPeers: trustedPeers,
    logger: logger,
    onTrustedListener: (peer) async {
      if (trustedPeers.any((p) => p.deviceId == peer.deviceId)) return;
      trustedPeers.add(peer);
      await trustedRepo.save(List.of(trustedPeers));
      logger(
        'Trusted listener persisted id=${peer.deviceId} '
        'fingerprint=${_shortFp(peer.certFingerprint)} '
        'total=${trustedPeers.length}',
      );
    },
  );

  await harness.start();
  final boundControlPort = harness.boundControlPort ?? controlPort;
  final boundPairingPort = harness.boundPairingPort ?? pairingPort;

  final serviceBuilder = ServiceIdentityBuilder(
    serviceProtocol: 'baby-monitor',
    serviceVersion: 1,
    defaultPort: boundControlPort,
    defaultPairingPort: boundPairingPort,
    transport: kDefaultControlTransport,
  );
  final qrPayload = serviceBuilder.qrPayloadString(
    identity: identity,
    monitorName: monitorName,
  );

  stdout
    ..writeln('Monitor identity: ${identity.deviceId}')
    ..writeln('Fingerprint: ${identity.certFingerprint}')
    ..writeln('Control port: $boundControlPort (mTLS WebSocket)')
    ..writeln('Pairing port: $boundPairingPort (TLS HTTP)')
    ..writeln('Transport: $kDefaultControlTransport')
    ..writeln('QR payload (canonical JSON):\n$qrPayload')
    ..writeln(
      'Listener example (direct connect, already trusted):\n'
      '  flutter pub run tool/control_cli.dart listener '
      '--host <ip> --control-port $boundControlPort '
      '--fingerprint ${identity.certFingerprint}\n',
    )
    ..writeln(
      'Listener example (pairing with PIN):\n'
      '  flutter pub run tool/control_cli.dart listener '
      '--host <ip> --control-port $boundControlPort --pairing-port $boundPairingPort '
      '--fingerprint ${identity.certFingerprint} --pin <6-digit>\n',
    )
    ..writeln('Press Ctrl+C to stop.');

  await _waitForSignal();
  stdout.writeln('Stopping monitor...');
  await harness.stop();
}

Future<void> _runListener(List<String> args) async {
  final options = _parseOptions(args);
  final host = options['host'];
  final fingerprint = options['fingerprint'] ?? '';
  final pin = options['pin'];

  if (host == null || host.isEmpty) {
    stderr.writeln('Missing required option: --host <monitor_ip>');
    _printUsage();
    exit(64);
  }

  if (fingerprint.isEmpty) {
    stderr.writeln('Missing required option: --fingerprint <hex>');
    _printUsage();
    exit(64);
  }

  final controlPort =
      int.tryParse(options['control-port'] ?? options['port'] ?? '') ??
          kControlDefaultPort;
  final pairingPort =
      int.tryParse(options['pairing-port'] ?? '') ?? kPairingDefaultPort;
  final dataDir = options['data-dir'] ?? _defaultDataDir('listener');
  final listenerName = options['name'] ?? 'CLI Listener';
  final sendPing = _boolOpt(options, 'ping');
  void logger(String msg) => stdout.writeln('[listener] $msg');

  final identityRepo = IdentityRepository(overrideDirectoryPath: dataDir);
  final identity = await identityRepo.loadOrCreate();

  final harness = ListenerCliHarness(
    identity: identity,
    monitorHost: host,
    monitorControlPort: controlPort,
    monitorPairingPort: pairingPort,
    monitorFingerprint: fingerprint,
    listenerName: listenerName,
    logger: logger,
  );

  ListenerRunResult result;
  if (pin != null && pin.isNotEmpty) {
    // Legacy PIN provided - use numeric comparison with auto-confirm
    // In CLI mode, we auto-confirm and display the comparison code
    result = await harness.pairAndConnect(
      onComparisonCode: (code) async {
        stdout.writeln('Comparison code: $code');
        stdout.writeln('Auto-confirming pairing in CLI mode...');
        return true;
      },
      sendPingAfterConnect: sendPing,
    );
  } else if (fingerprint.isEmpty) {
    // No fingerprint means pairing mode
    result = await harness.pairAndConnect(
      onComparisonCode: (code) async {
        stdout.writeln('Comparison code: $code');
        stdout.write('Does this match the monitor display? (y/n): ');
        final response = stdin.readLineSync()?.toLowerCase() ?? 'n';
        return response == 'y' || response == 'yes';
      },
      sendPingAfterConnect: sendPing,
    );
  } else {
    // Direct connect (already trusted)
    result = await harness.connect(sendPingAfterConnect: sendPing);
  }

  if (!result.ok) {
    stderr.writeln('Failed to connect/pair: ${result.error ?? 'unknown error'}');
    await harness.stop();
    exit(1);
  }

  final connectedFp = (result.peerFingerprint ?? fingerprint).trim();
  stdout
    ..writeln('Connected to $host:$controlPort')
    ..writeln(
      'Monitor fingerprint: ${connectedFp.isEmpty ? 'unknown' : connectedFp}',
    )
    ..writeln('Listener id: ${identity.deviceId}')
    ..writeln('Ctrl+C to stop; awaiting control messages...');

  await _waitForSignal();
  stdout.writeln('Stopping listener...');
  await harness.stop();
}

Map<String, String> _parseOptions(List<String> args) {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) continue;
    final trimmed = arg.substring(2);
    final eq = trimmed.indexOf('=');
    if (eq != -1) {
      options[trimmed.substring(0, eq)] = trimmed.substring(eq + 1);
      continue;
    }
    final hasValue = i + 1 < args.length && !args[i + 1].startsWith('-');
    if (hasValue) {
      options[trimmed] = args[i + 1];
      i++;
    } else {
      options[trimmed] = 'true';
    }
  }
  return options;
}

String _defaultDataDir(String role) {
  final root = Platform.environment['CRIBCALL_CLI_HOME'];
  if (root != null && root.isNotEmpty) return '$root/$role';
  return '${Directory.current.path}/.dart_tool/cribcall_cli/$role';
}

bool _boolOpt(Map<String, String> options, String key) {
  if (!options.containsKey(key)) return false;
  final value = options[key]?.toLowerCase();
  return value == null ||
      value.isEmpty ||
      value == 'true' ||
      value == '1' ||
      value == 'yes';
}

Future<void> _waitForSignal() async {
  final completer = Completer<void>();
  final subSigint = ProcessSignal.sigint.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });
  final subSigterm = ProcessSignal.sigterm.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });
  await completer.future;
  await subSigint.cancel();
  await subSigterm.cancel();
}

String _shortFp(String fingerprint) {
  if (fingerprint.length <= 12) return fingerprint;
  final prefix = fingerprint.substring(0, 6);
  final suffix = fingerprint.substring(fingerprint.length - 4);
  return '$prefix...$suffix';
}

void _printUsage() {
  stdout.writeln('CribCall control CLI (two-port architecture)');
  stdout.writeln(
    'Usage: flutter pub run tool/control_cli.dart <command> [options]',
  );
  stdout.writeln('Commands:');
  stdout.writeln(
    '  monitor  [--control-port <port>] [--pairing-port <port>] '
    '[--data-dir <path>] [--name <Monitor Name>]',
  );
  stdout.writeln(
    '  listener --host <ip> --fingerprint <hex> '
    '[--control-port <port>] [--pairing-port <port>] '
    '[--pin <6-digit>] [--data-dir <path>] [--name <Listener Name>] [--ping]',
  );
  stdout.writeln('\nNotes:');
  stdout.writeln(
    '  - If --pin is provided, pairing will be performed via HTTP RPC',
  );
  stdout.writeln(
    '  - Without --pin, direct mTLS connection (must be already trusted)',
  );
}
