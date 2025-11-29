# Protocol Conformance Tests

## Goal

Ensure the Dart (`control_server.dart`) and Kotlin (`ControlWebSocketServer.kt`) implementations behave identically for all protocol operations.

## Current State

### Existing Dart Tests
- `http_transport_test.dart` - Health endpoint, mTLS handshake
- `control_channel_test.dart` - Message framing, state transitions (uses fakes)
- `control_unpair_test.dart` - Unpair endpoint e2e
- `noise_subscriptions_test.dart` - Subscription logic (not server tests)

### Missing
- No Kotlin tests at all
- No cross-platform conformance tests
- No WebSocket protocol tests
- No noise subscribe/unsubscribe endpoint tests

---

## Test Strategy

### Approach: Shared Test Specifications

Define test cases in a language-agnostic format (JSON/YAML), then run identical tests against both implementations.

```
test_specs/
  protocol/
    health_endpoint.yaml
    unpair_endpoint.yaml
    noise_subscribe.yaml
    noise_unsubscribe.yaml
    websocket_upgrade.yaml
    websocket_messages.yaml
    mtls_validation.yaml

test/
  protocol_conformance_test.dart    # Runs specs against Dart server

android/app/src/test/kotlin/
  ProtocolConformanceTest.kt        # Runs specs against Kotlin server
```

---

## Test Specifications

### 1. Health Endpoint (`/health`)

```yaml
endpoint: /health
method: GET

cases:
  - name: health_no_client_cert
    description: Health endpoint accessible without client certificate
    request:
      client_cert: null
    expect:
      status: 200
      body:
        status: ok
        role: monitor
        protocol: http-ws
        mTLS: false
        trusted: false

  - name: health_with_untrusted_cert
    description: Health shows mTLS true but trusted false for unknown cert
    request:
      client_cert: untrusted_client
    expect:
      status: 200
      body:
        status: ok
        mTLS: true
        trusted: false

  - name: health_with_trusted_cert
    description: Health shows trusted true for known peer
    request:
      client_cert: trusted_client
    expect:
      status: 200
      body:
        status: ok
        mTLS: true
        trusted: true
```

### 2. Unpair Endpoint (`/unpair`)

```yaml
endpoint: /unpair
method: POST

cases:
  - name: unpair_no_cert
    description: Unpair rejected without client certificate
    request:
      client_cert: null
      body: {}
    expect:
      status: 401
      body:
        error: client_certificate_required

  - name: unpair_untrusted_cert
    description: Unpair rejected with untrusted certificate
    request:
      client_cert: untrusted_client
      body: {}
    expect:
      status: 403
      body:
        error: certificate_not_trusted

  - name: unpair_success
    description: Unpair succeeds with trusted certificate
    request:
      client_cert: trusted_client
      body:
        deviceId: listener-device-123
    expect:
      status: 200
      body:
        status: ok
        unpaired: true
        deviceId: listener-device-123

  - name: unpair_not_found
    description: Unpair returns unpaired false when device not found
    setup:
      unpair_handler_returns: false
    request:
      client_cert: trusted_client
      body:
        deviceId: unknown-device
    expect:
      status: 200
      body:
        status: ok
        unpaired: false
        reason: device_not_found
```

### 3. Noise Subscribe Endpoint (`/noise/subscribe`)

```yaml
endpoint: /noise/subscribe
method: POST

cases:
  - name: subscribe_no_cert
    description: Subscribe rejected without client certificate
    request:
      client_cert: null
      body:
        fcmToken: token123
        platform: android
    expect:
      status: 401
      body:
        error: unauthenticated

  - name: subscribe_untrusted_cert
    description: Subscribe rejected with untrusted certificate
    request:
      client_cert: untrusted_client
      body:
        fcmToken: token123
        platform: android
    expect:
      status: 403
      body:
        error: untrusted

  - name: subscribe_missing_fcm_token
    description: Subscribe rejected when fcmToken missing
    request:
      client_cert: trusted_client
      body:
        platform: android
    expect:
      status: 400
      body:
        error: invalid_fcm_token

  - name: subscribe_missing_platform
    description: Subscribe rejected when platform missing
    request:
      client_cert: trusted_client
      body:
        fcmToken: token123
    expect:
      status: 400
      body:
        error: invalid_platform

  - name: subscribe_success_minimal
    description: Subscribe succeeds with minimal required fields
    request:
      client_cert: trusted_client
      body:
        fcmToken: token123
        platform: android
    expect:
      status: 200
      body:
        subscriptionId: $nonempty
        deviceId: $nonempty
        expiresAt: $iso8601
        acceptedLeaseSeconds: $positive_int

  - name: subscribe_success_with_options
    description: Subscribe succeeds with all optional fields
    request:
      client_cert: trusted_client
      body:
        fcmToken: token123
        platform: android
        leaseSeconds: 7200
        threshold: 50
        cooldownSeconds: 10
        autoStreamType: audio
        autoStreamDurationSec: 30
    expect:
      status: 200
      body:
        subscriptionId: $nonempty
        deviceId: $nonempty
        expiresAt: $iso8601
        acceptedLeaseSeconds: 7200

  - name: subscribe_rejects_deviceId_field
    description: Subscribe rejects explicit deviceId (derived from cert)
    request:
      client_cert: trusted_client
      body:
        fcmToken: token123
        platform: android
        deviceId: spoofed-id
    expect:
      status: 400
      body:
        error: device_id_forbidden

  - name: subscribe_rejects_unknown_fields
    description: Subscribe rejects unknown fields
    request:
      client_cert: trusted_client
      body:
        fcmToken: token123
        platform: android
        unknownField: value
    expect:
      status: 400
      body:
        error: unknown_fields
        fields:
          - unknownField
```

### 4. Noise Unsubscribe Endpoint (`/noise/unsubscribe`)

```yaml
endpoint: /noise/unsubscribe
method: POST

cases:
  - name: unsubscribe_no_cert
    description: Unsubscribe rejected without client certificate
    request:
      client_cert: null
      body:
        fcmToken: token123
    expect:
      status: 401
      body:
        error: unauthenticated

  - name: unsubscribe_missing_identifier
    description: Unsubscribe rejected when neither fcmToken nor subscriptionId provided
    request:
      client_cert: trusted_client
      body: {}
    expect:
      status: 400
      body:
        error: missing_identifier

  - name: unsubscribe_by_fcm_token
    description: Unsubscribe by fcmToken
    request:
      client_cert: trusted_client
      body:
        fcmToken: token123
    expect:
      status: 200
      body:
        deviceId: $nonempty
        unsubscribed: true

  - name: unsubscribe_by_subscription_id
    description: Unsubscribe by subscriptionId
    request:
      client_cert: trusted_client
      body:
        subscriptionId: sub-123
    expect:
      status: 200
      body:
        deviceId: $nonempty
        unsubscribed: true
```

### 5. WebSocket Upgrade (`/control/ws`)

```yaml
endpoint: /control/ws
method: GET
upgrade: websocket

cases:
  - name: ws_upgrade_no_cert
    description: WebSocket upgrade rejected without client certificate
    request:
      client_cert: null
      headers:
        Upgrade: websocket
        Connection: Upgrade
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
        Sec-WebSocket-Version: 13
    expect:
      status: 401

  - name: ws_upgrade_untrusted_cert
    description: WebSocket upgrade rejected with untrusted certificate
    request:
      client_cert: untrusted_client
      headers:
        Upgrade: websocket
        Connection: Upgrade
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
        Sec-WebSocket-Version: 13
    expect:
      status: 403

  - name: ws_upgrade_success
    description: WebSocket upgrade succeeds with trusted certificate
    request:
      client_cert: trusted_client
      headers:
        Upgrade: websocket
        Connection: Upgrade
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
        Sec-WebSocket-Version: 13
    expect:
      status: 101
      headers:
        Upgrade: websocket
        Connection: Upgrade
        Sec-WebSocket-Accept: $nonempty
```

### 6. WebSocket Messages

```yaml
transport: websocket

cases:
  - name: ws_ping_pong
    description: Server sends pong in response to ping
    send:
      opcode: ping
      payload: hello
    expect:
      opcode: pong
      payload: hello

  - name: ws_text_message
    description: Server receives and can respond to text messages
    send:
      opcode: text
      payload: '{"type":"ping","timestamp":12345}'
    expect:
      # Server may or may not respond to ping; just verify no error

  - name: ws_binary_message
    description: Server handles binary frames (length-prefixed JSON)
    send:
      opcode: binary
      payload: $length_prefixed_json('{"type":"ping","timestamp":12345}')
    expect:
      # Verify message received by server

  - name: ws_close_frame
    description: Server responds to close frame
    send:
      opcode: close
      payload: ""
    expect:
      connection_closed: true
```

### 7. mTLS Validation

```yaml
transport: tls

cases:
  - name: mtls_valid_trusted_cert
    description: Connection succeeds with valid trusted certificate
    client_cert: trusted_client
    expect:
      handshake: success
      can_access_protected_endpoints: true

  - name: mtls_valid_untrusted_cert
    description: Connection succeeds but endpoints reject untrusted cert
    client_cert: untrusted_client
    expect:
      handshake: success
      can_access_protected_endpoints: false

  - name: mtls_expired_cert
    description: Connection rejected with expired certificate
    client_cert: expired_client
    expect:
      handshake: failure
      error: certificate_expired

  - name: mtls_self_signed_not_in_truststore
    description: Connection works but not trusted
    client_cert: self_signed_unknown
    expect:
      handshake: success
      can_access_protected_endpoints: false
```

---

## Implementation Plan

### Phase 1: Create Test Spec Format

1. Define YAML schema for test cases
2. Create parser in Dart
3. Create parser in Kotlin

### Phase 2: Dart Test Runner

File: `test/protocol_conformance_test.dart`

```dart
import 'dart:io';
import 'package:yaml/yaml.dart';
import 'package:test/test.dart';

void main() {
  final specFiles = Directory('test_specs/protocol')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.yaml'));

  for (final specFile in specFiles) {
    final spec = loadYaml(specFile.readAsStringSync());
    final endpoint = spec['endpoint'] as String;

    group(endpoint, () {
      for (final testCase in spec['cases']) {
        test(testCase['name'], () async {
          // 1. Start Dart ControlServer
          // 2. Setup test identities (trusted, untrusted, etc.)
          // 3. Make request according to testCase
          // 4. Assert response matches expected
        });
      }
    });
  }
}
```

### Phase 3: Kotlin Test Runner

File: `android/app/src/test/kotlin/com/cribcall/cribcall/ProtocolConformanceTest.kt`

```kotlin
class ProtocolConformanceTest {
    @ParameterizedTest
    @MethodSource("loadTestSpecs")
    fun runConformanceTest(testCase: TestCase) {
        // 1. Start Kotlin ControlWebSocketServer
        // 2. Setup test identities
        // 3. Make request according to testCase
        // 4. Assert response matches expected
    }

    companion object {
        @JvmStatic
        fun loadTestSpecs(): Stream<TestCase> {
            // Parse YAML specs from test_specs/protocol/
        }
    }
}
```

### Phase 4: CI Integration

```yaml
# .github/workflows/test.yml
jobs:
  dart-conformance:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
      - run: dart test test/protocol_conformance_test.dart

  kotlin-conformance:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
      - run: cd android && ./gradlew test --tests "ProtocolConformanceTest"
```

---

## Priority Order

1. **High Priority** - These endpoints have complex validation logic:
   - `/noise/subscribe` - Many edge cases, field validation
   - `/noise/unsubscribe` - Multiple identifier types
   - mTLS validation - Security critical

2. **Medium Priority** - Important but simpler:
   - `/unpair` - Already has Dart tests
   - `/health` - Simple but good baseline
   - WebSocket upgrade - Critical path

3. **Lower Priority** - Can add later:
   - WebSocket message framing - Mostly tested by usage
   - Connection lifecycle - Edge cases

---

## Estimated Effort

| Task | Effort |
|------|--------|
| Define YAML spec format | 2 hours |
| Write test specs (~30 cases) | 4 hours |
| Dart test runner | 4 hours |
| Kotlin test runner | 6 hours |
| CI integration | 2 hours |
| **Total** | **~18 hours** |

---

## Open Questions

1. Should specs live in `test_specs/` or alongside each test file?
2. Use YAML or JSON for specs? (YAML more readable, JSON simpler to parse)
3. How to handle server-side setup (mock handlers vs real logic)?
4. Should we also test response body canonicalization (JSON key ordering)?
