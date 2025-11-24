import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';

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
    return _events
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map(
          (event) =>
              MdnsAdvertisement.fromJson(Map<String, dynamic>.from(event)),
        );
  }

  @override
  Future<void> startAdvertise(MdnsAdvertisement advertisement) async {
    await _method.invokeMethod('startAdvertise', advertisement.toJson());
  }

  @override
  Future<void> stop() async {
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
      yield MdnsAdvertisement(
        monitorId: monitorId,
        monitorName: monitorName,
        monitorCertFingerprint: fingerprint,
        servicePort: srv.port,
        version: int.tryParse(attributes['version'] ?? '1') ?? 1,
        ip: addressRecord?.address.address,
      );
    }
  }

  @override
  Future<void> startAdvertise(MdnsAdvertisement advertisement) async {
    // Use avahi-publish-service if available.
    try {
      _advertiseProcess = await Process.start('avahi-publish-service', [
        '${advertisement.monitorName}-${advertisement.monitorId}',
        '_baby-monitor._tcp',
        advertisement.servicePort.toString(),
        'monitorId=${advertisement.monitorId}',
        'monitorName=${advertisement.monitorName}',
        'monitorCertFingerprint=${advertisement.monitorCertFingerprint}',
        'version=${advertisement.version}',
      ]);
    } catch (_) {
      // Ignore if avahi is unavailable.
    }
  }

  @override
  Future<void> stop() async {
    _client.stop();
    _advertiseProcess?.kill(ProcessSignal.sigterm);
    _advertiseProcess = null;
  }
}
