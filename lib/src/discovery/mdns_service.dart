import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/build_flags.dart';
import '../domain/models.dart';
import '../util/format_utils.dart';

/// Set to true to enable verbose mDNS trace logging.
const _kMdnsTrace = false;

void _mdnsLog(String message) {
  developer.log(message, name: 'mdns');
  debugPrint('[mdns] $message');
}

/// Trace-level logging for verbose mDNS debugging.
/// Only logs when [_kMdnsTrace] is true.
void _mdnsTrace(String message) {
  if (!_kMdnsTrace) return;
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
    _mdnsTrace('MethodChannelMdnsService.browse() starting platform stream');
    return _events
        .receiveBroadcastStream()
        .handleError(
          (Object error, StackTrace stack) =>
              _mdnsLog('mDNS platform stream error: $error\n$stack'),
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
          try {
            final isOnline = map['isOnline'] as bool? ?? true;
            final advertisement = MdnsAdvertisement.fromJson(map);
            _mdnsLog(
              'Platform mDNS event: ${isOnline ? "ONLINE" : "OFFLINE"} '
              'remoteDeviceId=${advertisement.remoteDeviceId} ip=${advertisement.ip}',
            );
            return MdnsEvent(advertisement: advertisement, isOnline: isOnline);
          } catch (e, stack) {
            _mdnsLog('FAILED to parse mDNS event: $e\nPayload: $map\n$stack');
            rethrow;
          }
        });
  }

  @override
  Future<void> startAdvertise(MdnsAdvertisement advertisement) async {
    _mdnsTrace(
      'MethodChannelMdnsService.startAdvertise() '
      'remoteDeviceId=${advertisement.remoteDeviceId} '
      'controlPort=${advertisement.controlPort} '
      'pairingPort=${advertisement.pairingPort} '
      'fp=${shortFingerprint(advertisement.certFingerprint)}',
    );
    await _method.invokeMethod('startAdvertise', advertisement.toJson());
  }

  @override
  Future<void> stop() async {
    _mdnsTrace('MethodChannelMdnsService.stop()');
    await _method.invokeMethod('stop');
  }
}

/// Desktop (Linux) using raw multicast sockets for continuous mDNS listening
/// and avahi-publish-service for advertising.
class DesktopMdnsService implements MdnsService {
  // Cache instanceName -> remoteDeviceId for goodbye packets
  final _instanceToDeviceId = <String, String>{};

  // Static to survive provider recreation
  static int? _avahiPid;
  static Completer<void>? _advertiseLock;
  // Static browse socket and controller to survive provider recreation
  static RawDatagramSocket? _socket;
  static StreamController<MdnsEvent>? _browseController;
  static bool _browseStarted = false;

  static const _mdnsAddress = '224.0.0.251';
  static const _mdnsPort = 5353;
  static const _serviceType = '_baby-monitor._tcp.local';

  @override
  Stream<MdnsEvent> browse() {
    _mdnsTrace('DesktopMdnsService.browse() called, browseStarted=$_browseStarted');

    // Reuse existing controller if available (survives provider recreation)
    if (_browseController != null && !_browseController!.isClosed) {
      _mdnsTrace('Reusing existing browse stream');
      return _browseController!.stream;
    }

    _mdnsTrace('Creating new browse stream');
    final controller = StreamController<MdnsEvent>.broadcast(
      onListen: () {
        _mdnsTrace('mDNS browse stream: first listener attached');
      },
      onCancel: () {
        // Don't close socket on cancel - keep listening for mDNS events
        // The socket will be reused when browse() is called again
        _mdnsTrace('mDNS browse stream: all listeners cancelled (socket kept alive)');
      },
    );
    _browseController = controller;

    // Only start listening once (static flag survives provider recreation)
    if (!_browseStarted) {
      _browseStarted = true;
      // Track seen services to avoid duplicates within a time window
      final seenServices = <String, DateTime>{};
      const dedupeWindow = Duration(seconds: 30);
      _startListening(controller, seenServices, dedupeWindow);
    } else {
      _mdnsTrace('Socket already listening, reusing');
    }

    return controller.stream;
  }

  Future<void> _startListening(
    StreamController<MdnsEvent> controller,
    Map<String, DateTime> seenServices,
    Duration dedupeWindow,
  ) async {
    _mdnsTrace('_startListening() called');
    try {
      // Bind to mDNS port with reuseAddress and reusePort
      _mdnsTrace('Binding to 0.0.0.0:$_mdnsPort with reuseAddress/reusePort');
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _mdnsPort,
        reuseAddress: true,
        reusePort: true,
      );
      _mdnsTrace('Socket bound successfully');

      // Join multicast group
      final mdnsGroup = InternetAddress(_mdnsAddress);
      _mdnsTrace('Joining multicast group $_mdnsAddress');
      _socket!.joinMulticast(mdnsGroup);
      _socket!.multicastLoopback = true;

      _mdnsLog('Joined mDNS multicast group $_mdnsAddress:$_mdnsPort');

      // Send initial query for our service type
      _sendQuery();

      // Also send periodic queries to catch services that don't announce
      Timer.periodic(const Duration(seconds: 30), (timer) {
        if (_socket == null || controller.isClosed) {
          _mdnsTrace('Stopping periodic query timer');
          timer.cancel();
          return;
        }
        _sendQuery();
      });

      _mdnsTrace('Starting socket listen loop');
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
          _mdnsTrace('mDNS socket closed');
        },
      );
      _mdnsTrace('Socket listen loop started');
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
      _mdnsTrace('Sent mDNS query for $_serviceType');
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

      // Log all record types for debugging (trace level)
      final recordSummary = records
          .map((r) => '${r.type.name}:${r.name}(ttl=${r.ttl})')
          .join(', ');
      if (records.any((r) =>
          r.name.toLowerCase().contains('_baby-monitor') ||
          r.name.toLowerCase().contains('cribcall'))) {
        _mdnsTrace('mDNS packet from ${source.address}: $recordSummary');
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
          _mdnsTrace(
            'mDNS PTR record: instance=$instanceName ttl=${record.ttl} '
            'isGoodbye=$isGoodbye',
          );

          _MdnsRecord? srvRecord;
          _MdnsRecord? txtRecord;
          _MdnsRecord? aRecord;
          _MdnsRecord? aaaaRecord;

          for (final r in records) {
            if (r.name == instanceName) {
              if (r.type == _DnsRecordType.srv) srvRecord = r;
              if (r.type == _DnsRecordType.txt) txtRecord = r;
            }
            // Address records might be for the target hostname
            if (srvRecord?.srvTarget != null &&
                r.name == srvRecord!.srvTarget) {
              if (r.type == _DnsRecordType.a) {
                aRecord = r;
              } else if (r.type == _DnsRecordType.aaaa) {
                aaaaRecord = r;
              }
            }
          }

          // For goodbye packets, we may not have full records, but we need
          // to extract what we can from the instance name
          if (isGoodbye) {
            // Parse TXT attributes if available, or use cached remoteDeviceId
            final attrs = txtRecord?.txtAttributes ?? {};
            final cachedDeviceId = _instanceToDeviceId[instanceName];
            final remoteDeviceId = attrs['remoteDeviceId'] ?? cachedDeviceId ?? instanceName;
            final monitorName = attrs['monitorName'] ?? instanceName;
            final fingerprint = attrs['monitorCertFingerprint'] ?? '';
            final ip = _selectBestIp(
              ipv4: aRecord?.aAddress,
              ipv6: aaaaRecord?.aaaaAddress,
              fallback: source.address,
            );

            // Remove from caches
            _instanceToDeviceId.remove(instanceName);
            final keyPrefix = '$remoteDeviceId:';
            seenServices.removeWhere((key, _) => key.startsWith(keyPrefix));

            if (!controller.isClosed) {
              _mdnsLog('OFFLINE remoteDeviceId=$remoteDeviceId ip=$ip');
              controller.add(MdnsEvent.offline(MdnsAdvertisement(
                remoteDeviceId: remoteDeviceId,
                monitorName: monitorName,
                certFingerprint: fingerprint,
                controlPort: srvRecord?.srvPort ?? kControlDefaultPort,
                pairingPort: kPairingDefaultPort,
                version: 1,
                ip: ip,
              )));
            }
            continue;
          }

          if (srvRecord == null) continue;

          // Also look for address records matching SRV target
          if ((aRecord == null || aaaaRecord == null) &&
              srvRecord.srvTarget != null) {
            for (final r in records) {
              if (r.name != srvRecord.srvTarget) continue;
              if (r.type == _DnsRecordType.a && aRecord == null) {
                aRecord = r;
              } else if (r.type == _DnsRecordType.aaaa && aaaaRecord == null) {
                aaaaRecord = r;
              }
            }
          }

          // Parse TXT attributes
          final attrs = txtRecord?.txtAttributes ?? {};
          final remoteDeviceId = attrs['remoteDeviceId'] ?? instanceName;
          final monitorName = attrs['monitorName'] ?? instanceName;
          final fingerprint = attrs['monitorCertFingerprint'] ?? '';
          final transport = attrs['transport'] ?? kTransportHttpWs;
          final controlPort = int.tryParse(attrs['controlPort'] ?? '') ??
              srvRecord.srvPort ??
              kControlDefaultPort;
          final pairingPort = int.tryParse(attrs['pairingPort'] ?? '') ??
              kPairingDefaultPort;
          final version = int.tryParse(attrs['version'] ?? '1') ?? 1;
          final ip = _selectBestIp(
            ipv4: aRecord?.aAddress,
            ipv6: aaaaRecord?.aaaaAddress,
            fallback: source.address,
          );

          // Cache instanceName -> remoteDeviceId for goodbye packets
          _instanceToDeviceId[instanceName] = remoteDeviceId;

          // Dedupe check (only for online events)
          final key = '$remoteDeviceId:$ip:$controlPort';
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

          if (!controller.isClosed) {
            _mdnsLog(
              'ONLINE remoteDeviceId=$remoteDeviceId ip=$ip port=$controlPort '
              'fp=${shortFingerprint(fingerprint)}',
            );
            controller.add(MdnsEvent.online(MdnsAdvertisement(
              remoteDeviceId: remoteDeviceId,
              monitorName: monitorName,
              certFingerprint: fingerprint,
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
      _mdnsTrace('mDNS parse error: $e');
    }
  }

  @override
  Future<void> startAdvertise(MdnsAdvertisement advertisement) async {
    _mdnsTrace('DesktopMdnsService.startAdvertise() called for '
        'remoteDeviceId=${advertisement.remoteDeviceId}');

    // Wait for any in-progress advertise operation to complete
    if (_advertiseLock != null) {
      _mdnsTrace('Waiting for previous startAdvertise to complete...');
      await _advertiseLock!.future;
    }

    // Acquire lock
    _advertiseLock = Completer<void>();

    try {
      // Best-effort cleanup of stale avahi publishers from previous runs
      await _killStaleAvahiProcesses(advertisement.remoteDeviceId);

      // Kill any existing avahi process first (use static PID to survive provider recreation)
      await _killAvahiProcess();

      // Use avahi-publish-service if available.
      try {
        final serviceName = '${advertisement.monitorName}-${advertisement.remoteDeviceId}';
        final args = [
          serviceName,
          '_baby-monitor._tcp',
          advertisement.controlPort.toString(),
          'remoteDeviceId=${advertisement.remoteDeviceId}',
          'monitorName=${advertisement.monitorName}',
          'monitorCertFingerprint=${advertisement.certFingerprint}',
          'controlPort=${advertisement.controlPort}',
          'pairingPort=${advertisement.pairingPort}',
          'version=${advertisement.version}',
          'transport=${advertisement.transport}',
        ];
        _mdnsTrace('Starting avahi-publish-service with args: $args');
        final process = await Process.start('avahi-publish-service', args);
        _avahiPid = process.pid;
        _mdnsLog('Advertising via avahi PID $_avahiPid');

        // Log stdout/stderr for debugging
        process.stdout.transform(utf8.decoder).listen(
          (data) => _mdnsTrace('avahi stdout: $data'),
        );
        process.stderr.transform(utf8.decoder).listen(
          (data) => _mdnsTrace('avahi stderr: $data'),
        );
        process.exitCode.then((code) {
          _mdnsTrace('avahi-publish-service PID ${process.pid} exited with code $code');
          // Clear the PID if it matches (process ended naturally or was killed)
          if (_avahiPid == process.pid) {
            _avahiPid = null;
          }
        });
      } catch (e, stack) {
        _mdnsLog('avahi-publish-service unavailable or failed: $e\n$stack');
        // Ignore if avahi is unavailable.
      }
    } finally {
      // Release lock
      _advertiseLock!.complete();
      _advertiseLock = null;
    }
  }

  /// Kill the avahi-publish-service process if running.
  static Future<void> _killAvahiProcess() async {
    if (_avahiPid == null) {
      _mdnsTrace('No avahi process to kill');
      return;
    }

    _mdnsTrace('Killing avahi-publish-service PID $_avahiPid');
    try {
      // Use Process.killPid with SIGTERM first, then SIGKILL if needed
      Process.killPid(_avahiPid!, ProcessSignal.sigterm);

      // Wait a bit for graceful shutdown
      await Future.delayed(const Duration(milliseconds: 100));

      // Check if still running and force kill
      try {
        // If killPid with signal 0 succeeds, process is still alive
        final stillAlive = Process.killPid(_avahiPid!, ProcessSignal.sigcont);
        if (stillAlive) {
          _mdnsTrace('Process still alive, sending SIGKILL');
          Process.killPid(_avahiPid!, ProcessSignal.sigkill);
        }
      } catch (_) {
        // Process already dead, good
      }

      _mdnsTrace('Killed avahi-publish-service PID $_avahiPid');
    } catch (e) {
      _mdnsLog('Error killing avahi process: $e');
    }
    _avahiPid = null;
  }

  /// Kill any avahi-publish-service processes that include [remoteDeviceId] in the cmdline.
  /// This handles stale publishers left behind when the app restarts.
  Future<void> _killStaleAvahiProcesses(String remoteDeviceId) async {
    try {
      final result = await Process.run('pgrep', ['-f', 'avahi-publish-service']);
      if (result.exitCode != 0) return;
      final lines = (result.stdout as String)
          .split('\n')
          .where((line) => line.trim().isNotEmpty);
      for (final line in lines) {
        final pid = int.tryParse(line.trim());
        if (pid == null || pid == _avahiPid) continue;
        final cmd = await Process.run('ps', ['-o', 'cmd=', '-p', '$pid']);
        final cmdline = (cmd.stdout as String?)?.trim() ?? '';
        if (!cmdline.contains(remoteDeviceId)) continue;
        _mdnsTrace('Killing stale avahi-publish-service PID $pid (cmd="$cmdline")');
        try {
          Process.killPid(pid, ProcessSignal.sigterm);
        } catch (_) {
          // Ignore failures; best effort.
        }
      }
    } catch (e) {
      _mdnsTrace('Could not check for stale avahi publishers: $e');
    }
  }

  String? _selectBestIp({String? ipv4, String? ipv6, String? fallback}) {
    if (_isUsableIp(ipv4)) return ipv4;
    if (_isUsableIpv6(ipv6)) return ipv6;
    if (_isUsableIp(fallback)) return fallback;
    return null;
  }

  bool _isUsableIp(String? ip) {
    if (ip == null || ip.isEmpty) return false;
    if (ip == '0.0.0.0' || ip == '::' || ip == '::0') return false;
    return true;
  }

  bool _isUsableIpv6(String? ip) {
    if (!_isUsableIp(ip)) return false;
    return !_isLinkLocalIpv6(ip!);
  }

  bool _isLinkLocalIpv6(String ip) {
    return ip.toLowerCase().startsWith('fe80:');
  }

  @override
  Future<void> stop() async {
    _mdnsTrace('DesktopMdnsService.stop() called - stopping advertising only');
    // Only stop advertising, NOT the browse socket.
    // The browse socket is managed by the stream lifecycle (onCancel in browse()).
    await _killAvahiProcess();
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
    this.aaaaAddress,
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
  final String? aaaaAddress;
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
    String? aaaaAddress;

    switch (typeValue) {
      case 1: // A
        type = _DnsRecordType.a;
        if (rdLength >= 4) {
          aAddress = '${data[_offset]}.${data[_offset + 1]}.'
              '${data[_offset + 2]}.${data[_offset + 3]}';
        }
        break;
      case 12: // PTR
        type = _DnsRecordType.ptr;
        ptrDomain = _readName();
        _offset = rdStart + rdLength; // Ensure we're at the right position
        return _MdnsRecord(name: name, type: type, ttl: ttl, ptrDomain: ptrDomain);
      case 16: // TXT
        type = _DnsRecordType.txt;
        txtAttrs = _parseTxtRecord(rdLength);
        break;
      case 28: // AAAA
        type = _DnsRecordType.aaaa;
        if (rdLength >= 16) {
          final raw = Uint8List.sublistView(data, _offset, _offset + 16);
          try {
            aaaaAddress = InternetAddress.fromRawAddress(raw).address;
          } catch (_) {
            // Ignore parse errors
          }
        }
        break;
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
        break;
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
      aaaaAddress: aaaaAddress,
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
