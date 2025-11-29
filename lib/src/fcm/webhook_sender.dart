import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import '../identity/device_identity.dart';
import '../identity/pem.dart';
import '../identity/pkcs8.dart';

/// Result of sending a webhook notification.
class WebhookSendResult {
  const WebhookSendResult({
    required this.success,
    this.statusCode,
    this.error,
    this.responseBody,
  });

  final bool success;
  final int? statusCode;
  final String? error;
  final String? responseBody;

  @override
  String toString() =>
      'WebhookSendResult(success=$success, status=$statusCode, error=$error)';
}

/// HTTP client for sending noise events to webhook URLs with mTLS authentication.
///
/// Uses the monitor's device certificate for client authentication,
/// allowing the webhook receiver to verify the notification source.
class WebhookSender {
  WebhookSender({
    required DeviceIdentity identity,
    Duration? connectionTimeout,
    Duration? requestTimeout,
  })  : _identity = identity,
        _connectionTimeout = connectionTimeout ?? const Duration(seconds: 10),
        _requestTimeout = requestTimeout ?? const Duration(seconds: 30);

  final DeviceIdentity _identity;
  final Duration _connectionTimeout;
  final Duration _requestTimeout;

  HttpClient? _client;
  bool _disposed = false;

  /// Send a noise event to a webhook URL.
  ///
  /// Returns a result indicating success/failure and any error details.
  Future<WebhookSendResult> sendNoiseEvent({
    required String webhookUrl,
    required String remoteDeviceId,
    required String monitorName,
    required int timestamp,
    required int peakLevel,
    required String subscriptionId,
  }) async {
    if (_disposed) {
      return const WebhookSendResult(
        success: false,
        statusCode: null,
        error: 'WebhookSender disposed',
      );
    }

    // Validate URL
    final uri = Uri.tryParse(webhookUrl);
    if (uri == null || uri.scheme != 'https') {
      developer.log(
        'Webhook rejected: invalid URL or not HTTPS: $webhookUrl',
        name: 'webhook_sender',
      );
      return WebhookSendResult(
        success: false,
        statusCode: null,
        error: 'Invalid webhook URL: must be HTTPS',
      );
    }

    // Lazily create mTLS client
    _client ??= await _createMtlsClient();

    developer.log(
      'Sending webhook noise event to $webhookUrl',
      name: 'webhook_sender',
    );

    try {
      final request =
          await _client!.postUrl(uri).timeout(_connectionTimeout);

      request.headers.contentType = ContentType.json;
      request.headers.set('X-CribCall-Monitor-Fingerprint', _identity.certFingerprint);
      request.headers.set('X-CribCall-Event-Type', 'noise');

      final payload = jsonEncode({
        'type': 'noise_event',
        'version': 1,
        'remoteDeviceId': remoteDeviceId,
        'monitorName': monitorName,
        'timestamp': timestamp,
        'peakLevel': peakLevel,
        'subscriptionId': subscriptionId,
        'sentAt': DateTime.now().toUtc().toIso8601String(),
      });

      request.write(payload);

      final response = await request.close().timeout(_requestTimeout);

      final body = await utf8.decodeStream(response).timeout(_requestTimeout);

      final success = response.statusCode >= 200 && response.statusCode < 300;

      developer.log(
        'Webhook response: status=${response.statusCode} success=$success',
        name: 'webhook_sender',
      );

      return WebhookSendResult(
        success: success,
        statusCode: response.statusCode,
        responseBody: body.isNotEmpty ? body : null,
        error: success ? null : 'HTTP ${response.statusCode}',
      );
    } on SocketException catch (e) {
      developer.log('Webhook socket error: $e', name: 'webhook_sender');
      return WebhookSendResult(
        success: false,
        statusCode: null,
        error: 'Connection failed: ${e.message}',
      );
    } on HandshakeException catch (e) {
      developer.log('Webhook TLS handshake error: $e', name: 'webhook_sender');
      return WebhookSendResult(
        success: false,
        statusCode: null,
        error: 'TLS handshake failed: ${e.message}',
      );
    } on HttpException catch (e) {
      developer.log('Webhook HTTP error: $e', name: 'webhook_sender');
      return WebhookSendResult(
        success: false,
        statusCode: null,
        error: 'HTTP error: ${e.message}',
      );
    } on TimeoutException catch (_) {
      developer.log('Webhook timeout', name: 'webhook_sender');
      return const WebhookSendResult(
        success: false,
        statusCode: null,
        error: 'Request timed out',
      );
    } catch (e) {
      developer.log('Webhook unexpected error: $e', name: 'webhook_sender');
      return WebhookSendResult(
        success: false,
        statusCode: null,
        error: 'Unexpected error: $e',
      );
    }
  }

  /// Create an HttpClient configured for mTLS using monitor's certificate.
  Future<HttpClient> _createMtlsClient() async {
    final context = SecurityContext(withTrustedRoots: true);

    // Use monitor's certificate for client authentication
    final certPem = encodePem('CERTIFICATE', _identity.certificateDer);
    final extracted = await _identity.keyPair.extract();
    final pkcs8 = p256PrivateKeyPkcs8(
      privateKeyBytes: (extracted as SimpleKeyPairData).bytes,
      publicKeyBytes: _identity.publicKeyUncompressed,
    );
    final keyPem = encodePem('PRIVATE KEY', pkcs8);

    context.useCertificateChainBytes(utf8.encode(certPem));
    context.usePrivateKeyBytes(utf8.encode(keyPem));

    final client = HttpClient(context: context);
    client.connectionTimeout = _connectionTimeout;

    return client;
  }

  /// Close the HTTP client and release resources.
  void dispose() {
    _disposed = true;
    _client?.close(force: true);
    _client = null;
  }
}
