import 'dart:io';

/// Returns a list of local IPv4 addresses for the device.
/// Excludes loopback addresses (127.x.x.x) and link-local addresses (169.254.x.x).
Future<List<String>> getLocalIpAddresses() async {
  final ips = <String>[];
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final interface in interfaces) {
      for (final addr in interface.addresses) {
        final ip = addr.address;
        // Skip loopback and link-local addresses
        if (ip.startsWith('127.') || ip.startsWith('169.254.')) {
          continue;
        }
        ips.add(ip);
      }
    }
  } catch (_) {
    // Ignore errors - return empty list
  }
  return ips;
}
