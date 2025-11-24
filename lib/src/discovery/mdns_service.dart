import '../domain/models.dart';

/// Abstraction for mDNS/UPnP discovery and advertisement.
import 'package:flutter/services.dart';

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
