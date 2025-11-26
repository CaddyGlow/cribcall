import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';

import '../config/build_flags.dart';
import '../domain/models.dart';

/// Abstraction for mDNS/UPnP discovery and advertisement.

abstract class MdnsService {
  Stream<MdnsAdvertisement> browse();

  Future<void> startAdvertise(MdnsAdvertisement advertisement);

  Future<void> stop();
}

/// Temporary no-op implementation until platform channel code lands.
class NoopMdnsService implements MdnsService {
  @override
  Stream<MdnsAdvertisement> browse() => const Stream.empty();

  @override
  Future<void> startAdvertise(MdnsAdvertisement advertisement) async {}

  @override
  Future<void> stop() async {}
}

class MethodChannelMdnsService implements MdnsService {
  MethodChannelMdnsService({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _method = methodChannel ?? const MethodChannel('cribcall/mdns'),
       _events = eventChannel ?? const EventChannel('cribcall/mdns_events');

  final MethodChannel _method;
  final EventChannel _events;

  @override
  Stream<MdnsAdvertisement> browse() {
    developer.log('Starting platform mDNS browse stream', name: 'mdns');
    return _events
        .receiveBroadcastStream()
        .handleError(
          (Object error, _) =>
              developer.log('mDNS browse error: $error', name: 'mdns'),
        )
        .where((event) => event is Map)
        .map(
          (event) =>
              MdnsAdvertisement.fromJson(Map<String, dynamic>.from(event)),
        );
  }

  @override
  Future<void> startAdvertise(MdnsAdvertisement advertisement) async {
    developer.log(
      'Starting platform mDNS advertise '
      'monitorId=${advertisement.monitorId} '
      'controlPort=${advertisement.controlPort} '
      'pairingPort=${advertisement.pairingPort} '
      'fp=${_shortFingerprint(advertisement.monitorCertFingerprint)}',
      name: 'mdns',
    );
    await _method.invokeMethod('startAdvertise', advertisement.toJson());
  }

  @override
  Future<void> stop() async {
    developer.log('Stopping platform mDNS advertise/browse', name: 'mdns');
    await _method.invokeMethod('stop');
  }
}

/// Desktop (Linux) fallback using multicast_dns and avahi-publish-service when available.
class DesktopMdnsService implements MdnsService {
  DesktopMdnsService({MDnsClient? client}) : _client = client ?? MDnsClient();

  final MDnsClient _client;
  Process? _advertiseProcess;

  static const _serviceType = '_baby-monitor._tcp.local';

  @override
  Stream<MdnsAdvertisement> browse() async* {
    developer.log('Starting desktop mDNS browse', name: 'mdns');
    await _client.start();
    await for (final PtrResourceRecord ptr in _client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer(_serviceType),
    )) {
      final domain = ptr.domainName;
      SrvResourceRecord? srv;
      await for (final record in _client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(domain),
      )) {
        srv = record;
        break;
      }
      if (srv == null) continue;

      final attributes = <String, String>{};
      await for (final record in _client.lookup<TxtResourceRecord>(
        ResourceRecordQuery.text(domain),
      )) {
        final parts = record.text.split('=');
        if (parts.length == 2) {
          attributes[parts[0]] = parts[1];
        }
      }
      IPAddressResourceRecord? addressRecord;
      await for (final record in _client.lookup<IPAddressResourceRecord>(
        ResourceRecordQuery.addressIPv4(srv.target),
      )) {
        addressRecord = record;
        break;
      }
      final monitorId = attributes['monitorId'] ?? srv.target;
      final monitorName = attributes['monitorName'] ?? srv.target;
      final fingerprint = attributes['monitorCertFingerprint'] ?? '';
      final transport = attributes['transport'] ?? kTransportHttpWs;
      final controlPortAttr = int.tryParse(attributes['controlPort'] ?? '') ?? srv.port;
      final pairingPortAttr = int.tryParse(attributes['pairingPort'] ?? '') ?? kPairingDefaultPort;
      developer.log(
        'mDNS found monitor=$monitorId ip=${addressRecord?.address.address ?? 'unknown'} '
        'controlPort=$controlPortAttr pairingPort=$pairingPortAttr transport=$transport '
        'fp=${_shortFingerprint(fingerprint)}',
        name: 'mdns',
      );
      yield MdnsAdvertisement(
        monitorId: monitorId,
        monitorName: monitorName,
        monitorCertFingerprint: fingerprint,
        controlPort: controlPortAttr,
        pairingPort: pairingPortAttr,
        version: int.tryParse(attributes['version'] ?? '1') ?? 1,
        transport: transport,
        ip: addressRecord?.address.address,
      );
    }
  }

  @override
  Future<void> startAdvertise(MdnsAdvertisement advertisement) async {
    // Use avahi-publish-service if available.
    try {
      developer.log(
        'Publishing desktop mDNS monitorId=${advertisement.monitorId} '
        'controlPort=${advertisement.controlPort} pairingPort=${advertisement.pairingPort} '
        'fp=${_shortFingerprint(advertisement.monitorCertFingerprint)}',
        name: 'mdns',
      );
      _advertiseProcess = await Process.start('avahi-publish-service', [
        '${advertisement.monitorName}-${advertisement.monitorId}',
        '_baby-monitor._tcp',
        advertisement.controlPort.toString(),
        'monitorId=${advertisement.monitorId}',
        'monitorName=${advertisement.monitorName}',
        'monitorCertFingerprint=${advertisement.monitorCertFingerprint}',
        'controlPort=${advertisement.controlPort}',
        'pairingPort=${advertisement.pairingPort}',
        'version=${advertisement.version}',
        'transport=${advertisement.transport}',
      ]);
    } catch (e) {
      developer.log(
        'avahi-publish-service unavailable or failed: $e',
        name: 'mdns',
      );
      // Ignore if avahi is unavailable.
    }
  }

  @override
  Future<void> stop() async {
    developer.log('Stopping desktop mDNS advertise/browse', name: 'mdns');
    _client.stop();
    _advertiseProcess?.kill(ProcessSignal.sigterm);
    _advertiseProcess = null;
  }
}

String _shortFingerprint(String fingerprint) {
  if (fingerprint.length <= 12) return fingerprint;
  final prefix = fingerprint.substring(0, 6);
  final suffix = fingerprint.substring(fingerprint.length - 4);
  return '$prefix...$suffix';
}
