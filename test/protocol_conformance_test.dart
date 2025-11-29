/// Protocol conformance tests for the Dart control server.
///
/// This test runner parses YAML test specs from test_specs/protocol/
/// and validates that the Dart ControlServer behaves according to spec.
///
/// Run with: flutter test test/protocol_conformance_test.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:cribcall/src/control/control_server.dart';
import 'package:cribcall/src/domain/models.dart';
import 'package:cribcall/src/identity/device_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'helpers/mtls_test_client.dart';

/// Matcher value types from the spec schema.
const _kMatcherNonempty = r'$nonempty';
const _kMatcherPositiveInt = r'$positive_int';
const _kMatcherIso8601 = r'$iso8601';
const _kMatcherUuid = r'$uuid';
const _kMatcherAny = r'$any';
const _kMatcherContainsPrefix = r'$contains:';
const _kMatcherRegexPrefix = r'$regex:';

/// Load and parse a test spec YAML file.
Future<Map<String, dynamic>> loadTestSpec(String filename) async {
  final file = File('test_specs/protocol/$filename');
  if (!await file.exists()) {
    throw StateError('Test spec not found: $filename');
  }
  final content = await file.readAsString();
  final yaml = loadYaml(content);
  return _yamlToMap(yaml);
}

/// Convert YamlMap to regular Map recursively.
Map<String, dynamic> _yamlToMap(YamlMap yaml) {
  final result = <String, dynamic>{};
  for (final entry in yaml.entries) {
    final key = entry.key.toString();
    final value = entry.value;
    result[key] = _convertYamlValue(value);
  }
  return result;
}

dynamic _convertYamlValue(dynamic value) {
  if (value is YamlMap) {
    return _yamlToMap(value);
  } else if (value is YamlList) {
    return value.map(_convertYamlValue).toList();
  } else {
    return value;
  }
}

/// Parse the client_cert field to TestCertType.
TestCertType parseCertType(dynamic value) {
  if (value == null) return TestCertType.none;
  switch (value.toString()) {
    case 'trusted':
      return TestCertType.trusted;
    case 'untrusted':
      return TestCertType.untrusted;
    case 'expired':
      return TestCertType.expired;
    case 'self_signed_unknown':
      return TestCertType.selfSignedUnknown;
    default:
      return TestCertType.none;
  }
}

/// Check if a value matches an expected pattern from the spec.
bool matchesExpected(dynamic actual, dynamic expected) {
  if (expected == null) return actual == null;

  if (expected is String) {
    // Handle matcher patterns
    if (expected == _kMatcherNonempty) {
      return actual is String && actual.isNotEmpty;
    }
    if (expected == _kMatcherPositiveInt) {
      return actual is int && actual > 0;
    }
    if (expected == _kMatcherIso8601) {
      if (actual is! String) return false;
      try {
        DateTime.parse(actual);
        return true;
      } catch (_) {
        return false;
      }
    }
    if (expected == _kMatcherUuid) {
      if (actual is! String) return false;
      final uuidRegex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        caseSensitive: false,
      );
      return uuidRegex.hasMatch(actual);
    }
    if (expected == _kMatcherAny) {
      return true; // Just check the key exists
    }
    if (expected.startsWith(_kMatcherContainsPrefix)) {
      final substring = expected.substring(_kMatcherContainsPrefix.length);
      return actual is String && actual.contains(substring);
    }
    if (expected.startsWith(_kMatcherRegexPrefix)) {
      final pattern = expected.substring(_kMatcherRegexPrefix.length);
      return actual is String && RegExp(pattern).hasMatch(actual);
    }
  }

  if (expected is Map && actual is Map) {
    for (final entry in expected.entries) {
      if (!actual.containsKey(entry.key)) {
        return false;
      }
      if (!matchesExpected(actual[entry.key], entry.value)) {
        return false;
      }
    }
    return true;
  }

  if (expected is List && actual is List) {
    if (expected.length != actual.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (!matchesExpected(actual[i], expected[i])) {
        return false;
      }
    }
    return true;
  }

  return actual == expected;
}

/// Parse response body as JSON.
Future<Map<String, dynamic>?> parseResponseBody(
  HttpClientResponse response,
) async {
  try {
    final body = await utf8.decodeStream(response);
    if (body.isEmpty) return null;
    return jsonDecode(body) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

void main() {
  group('Protocol Conformance Tests', () {
    late MtlsTestIdentities identities;

    setUpAll(() async {
      // Generate test identities once for all tests
      identities = await MtlsTestIdentities.generate();
    });

    group('YAML Spec Loading', () {
      test('can load health spec', () async {
        final spec = await loadTestSpec('health.yaml');
        expect(spec['endpoint'], equals('/health'));
        expect(spec['method'], equals('GET'));
        expect(spec['cases'], isA<List>());
        expect((spec['cases'] as List).isNotEmpty, isTrue);
      });

      test('can load unpair spec', () async {
        final spec = await loadTestSpec('unpair.yaml');
        expect(spec['endpoint'], equals('/unpair'));
        expect(spec['method'], equals('POST'));
      });

      test('can load noise subscribe spec', () async {
        final spec = await loadTestSpec('noise_subscribe.yaml');
        expect(spec['endpoint'], equals('/noise/subscribe'));
        expect(spec['method'], equals('POST'));
      });

      test('can load noise unsubscribe spec', () async {
        final spec = await loadTestSpec('noise_unsubscribe.yaml');
        expect(spec['endpoint'], equals('/noise/unsubscribe'));
        expect(spec['method'], equals('POST'));
      });

      test('can load websocket upgrade spec', () async {
        final spec = await loadTestSpec('websocket_upgrade.yaml');
        expect(spec['endpoint'], equals('/control/ws'));
        expect(spec['upgrade'], equals('websocket'));
      });

      test('can load mtls spec', () async {
        final spec = await loadTestSpec('mtls.yaml');
        expect(spec['endpoint'], equals('/*'));
      });
    });

    group('Matcher Tests', () {
      test(r'$nonempty matches non-empty strings', () {
        expect(matchesExpected('hello', _kMatcherNonempty), isTrue);
        expect(matchesExpected('', _kMatcherNonempty), isFalse);
        expect(matchesExpected(123, _kMatcherNonempty), isFalse);
      });

      test(r'$positive_int matches positive integers', () {
        expect(matchesExpected(1, _kMatcherPositiveInt), isTrue);
        expect(matchesExpected(100, _kMatcherPositiveInt), isTrue);
        expect(matchesExpected(0, _kMatcherPositiveInt), isFalse);
        expect(matchesExpected(-1, _kMatcherPositiveInt), isFalse);
        expect(matchesExpected('1', _kMatcherPositiveInt), isFalse);
      });

      test(r'$iso8601 matches valid ISO 8601 dates', () {
        expect(
          matchesExpected('2024-12-31T23:59:59Z', _kMatcherIso8601),
          isTrue,
        );
        expect(
          matchesExpected('2024-01-01T00:00:00.000Z', _kMatcherIso8601),
          isTrue,
        );
        expect(matchesExpected('not a date', _kMatcherIso8601), isFalse);
      });

      test(r'$uuid matches valid UUIDs', () {
        expect(
          matchesExpected(
            '550e8400-e29b-41d4-a716-446655440000',
            _kMatcherUuid,
          ),
          isTrue,
        );
        expect(matchesExpected('not-a-uuid', _kMatcherUuid), isFalse);
      });

      test(r'$any matches anything', () {
        expect(matchesExpected('anything', _kMatcherAny), isTrue);
        expect(matchesExpected(123, _kMatcherAny), isTrue);
        expect(matchesExpected(null, _kMatcherAny), isTrue);
        expect(matchesExpected({'nested': 'map'}, _kMatcherAny), isTrue);
      });

      test(r'$contains:text matches substrings', () {
        expect(
          matchesExpected('hello world', r'$contains:world'),
          isTrue,
        );
        expect(
          matchesExpected('hello world', r'$contains:foo'),
          isFalse,
        );
      });

      test(r'$regex:pattern matches regex patterns', () {
        expect(
          matchesExpected('ABC123', r'$regex:^[A-Z0-9]+$'),
          isTrue,
        );
        expect(
          matchesExpected('abc', r'$regex:^[A-Z]+$'),
          isFalse,
        );
      });

      test('nested map matching works', () {
        final actual = {
          'status': 'ok',
          'data': {
            'id': 'abc123',
            'count': 42,
          },
        };
        final expected = {
          'status': 'ok',
          'data': {
            'id': _kMatcherNonempty,
            'count': _kMatcherPositiveInt,
          },
        };
        expect(matchesExpected(actual, expected), isTrue);
      });
    });

    group('Health Endpoint (mTLS)', () {
      late ControlServer server;
      late int serverPort;
      late MtlsTestClient mtlsClient;

      setUp(() async {
        server = ControlServer(bindAddress: '127.0.0.1');

        final trustedPeer = TrustedPeer(
          remoteDeviceId: identities.trusted.deviceId,
          name: 'Trusted Listener',
          certFingerprint: identities.trusted.certFingerprint,
          addedAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          certificateDer: identities.trusted.certificateDer,
        );

        await server.start(
          port: 0, // Ephemeral port
          identity: identities.monitor,
          trustedPeers: [trustedPeer],
          // Add untrusted cert to TLS context so connection succeeds,
          // but it won't be in the trusted fingerprints list
          knownUntrustedCerts: [identities.untrusted.certificateDer],
        );

        serverPort = server.boundPort!;

        mtlsClient = MtlsTestClient(
          identities: identities,
          serverHost: '127.0.0.1',
          serverPort: serverPort,
        );
      });

      tearDown(() async {
        await server.stop();
      });

      test('health_no_client_cert: returns status ok without mTLS', () async {
        final response = await mtlsClient.request(
          method: 'GET',
          path: '/health',
          certType: TestCertType.none,
        );

        expect(response.statusCode, equals(200));
        expect(response.body, isNotNull);
        expect(response.body!['status'], equals('ok'));
        expect(response.body!['role'], equals('monitor'));
        expect(response.body!['mTLS'], equals(false));
        expect(response.body!['trusted'], equals(false));
      });

      test('health_with_untrusted_cert: shows mTLS true but trusted false',
          () async {
        final response = await mtlsClient.request(
          method: 'GET',
          path: '/health',
          certType: TestCertType.untrusted,
        );

        expect(response.statusCode, equals(200));
        expect(response.body, isNotNull);
        expect(response.body!['status'], equals('ok'));
        expect(response.body!['mTLS'], equals(true));
        expect(response.body!['trusted'], equals(false));
        expect(response.body!['clientFingerprint'], isNotEmpty);
      });

      test('health_with_trusted_cert: shows trusted true', () async {
        final response = await mtlsClient.request(
          method: 'GET',
          path: '/health',
          certType: TestCertType.trusted,
        );

        expect(response.statusCode, equals(200));
        expect(response.body, isNotNull);
        expect(response.body!['status'], equals('ok'));
        expect(response.body!['mTLS'], equals(true));
        expect(response.body!['trusted'], equals(true));
        expect(response.body!['clientFingerprint'], isNotEmpty);
        expect(response.body!['fingerprint'], isNotEmpty);
      });

      test('health_includes_uptime: has positive uptimeSec', () async {
        final response = await mtlsClient.request(
          method: 'GET',
          path: '/health',
          certType: TestCertType.none,
        );

        expect(response.statusCode, equals(200));
        expect(response.body, isNotNull);
        expect(response.body!['uptimeSec'], isA<int>());
        expect(response.body!['uptimeSec'] as int, greaterThanOrEqualTo(0));
      });

      test('health_includes_connection_count: has activeConnections', () async {
        final response = await mtlsClient.request(
          method: 'GET',
          path: '/health',
          certType: TestCertType.none,
        );

        expect(response.statusCode, equals(200));
        expect(response.body, isNotNull);
        expect(response.body!.containsKey('activeConnections'), isTrue);
      });
    });

    group('Unpair Endpoint (mTLS)', () {
      late ControlServer server;
      late int serverPort;
      late MtlsTestClient mtlsClient;
      String? lastUnpairFingerprint;
      String? lastUnpairDeviceId;

      setUp(() async {
        lastUnpairFingerprint = null;
        lastUnpairDeviceId = null;

        server = ControlServer(
          bindAddress: '127.0.0.1',
          onUnpairRequest: (fingerprint, deviceId) async {
            lastUnpairFingerprint = fingerprint;
            lastUnpairDeviceId = deviceId;
            return true;
          },
        );

        final trustedPeer = TrustedPeer(
          remoteDeviceId: identities.trusted.deviceId,
          name: 'Trusted Listener',
          certFingerprint: identities.trusted.certFingerprint,
          addedAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          certificateDer: identities.trusted.certificateDer,
        );

        await server.start(
          port: 0,
          identity: identities.monitor,
          trustedPeers: [trustedPeer],
          knownUntrustedCerts: [identities.untrusted.certificateDer],
        );

        serverPort = server.boundPort!;

        mtlsClient = MtlsTestClient(
          identities: identities,
          serverHost: '127.0.0.1',
          serverPort: serverPort,
        );
      });

      tearDown(() async {
        await server.stop();
      });

      test('unpair_no_cert: rejected without client certificate', () async {
        final response = await mtlsClient.request(
          method: 'POST',
          path: '/unpair',
          certType: TestCertType.none,
          body: {},
        );

        expect(response.statusCode, equals(401));
        expect(response.body, isNotNull);
        expect(response.body!['error'], equals('client_certificate_required'));
        expect(response.body!['message'], isNotEmpty);
      });

      test('unpair_untrusted_cert: rejected with untrusted certificate',
          () async {
        final response = await mtlsClient.request(
          method: 'POST',
          path: '/unpair',
          certType: TestCertType.untrusted,
          body: {},
        );

        expect(response.statusCode, equals(403));
        expect(response.body, isNotNull);
        expect(response.body!['error'], equals('certificate_not_trusted'));
        expect(response.body!['fingerprint'], isNotEmpty);
      });

      test('unpair_success_with_device_id: succeeds with trusted cert',
          () async {
        final response = await mtlsClient.request(
          method: 'POST',
          path: '/unpair',
          certType: TestCertType.trusted,
          body: {'deviceId': 'listener-device-123'},
        );

        expect(response.statusCode, equals(200));
        expect(response.body, isNotNull);
        expect(response.body!['status'], equals('ok'));
        expect(response.body!['unpaired'], equals(true));
        expect(lastUnpairFingerprint, equals(identities.trusted.certFingerprint));
        expect(lastUnpairDeviceId, equals('listener-device-123'));
      });

      test('unpair_success_without_device_id: succeeds without deviceId',
          () async {
        final response = await mtlsClient.request(
          method: 'POST',
          path: '/unpair',
          certType: TestCertType.trusted,
          body: {},
        );

        expect(response.statusCode, equals(200));
        expect(response.body, isNotNull);
        expect(response.body!['status'], equals('ok'));
        expect(response.body!['unpaired'], equals(true));
      });
    });

    group('Noise Subscribe Endpoint (mTLS)', () {
      late ControlServer server;
      late int serverPort;
      late MtlsTestClient mtlsClient;

      setUp(() async {
        server = ControlServer(
          bindAddress: '127.0.0.1',
          onNoiseSubscribe: ({
            required fingerprint,
            required fcmToken,
            required platform,
            required leaseSeconds,
            required remoteAddress,
            threshold,
            cooldownSeconds,
            autoStreamType,
            autoStreamDurationSec,
          }) async {
            final now = DateTime.now();
            final lease = leaseSeconds ?? 3600;
            return (
              deviceId: 'device-${fingerprint.substring(0, 8)}',
              subscriptionId: 'sub-${now.millisecondsSinceEpoch}',
              expiresAt: now.add(Duration(seconds: lease)),
              acceptedLeaseSeconds: lease,
            );
          },
        );

        final trustedPeer = TrustedPeer(
          remoteDeviceId: identities.trusted.deviceId,
          name: 'Trusted Listener',
          certFingerprint: identities.trusted.certFingerprint,
          addedAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          certificateDer: identities.trusted.certificateDer,
        );

        await server.start(
          port: 0,
          identity: identities.monitor,
          trustedPeers: [trustedPeer],
          knownUntrustedCerts: [identities.untrusted.certificateDer],
        );

        serverPort = server.boundPort!;

        mtlsClient = MtlsTestClient(
          identities: identities,
          serverHost: '127.0.0.1',
          serverPort: serverPort,
        );
      });

      tearDown(() async {
        await server.stop();
      });

      test('subscribe_no_cert: rejected without client certificate', () async {
        final response = await mtlsClient.request(
          method: 'POST',
          path: '/noise/subscribe',
          certType: TestCertType.none,
          body: {
            'fcmToken': 'token123',
            'platform': 'android',
          },
        );

        expect(response.statusCode, equals(401));
      });

      test('subscribe_untrusted_cert: rejected with untrusted certificate',
          () async {
        final response = await mtlsClient.request(
          method: 'POST',
          path: '/noise/subscribe',
          certType: TestCertType.untrusted,
          body: {
            'fcmToken': 'token123',
            'platform': 'android',
          },
        );

        expect(response.statusCode, equals(403));
      });

      test('subscribe_success_minimal: succeeds with required fields',
          () async {
        final response = await mtlsClient.request(
          method: 'POST',
          path: '/noise/subscribe',
          certType: TestCertType.trusted,
          body: {
            'fcmToken': 'token123',
            'platform': 'android',
          },
        );

        expect(response.statusCode, equals(200));
        expect(response.body, isNotNull);
        expect(response.body!['subscriptionId'], isNotEmpty);
        expect(response.body!['deviceId'], isNotEmpty);
        expect(response.body!['expiresAt'], isNotEmpty);
        expect(response.body!['acceptedLeaseSeconds'], isA<int>());
      });

      test('subscribe_success_with_lease: accepts custom lease duration',
          () async {
        final response = await mtlsClient.request(
          method: 'POST',
          path: '/noise/subscribe',
          certType: TestCertType.trusted,
          body: {
            'fcmToken': 'token123',
            'platform': 'android',
            'leaseSeconds': 7200,
          },
        );

        expect(response.statusCode, equals(200));
        expect(response.body, isNotNull);
        expect(response.body!['acceptedLeaseSeconds'], equals(7200));
      });
    });

    group('Noise Unsubscribe Endpoint (mTLS)', () {
      late ControlServer server;
      late int serverPort;
      late MtlsTestClient mtlsClient;

      setUp(() async {
        server = ControlServer(
          bindAddress: '127.0.0.1',
          onNoiseUnsubscribe: ({
            required fingerprint,
            fcmToken,
            subscriptionId,
            required remoteAddress,
          }) async {
            return (
              deviceId: 'device-${fingerprint.substring(0, 8)}',
              subscriptionId: subscriptionId,
              expiresAt: null,
              removed: fcmToken != 'nonexistent-token',
            );
          },
        );

        final trustedPeer = TrustedPeer(
          remoteDeviceId: identities.trusted.deviceId,
          name: 'Trusted Listener',
          certFingerprint: identities.trusted.certFingerprint,
          addedAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          certificateDer: identities.trusted.certificateDer,
        );

        await server.start(
          port: 0,
          identity: identities.monitor,
          trustedPeers: [trustedPeer],
          knownUntrustedCerts: [identities.untrusted.certificateDer],
        );

        serverPort = server.boundPort!;

        mtlsClient = MtlsTestClient(
          identities: identities,
          serverHost: '127.0.0.1',
          serverPort: serverPort,
        );
      });

      tearDown(() async {
        await server.stop();
      });

      test('unsubscribe_no_cert: rejected without client certificate', () async {
        final response = await mtlsClient.request(
          method: 'POST',
          path: '/noise/unsubscribe',
          certType: TestCertType.none,
          body: {'fcmToken': 'token123'},
        );

        expect(response.statusCode, equals(401));
      });

      test('unsubscribe_untrusted_cert: rejected with untrusted certificate',
          () async {
        final response = await mtlsClient.request(
          method: 'POST',
          path: '/noise/unsubscribe',
          certType: TestCertType.untrusted,
          body: {'fcmToken': 'token123'},
        );

        expect(response.statusCode, equals(403));
      });

      test('unsubscribe_by_fcm_token: succeeds with fcmToken', () async {
        final response = await mtlsClient.request(
          method: 'POST',
          path: '/noise/unsubscribe',
          certType: TestCertType.trusted,
          body: {'fcmToken': 'token123'},
        );

        expect(response.statusCode, equals(200));
        expect(response.body, isNotNull);
        expect(response.body!['deviceId'], isNotEmpty);
        expect(response.body!['unsubscribed'], equals(true));
      });

      test('unsubscribe_not_found: returns unsubscribed false when not found',
          () async {
        final response = await mtlsClient.request(
          method: 'POST',
          path: '/noise/unsubscribe',
          certType: TestCertType.trusted,
          body: {'fcmToken': 'nonexistent-token'},
        );

        expect(response.statusCode, equals(200));
        expect(response.body, isNotNull);
        expect(response.body!['unsubscribed'], equals(false));
      });
    });

    group('mTLS Fingerprint Verification', () {
      late ControlServer server;
      late int serverPort;
      late MtlsTestClient mtlsClient;

      setUp(() async {
        server = ControlServer(bindAddress: '127.0.0.1');

        final trustedPeer = TrustedPeer(
          remoteDeviceId: identities.trusted.deviceId,
          name: 'Trusted Listener',
          certFingerprint: identities.trusted.certFingerprint,
          addedAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          certificateDer: identities.trusted.certificateDer,
        );

        await server.start(
          port: 0,
          identity: identities.monitor,
          trustedPeers: [trustedPeer],
          knownUntrustedCerts: [identities.untrusted.certificateDer],
        );

        serverPort = server.boundPort!;

        mtlsClient = MtlsTestClient(
          identities: identities,
          serverHost: '127.0.0.1',
          serverPort: serverPort,
        );
      });

      tearDown(() async {
        await server.stop();
      });

      test('fingerprint matches trusted identity', () async {
        final response = await mtlsClient.request(
          method: 'GET',
          path: '/health',
          certType: TestCertType.trusted,
        );

        expect(response.statusCode, equals(200));
        expect(response.body!['clientFingerprint'],
            equals(identities.trusted.certFingerprint));
      });

      test('fingerprint matches untrusted identity', () async {
        final response = await mtlsClient.request(
          method: 'GET',
          path: '/health',
          certType: TestCertType.untrusted,
        );

        expect(response.statusCode, equals(200));
        expect(response.body!['clientFingerprint'],
            equals(identities.untrusted.certFingerprint));
      });

      test('server fingerprint is returned for trusted clients', () async {
        final response = await mtlsClient.request(
          method: 'GET',
          path: '/health',
          certType: TestCertType.trusted,
        );

        expect(response.statusCode, equals(200));
        expect(response.body!['fingerprint'],
            equals(identities.monitor.certFingerprint));
      });
    });
  });
}
