import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../config/build_flags.dart';

/// Result of sending FCM messages via Cloud Function.
class FcmSendResult {
  const FcmSendResult({
    required this.success,
    required this.failure,
    required this.invalidTokens,
  });

  final int success;
  final int failure;
  final List<String> invalidTokens;

  factory FcmSendResult.fromJson(Map<String, dynamic> json) {
    return FcmSendResult(
      success: json['success'] as int? ?? 0,
      failure: json['failure'] as int? ?? 0,
      invalidTokens: (json['invalidTokens'] as List<dynamic>?)
              ?.cast<String>() ??
          [],
    );
  }

  @override
  String toString() =>
      'FcmSendResult(success=$success, failure=$failure, invalidTokens=${invalidTokens.length})';
}

/// HTTP client for sending FCM messages via Firebase Cloud Function.
class FcmSender {
  FcmSender({String? cloudFunctionUrl})
      : _cloudFunctionUrl = cloudFunctionUrl ?? kFcmCloudFunctionUrl;

  final String _cloudFunctionUrl;
  HttpClient? _client;

  /// Whether FCM sending is enabled (Cloud Function URL is configured).
  bool get isEnabled => _cloudFunctionUrl.isNotEmpty;

  /// Send a noise event to multiple listeners via FCM.
  ///
  /// Returns a result indicating success/failure counts and any invalid tokens.
  /// Throws on network or server errors.
  Future<FcmSendResult> sendNoiseEvent({
    required String monitorId,
    required String monitorName,
    required int timestamp,
    required int peakLevel,
    required List<String> fcmTokens,
  }) async {
    if (!isEnabled) {
      developer.log(
        'FCM not configured (FCM_FUNCTION_URL not set), skipping push',
        name: 'fcm_sender',
      );
      return const FcmSendResult(success: 0, failure: 0, invalidTokens: []);
    }

    if (fcmTokens.isEmpty) {
      developer.log('No FCM tokens provided, skipping push', name: 'fcm_sender');
      return const FcmSendResult(success: 0, failure: 0, invalidTokens: []);
    }

    _client ??= HttpClient()..connectionTimeout = const Duration(seconds: 10);

    final uri = Uri.parse(_cloudFunctionUrl);
    developer.log(
      'Sending FCM noise event to ${fcmTokens.length} tokens via $uri',
      name: 'fcm_sender',
    );

    try {
      final request = await _client!.postUrl(uri);
      request.headers.contentType = ContentType.json;

      final payload = jsonEncode({
        'monitorId': monitorId,
        'monitorName': monitorName,
        'timestamp': timestamp,
        'peakLevel': peakLevel,
        'fcmTokens': fcmTokens,
      });

      request.write(payload);

      final response = await request.close();
      final body = await utf8.decodeStream(response);

      if (response.statusCode != 200) {
        developer.log(
          'FCM send failed: status=${response.statusCode} body=$body',
          name: 'fcm_sender',
        );
        throw HttpException(
          'FCM Cloud Function returned ${response.statusCode}: $body',
          uri: uri,
        );
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      final result = FcmSendResult.fromJson(json);
      developer.log('FCM send result: $result', name: 'fcm_sender');
      return result;
    } catch (e) {
      developer.log('FCM send error: $e', name: 'fcm_sender');
      rethrow;
    }
  }

  /// Close the HTTP client.
  void dispose() {
    _client?.close();
    _client = null;
  }
}
