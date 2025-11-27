import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/build_flags.dart';
import '../domain/models.dart';

void _mdnsLog(String message) {
  developer.log(message, name: 'mdns');
  debugPrint('[mdns] $message');
}

/// Abstraction for mDNS/UPnP discovery and advertisement.

abstract class MdnsService {
  /// Browse for services. Emits [MdnsEvent] with online/offline status.
  Stream<MdnsEvent> browse();

  Future<void> startAdvertise(MdnsAdvertisement advertisement);

  Future<void> stop();
}

/// Temporary no-op implementation until platform channel code lands.
class NoopMdnsService implements MdnsService {
  @override
  Stream<MdnsEvent> browse() => const Stream.empty();

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
  Stream<MdnsEvent> browse() {
    _mdnsLog('MethodChannelMdnsService.browse() starting platform stream');
    return _events
        .receiveBroadcastStream()
        .handleError(
          (Object error, _) =>
              _mdnsLog('mDNS browse error: $error'),
        )
        .where((event) {
          final isMap = event is Map;
          if (!isMap) {
            _mdnsLog('mDNS browse: ignoring non-Map event: ${event.runtimeType}');
          }
          return isMap;
        })
        .map((event) {
          final map = Map<String, dynamic>.from(event as Map);
          final isOnline = map['isOnline'] as bool? ?? true;
          final advertisement = MdnsAdvertisement.fromJson(map);
          _mdnsLog(
            'Platform mDNS event: ${isOnline ? "ONLINE" : "OFFLINE"} '
            'monitorId=${advertisement.monitorId} ip=${advertisement.ip}',
          );
          return MdnsEvent(advertisement: advertisement, isOnline: isOnline);
        });
  }

  @override
  Future<void> startAdvertise(MdnsAdvertisement advertisement) async {
    _mdnsLog(
      'MethodChannelMdnsService.startAdvertise() '
      'monitorId=${advertisement.monitorId} '
      'controlPort=${advertisement.controlPort} '
      'pairingPort=${advertisement.pairingPort} '
      'fp=${_shortFingerprint(advertisement.monitorCertFingerprint)}',
    );
    await _method.invokeMethod('startAdvertise', advertisement.toJson());
  }

  @override
  Future<void> stop() async {
    _mdnsLog('MethodChannelMdnsService.stop()');
    await _method.invokeMethod('stop');
  }
}

/// Desktop (Linux) using raw multicast sockets for continuous mDNS listening
/// and avahi-publish-service for advertising.
class DesktopMdnsService implements MdnsService {
  RawDatagramSocket? _socket;
  Process? _advertiseProcess;
  StreamController<MdnsEvent>? _browseController;

  // Cache instanceName -> monitorId for goodbye packets
  final _instanceToMonitorId = <String, String>{};

  static const _mdnsAddress = '224.0.0.251';
  static const _mdnsPort = 5353;
  static const _serviceType = '_baby-monitor._tcp.local';

  @override
  Stream<MdnsEvent> browse() {
    _mdnsLog('DesktopMdnsService.browse() called - starting raw socket continuous mode');
    final controller = StreamController<MdnsEvent>.broadcast(
      onListen: () {
        _mdnsLog('mDNS browse stream: first listener attached');
      },
      onCancel: () {
        _mdnsLog('mDNS browse stream: all listeners cancelled');
        _socket?.close();
        _socket = null;
        _browseController = null;
      },
    );
    _browseController = controller;

    // Track seen services to avoid duplicates within a time window
    final seenServices = <String, DateTime>{};
    const dedupeWindow = Duration(seconds: 30);

    _startListening(controller, seenServices, dedupeWindow);

    return controller.stream;
  }

  Future<void> _startListening(
    StreamController<MdnsEvent> controller,
    Map<String, DateTime> seenServices,
    Duration dedupeWindow,
  ) async {
    _mdnsLog('_startListening() called');
    try {
      // Bind to mDNS port with reuseAddress and reusePort
      _mdnsLog('Binding to 0.0.0.0:$_mdnsPort with reuseAddress/reusePort');
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _mdnsPort,
        reuseAddress: true,
        reusePort: true,
      );
      _mdnsLog('Socket bound successfully');

      // Join multicast group
      final mdnsGroup = InternetAddress(_mdnsAddress);
      _mdnsLog('Joining multicast group $_mdnsAddress');
      _socket!.joinMulticast(mdnsGroup);
      _socket!.multicastLoopback = true;

      _mdnsLog('SUCCESS: Joined mDNS multicast group $_mdnsAddress:$_mdnsPort');

      // Send initial query for our service type
      _sendQuery();

      // Also send periodic queries to catch services that don't announce
      Timer.periodic(const Duration(seconds: 30), (timer) {
        if (_socket == null || controller.isClosed) {
          _mdnsLog('Stopping periodic query timer');
          timer.cancel();
          return;
        }
        _sendQuery();
      });

      _mdnsLog('Starting socket listen loop');
      _socket!.listen(
        (event) {
          if (event == RawSocketEvent.read) {
            final datagram = _socket!.receive();
            if (datagram != null) {
              _handleMdnsPacket(
                datagram.data,
                datagram.address,
                controller,
                seenServices,
                dedupeWindow,
              );
            }
          }
        },
        onError: (error) {
          _mdnsLog('mDNS socket error: $error');
        },
        onDone: () {
          _mdnsLog('mDNS socket closed');
        },
      );
      _mdnsLog('Socket listen loop started');
    } catch (e, stack) {
      _mdnsLog('FAILED to start mDNS listener: $e\n$stack');
      // Don't close controller, allow retry
    }
  }

  void _sendQuery() {
    if (_socket == null) return;

    try {
      // Build a DNS query for PTR record of _baby-monitor._tcp.local
      final query = _buildPtrQuery(_serviceType);
      _socket!.send(query, InternetAddress(_mdnsAddress), _mdnsPort);
      _mdnsLog('Sent mDNS query for $_serviceType');
    } catch (e) {
      _mdnsLog('Failed to send mDNS query: $e');
    }
  }

  Uint8List _buildPtrQuery(String serviceName) {
    final buffer = BytesBuilder();

    // Transaction ID (2 bytes) - 0 for mDNS
    buffer.add([0x00, 0x00]);
    // Flags (2 bytes) - standard query
    buffer.add([0x00, 0x00]);
    // Questions (2 bytes) - 1 question
    buffer.add([0x00, 0x01]);
    // Answer RRs, Authority RRs, Additional RRs (6 bytes) - all 0
    buffer.add([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);

    // Question: serviceName as DNS name
    _writeDnsName(buffer, serviceName);

    // Type PTR (12)
    buffer.add([0x00, 0x0c]);
    // Class IN with QU bit set for unicast response
    buffer.add([0x80, 0x01]);

    return Uint8List.fromList(buffer.toBytes());
  }

  void _writeDnsName(BytesBuilder buffer, String name) {
    final labels = name.split('.');
    for (final label in labels) {
      if (label.isEmpty) continue;
      final bytes = label.codeUnits;
      buffer.addByte(bytes.length);
      buffer.add(bytes);
    }
    buffer.addByte(0); // Null terminator
  }

  void _handleMdnsPacket(
    Uint8List data,
    InternetAddress source,
    StreamController<MdnsEvent> controller,
    Map<String, DateTime> seenServices,
    Duration dedupeWindow,
  ) {
    if (data.length < 12) return; // Too short for DNS header

    try {
      final parsed = _MdnsParser(data);
      final records = parsed.parse();

      // Log all record types for debugging
      final recordSummary = records
          .map((r) => '${r.type.name}:${r.name}(ttl=${r.ttl})')
          .join(', ');
      if (records.any((r) =>
          r.name.toLowerCase().contains('_baby-monitor') ||
          r.name.toLowerCase().contains('cribcall'))) {
        _mdnsLog('mDNS packet from ${source.address}: $recordSummary');
      }

      // Find PTR records for our service type
      for (final record in records) {
        if (record.type == _DnsRecordType.ptr &&
            record.name.toLowerCase().contains('_baby-monitor._tcp')) {
          // Found a PTR record, now find corresponding SRV, TXT, and A records
          final instanceName = record.ptrDomain;
          if (instanceName == null) continue;

          // Check if this is a goodbye packet (TTL=0 on PTR record)
          final isGoodbye = record.ttl == 0;
          _mdnsLog(
            'mDNS PTR record: instance=$instanceName ttl=${record.ttl} '
            'isGoodbye=$isGoodbye',
          );

          _MdnsRecord? srvRecord;
          _MdnsRecord? txtRecord;
          _MdnsRecord? aRecord;

          for (final r in records) {
            if (r.name == instanceName) {
              if (r.type == _DnsRecordType.srv) srvRecord = r;
              if (r.type == _DnsRecordType.txt) txtRecord = r;
            }
            // A record might be for the target hostname
            if (r.type == _DnsRecordType.a) {
              if (srvRecord?.srvTarget != null &&
                  r.name == srvRecord!.srvTarget) {
                aRecord = r;
              }
            }
          }

          // For goodbye packets, we may not have full records, but we need
          // to extract what we can from the instance name
          if (isGoodbye) {
            // Parse TXT attributes if available, or use cached monitorId
            final attrs = txtRecord?.txtAttributes ?? {};
            final cachedMonitorId = _instanceToMonitorId[instanceName];
            final monitorId = attrs['monitorId'] ?? cachedMonitorId ?? instanceName;
            final monitorName = attrs['monitorName'] ?? instanceName;
            final fingerprint = attrs['monitorCertFingerprint'] ?? '';
            final ip = aRecord?.aAddress ?? source.address;

            _mdnsLog(
              'mDNS GOODBYE (offline) instance=$instanceName '
              'monitorId=$monitorId cachedId=$cachedMonitorId ip=$ip '
              'controllerClosed=${controller.isClosed}',
            );

            // Remove from caches
            _instanceToMonitorId.remove(instanceName);
            final keyPrefix = '$monitorId:';
            seenServices.removeWhere((key, _) => key.startsWith(keyPrefix));

            if (!controller.isClosed) {
              _mdnsLog('Emitting OFFLINE MdnsEvent for $monitorId');
              controller.add(MdnsEvent.offline(MdnsAdvertisement(
                monitorId: monitorId,
                monitorName: monitorName,
                monitorCertFingerprint: fingerprint,
                controlPort: srvRecord?.srvPort ?? kControlDefaultPort,
                pairingPort: kPairingDefaultPort,
                version: 1,
                ip: ip,
              )));
            }
            continue;
          }

          if (srvRecord == null) continue;

          // Also look for A record matching SRV target
          if (aRecord == null && srvRecord.srvTarget != null) {
            for (final r in records) {
              if (r.type == _DnsRecordType.a &&
                  r.name == srvRecord.srvTarget) {
                aRecord = r;
                break;
              }
            }
          }

          // Parse TXT attributes
          final attrs = txtRecord?.txtAttributes ?? {};
          final monitorId = attrs['monitorId'] ?? instanceName;
          final monitorName = attrs['monitorName'] ?? instanceName;
          final fingerprint = attrs['monitorCertFingerprint'] ?? '';
          final transport = attrs['transport'] ?? kTransportHttpWs;
          final controlPort = int.tryParse(attrs['controlPort'] ?? '') ??
              srvRecord.srvPort ??
              kControlDefaultPort;
          final pairingPort = int.tryParse(attrs['pairingPort'] ?? '') ??
              kPairingDefaultPort;
          final version = int.tryParse(attrs['version'] ?? '1') ?? 1;
          final ip = aRecord?.aAddress ?? source.address;

          // Cache instanceName -> monitorId for goodbye packets
          _instanceToMonitorId[instanceName] = monitorId;

          // Dedupe check (only for online events)
          final key = '$monitorId:$ip:$controlPort';
          final now = DateTime.now();
          final lastSeen = seenServices[key];
          if (lastSeen != null && now.difference(lastSeen) < dedupeWindow) {
            continue;
          }
          seenServices[key] = now;

          // Clean up old entries
          seenServices.removeWhere(
            (_, time) => now.difference(time) > dedupeWindow,
          );

          _mdnsLog(
            'mDNS ONLINE monitor=$monitorId instance=$instanceName ip=$ip '
            'controlPort=$controlPort pairingPort=$pairingPort '
            'transport=$transport fp=${_shortFingerprint(fingerprint)} '
            'controllerClosed=${controller.isClosed}',
          );

          if (!controller.isClosed) {
            _mdnsLog('Emitting ONLINE MdnsEvent for $monitorId');
            controller.add(MdnsEvent.online(MdnsAdvertisement(
              monitorId: monitorId,
              monitorName: monitorName,
              monitorCertFingerprint: fingerprint,
              controlPort: controlPort,
              pairingPort: pairingPort,
              version: version,
              transport: transport,
              ip: ip,
            )));
          }
        }
      }
    } catch (e) {
      // Ignore malformed packets
      _mdnsLog('mDNS parse error: $e');
    }
  }

  @override
  Future<void> startAdvertise(MdnsAdvertisement advertisement) async {
    _mdnsLog('DesktopMdnsService.startAdvertise() called for '
        'monitorId=${advertisement.monitorId}');

    // Stop any existing advertisement first
    if (_advertiseProcess != null) {
      _mdnsLog('Killing existing avahi-publish-service PID ${_advertiseProcess!.pid}');
      _advertiseProcess!.kill(ProcessSignal.sigterm);
      _advertiseProcess = null;
    }

    // Use avahi-publish-service if available.
    try {
      final serviceName = '${advertisement.monitorName}-${advertisement.monitorId}';
      final args = [
        serviceName,
        '_baby-monitor._tcp',
        advertisement.controlPort.toString(),
        'monitorId=${advertisement.monitorId}',
        'monitorName=${advertisement.monitorName}',
        'monitorCertFingerprint=${advertisement.monitorCertFingerprint}',
        'controlPort=${advertisement.controlPort}',
        'pairingPort=${advertisement.pairingPort}',
        'version=${advertisement.version}',
        'transport=${advertisement.transport}',
      ];
      _mdnsLog('Starting avahi-publish-service with args: $args');
      _advertiseProcess = await Process.start('avahi-publish-service', args);
      _mdnsLog('avahi-publish-service started with PID ${_advertiseProcess!.pid}');

      // Log stdout/stderr for debugging
      _advertiseProcess!.stdout.transform(utf8.decoder).listen(
        (data) => _mdnsLog('avahi stdout: $data'),
      );
      _advertiseProcess!.stderr.transform(utf8.decoder).listen(
        (data) => _mdnsLog('avahi stderr: $data'),
      );
      _advertiseProcess!.exitCode.then((code) {
        _mdnsLog('avahi-publish-service exited with code $code');
      });
    } catch (e, stack) {
      _mdnsLog('avahi-publish-service unavailable or failed: $e\n$stack');
      // Ignore if avahi is unavailable.
    }
  }

  @override
  Future<void> stop() async {
    _mdnsLog('Stopping desktop mDNS advertise/browse');
    _socket?.close();
    _socket = null;
    _browseController?.close();
    _browseController = null;
    _advertiseProcess?.kill(ProcessSignal.sigterm);
    _advertiseProcess = null;
  }
}

// DNS record types
enum _DnsRecordType { a, ptr, txt, srv, aaaa, other }

// Parsed mDNS record
class _MdnsRecord {
  _MdnsRecord({
    required this.name,
    required this.type,
    required this.ttl,
    this.ptrDomain,
    this.txtAttributes,
    this.srvTarget,
    this.srvPort,
    this.aAddress,
  });

  final String name;
  final _DnsRecordType type;
  /// Time-to-live in seconds. TTL=0 indicates a goodbye packet (service going offline).
  final int ttl;
  final String? ptrDomain;
  final Map<String, String>? txtAttributes;
  final String? srvTarget;
  final int? srvPort;
  final String? aAddress;
}

// Simple mDNS packet parser
class _MdnsParser {
  _MdnsParser(this.data);

  final Uint8List data;
  int _offset = 0;

  List<_MdnsRecord> parse() {
    final records = <_MdnsRecord>[];

    // Skip transaction ID and flags (4 bytes)
    _offset = 4;

    final qdCount = _readUint16();
    final anCount = _readUint16();
    final nsCount = _readUint16();
    final arCount = _readUint16();

    // Skip questions
    for (var i = 0; i < qdCount; i++) {
      _readName(); // Name
      _offset += 4; // Type + Class
    }

    // Parse answer, authority, and additional records
    final totalRecords = anCount + nsCount + arCount;
    for (var i = 0; i < totalRecords; i++) {
      final record = _parseRecord();
      if (record != null) {
        records.add(record);
      }
    }

    return records;
  }

  _MdnsRecord? _parseRecord() {
    final name = _readName();
    final typeValue = _readUint16();
    _offset += 2; // Class
    final ttl = _readUint32(); // TTL (4 bytes)
    final rdLength = _readUint16();
    final rdStart = _offset;

    _DnsRecordType type;
    String? ptrDomain;
    Map<String, String>? txtAttrs;
    String? srvTarget;
    int? srvPort;
    String? aAddress;

    switch (typeValue) {
      case 1: // A
        type = _DnsRecordType.a;
        if (rdLength >= 4) {
          aAddress = '${data[_offset]}.${data[_offset + 1]}.'
              '${data[_offset + 2]}.${data[_offset + 3]}';
        }
      case 12: // PTR
        type = _DnsRecordType.ptr;
        ptrDomain = _readName();
        _offset = rdStart + rdLength; // Ensure we're at the right position
        return _MdnsRecord(name: name, type: type, ttl: ttl, ptrDomain: ptrDomain);
      case 16: // TXT
        type = _DnsRecordType.txt;
        txtAttrs = _parseTxtRecord(rdLength);
      case 28: // AAAA
        type = _DnsRecordType.aaaa;
      case 33: // SRV
        type = _DnsRecordType.srv;
        if (rdLength >= 6) {
          _offset += 2; // Priority
          _offset += 2; // Weight
          srvPort = _readUint16();
          srvTarget = _readName();
          _offset = rdStart + rdLength;
          return _MdnsRecord(
            name: name,
            type: type,
            ttl: ttl,
            srvTarget: srvTarget,
            srvPort: srvPort,
          );
        }
      default:
        type = _DnsRecordType.other;
    }

    _offset = rdStart + rdLength;

    return _MdnsRecord(
      name: name,
      type: type,
      ttl: ttl,
      ptrDomain: ptrDomain,
      txtAttributes: txtAttrs,
      srvTarget: srvTarget,
      srvPort: srvPort,
      aAddress: aAddress,
    );
  }

  Map<String, String> _parseTxtRecord(int length) {
    final attrs = <String, String>{};
    final end = _offset + length;

    while (_offset < end) {
      final strLen = data[_offset++];
      if (strLen == 0 || _offset + strLen > end) break;

      final str = String.fromCharCodes(data.sublist(_offset, _offset + strLen));
      _offset += strLen;

      final eqIdx = str.indexOf('=');
      if (eqIdx > 0) {
        attrs[str.substring(0, eqIdx)] = str.substring(eqIdx + 1);
      }
    }

    return attrs;
  }

  int _readUint16() {
    final value = (data[_offset] << 8) | data[_offset + 1];
    _offset += 2;
    return value;
  }

  int _readUint32() {
    final value = (data[_offset] << 24) |
        (data[_offset + 1] << 16) |
        (data[_offset + 2] << 8) |
        data[_offset + 3];
    _offset += 4;
    return value;
  }

  String _readName() {
    final labels = <String>[];
    var jumped = false;
    var savedOffset = 0;

    while (_offset < data.length) {
      final len = data[_offset];

      if (len == 0) {
        _offset++;
        break;
      }

      // Check for compression pointer
      if ((len & 0xC0) == 0xC0) {
        if (!jumped) {
          savedOffset = _offset + 2;
        }
        final pointer = ((len & 0x3F) << 8) | data[_offset + 1];
        _offset = pointer;
        jumped = true;
        continue;
      }

      _offset++;
      if (_offset + len > data.length) break;

      labels.add(String.fromCharCodes(data.sublist(_offset, _offset + len)));
      _offset += len;
    }

    if (jumped) {
      _offset = savedOffset;
    }

    return labels.join('.');
  }
}

String _shortFingerprint(String fingerprint) {
  if (fingerprint.length <= 12) return fingerprint;
  final prefix = fingerprint.substring(0, 6);
  final suffix = fingerprint.substring(fingerprint.length - 4);
  return '$prefix...$suffix';
}
