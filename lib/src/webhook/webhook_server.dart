import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import '../domain/models.dart';
import '../identity/device_identity.dart';
import '../identity/pem.dart';
import '../identity/pkcs8.dart';
import '../util/format_utils.dart';

/// Default port for webhook server.
const kWebhookDefaultPort = 9443;

/// Event emitted when a noise event is received via webhook.
class WebhookNoiseEvent {
  const WebhookNoiseEvent({
    required this.remoteDeviceId,
    required this.monitorName,
    required this.timestamp,
    required this.peakLevel,
    required this.subscriptionId,
    required this.monitorFingerprint,
  });

  final String remoteDeviceId;
  final String monitorName;
  final int timestamp;
  final int peakLevel;
  final String subscriptionId;
  final String monitorFingerprint;

  @override
  String toString() =>
      'WebhookNoiseEvent(monitor=$remoteDeviceId, peak=$peakLevel)';
}

/// HTTPS server for receiving noise events from monitors via webhook.
///
/// Uses mTLS to verify that incoming requests are from trusted monitors.
/// Runs on the listener device and receives POSTs from monitor devices.
class WebhookServer {
  WebhookServer({this.bindAddress});

  /// Optional specific bind address. If null, tries IPv6 first, then IPv4.
  final String? bindAddress;

  HttpServer? _server;
  int? _boundPort;
  String? _boundAddress;
  DeviceIdentity? _identity;

  final Set<String> _trustedFingerprints = {};
  final List<List<int>> _trustedCertificates = [];
  final _eventsController = StreamController<WebhookNoiseEvent>.broadcast();

  int? get boundPort => _boundPort;
  String? get boundAddress => _boundAddress;
  bool get isRunning => _server != null;
  Stream<WebhookNoiseEvent> get events => _eventsController.stream;

  /// Start the webhook server.
  ///
  /// [trustedMonitors] - Monitors whose certificates are trusted.
  Future<void> start({
    required int port,
    required DeviceIdentity identity,
    required List<TrustedMonitor> trustedMonitors,
  }) async {
    await stop();
    _identity = identity;

    // Initialize trusted monitors
    _trustedFingerprints.clear();
    _trustedCertificates.clear();

    for (final monitor in trustedMonitors) {
      _trustedFingerprints.add(monitor.certFingerprint);
      if (monitor.certificateDer != null) {
        _trustedCertificates.add(monitor.certificateDer!);
      }
    }

    // Also trust our own certificate (for same-device testing)
    _trustedFingerprints.add(identity.certFingerprint);
    _trustedCertificates.add(identity.certificateDer);

    await _bindServer(port, identity);
  }

  Future<void> _bindServer(int port, DeviceIdentity identity) async {
    final context = await _buildSecurityContext(identity);

    // If explicit bindAddress provided, use only that; otherwise try IPv6 first
    final bindAddresses = bindAddress != null
        ? [bindAddress!]
        : [InternetAddress.anyIPv6.address, InternetAddress.anyIPv4.address];

    for (final address in bindAddresses) {
      try {
        _log(
          'Binding webhook server on $address:$port '
          'fingerprint=${shortFingerprint(identity.certFingerprint)} '
          'trustedMonitors=${_trustedFingerprints.length}',
        );

        _server = await HttpServer.bindSecure(
          address,
          port,
          context,
          requestClientCertificate: true,
          shared: true, // Allow rebind for hot reload
        );
        _boundPort = _server!.port;
        _boundAddress = address;

        _server!.listen(
          _handleRequest,
          onError: (error, stack) {
            _log('Webhook server error: $error');
          },
        );

        _log(
          'Webhook server running on $address:${_server!.port} '
          'mTLS enabled, trustedMonitors=${_trustedFingerprints.length}',
        );

        // Bind succeeded, no need to try fallback
        break;
      } catch (e) {
        _log('Failed to bind webhook server on $address:$port: $e');
      }
    }

    if (_server == null) {
      throw StateError('Failed to bind webhook server on any address');
    }
  }

  Future<void> stop() async {
    _log('Stopping webhook server');
    await _server?.close(force: true);
    _server = null;
    _boundPort = null;
    _boundAddress = null;
    _log('Webhook server stopped');
  }

  /// Add a trusted monitor dynamically.
  Future<void> addTrustedMonitor(TrustedMonitor monitor) async {
    if (_trustedFingerprints.contains(monitor.certFingerprint)) {
      _log('Monitor already trusted: ${shortFingerprint(monitor.certFingerprint)}');
      return;
    }

    _trustedFingerprints.add(monitor.certFingerprint);
    if (monitor.certificateDer != null) {
      _trustedCertificates.add(monitor.certificateDer!);
    }
    _log(
      'Added trusted monitor ${shortFingerprint(monitor.certFingerprint)}, '
      'total=${_trustedFingerprints.length}',
    );

    await _rebindWithUpdatedCertificates();
  }

  /// Remove a trusted monitor.
  Future<void> removeTrustedMonitor(String fingerprint) async {
    if (!_trustedFingerprints.contains(fingerprint)) return;

    _trustedFingerprints.remove(fingerprint);
    _trustedCertificates.removeWhere(
      (cert) => _fingerprintHex(cert) == fingerprint,
    );
    _log(
      'Removed trusted monitor ${shortFingerprint(fingerprint)}, '
      'total=${_trustedFingerprints.length}',
    );

    await _rebindWithUpdatedCertificates();
  }

  Future<void> _rebindWithUpdatedCertificates() async {
    if (_identity == null || _boundPort == null) return;

    final port = _boundPort!;
    final identity = _identity!;

    _log('Rebinding webhook server with updated certificates');

    final oldServer = _server;
    _server = null;

    await _bindServer(port, identity);
    await oldServer?.close();

    _log('Webhook server rebind complete');
  }

  Future<SecurityContext> _buildSecurityContext(DeviceIdentity identity) async {
    final ctx = SecurityContext(withTrustedRoots: false);

    // Server certificate and key
    final certPem = encodePem('CERTIFICATE', identity.certificateDer);
    final extracted = await identity.keyPair.extract();
    final pkcs8 = p256PrivateKeyPkcs8(
      privateKeyBytes: (extracted as SimpleKeyPairData).bytes,
      publicKeyBytes: identity.publicKeyUncompressed,
    );
    final keyPem = encodePem('PRIVATE KEY', pkcs8);
    ctx.useCertificateChainBytes(utf8.encode(certPem));
    ctx.usePrivateKeyBytes(utf8.encode(keyPem));

    // Add trusted client certificates (monitors)
    for (final certDer in _trustedCertificates) {
      final clientCertPem = encodePem('CERTIFICATE', certDer);
      ctx.setTrustedCertificatesBytes(utf8.encode(clientCertPem));
    }

    return ctx;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final remoteIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final remotePort = request.connectionInfo?.remotePort ?? 0;
    _log(
      'Incoming ${request.method} ${request.uri.path} from $remoteIp:$remotePort',
    );

    // Only accept POST to /api/noise-event
    if (request.method != 'POST' || request.uri.path != '/api/noise-event') {
      _log('Rejected: invalid method or path');
      request.response
        ..statusCode = HttpStatus.notFound
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': 'not_found'}));
      await request.response.close();
      return;
    }

    // Verify client certificate
    final cert = request.certificate;
    if (cert == null) {
      _log('Rejected: no client certificate');
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'error': 'unauthenticated',
          'message': 'Client certificate required',
        }));
      await request.response.close();
      return;
    }

    final fingerprint = _fingerprintHex(cert.der);
    if (!_trustedFingerprints.contains(fingerprint)) {
      _log('Rejected: untrusted certificate ${shortFingerprint(fingerprint)}');
      request.response
        ..statusCode = HttpStatus.forbidden
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'error': 'untrusted',
          'message': 'Certificate not trusted',
        }));
      await request.response.close();
      return;
    }

    // Parse request body
    try {
      final bodyString = await utf8.decodeStream(request);
      final body = jsonDecode(bodyString) as Map<String, dynamic>;

      // Validate payload
      final type = body['type'] as String?;
      if (type != 'noise_event') {
        _log('Rejected: invalid event type: $type');
        request.response
          ..statusCode = HttpStatus.badRequest
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'error': 'invalid_type'}));
        await request.response.close();
        return;
      }

      final remoteDeviceId = body['remoteDeviceId'] as String?;
      final monitorName = body['monitorName'] as String?;
      final timestamp = body['timestamp'] as int?;
      final peakLevel = body['peakLevel'] as int?;
      final subscriptionId = body['subscriptionId'] as String?;

      if (remoteDeviceId == null ||
          monitorName == null ||
          timestamp == null ||
          peakLevel == null ||
          subscriptionId == null) {
        _log('Rejected: missing required fields');
        request.response
          ..statusCode = HttpStatus.badRequest
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'error': 'missing_fields'}));
        await request.response.close();
        return;
      }

      // Emit event
      final event = WebhookNoiseEvent(
        remoteDeviceId: remoteDeviceId,
        monitorName: monitorName,
        timestamp: timestamp,
        peakLevel: peakLevel,
        subscriptionId: subscriptionId,
        monitorFingerprint: fingerprint,
      );

      _log('Received noise event: $event');
      _eventsController.add(event);

      // Send success response
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'status': 'ok'}));
      await request.response.close();
    } catch (e) {
      _log('Error processing request: $e');
      request.response
        ..statusCode = HttpStatus.badRequest
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': 'invalid_body'}));
      await request.response.close();
    }
  }

  String _fingerprintHex(List<int> bytes) {
    final digest = sha256.convert(bytes);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _log(String message) {
    developer.log(message, name: 'webhook_server');
  }

  void dispose() {
    stop();
    _eventsController.close();
  }
}
