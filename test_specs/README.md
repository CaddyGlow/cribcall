# Protocol Conformance Test Specifications

This directory contains language-agnostic test specifications for the control server protocol.
Both Dart and Kotlin implementations must pass all tests defined here.

## Directory Structure

```
test_specs/
  protocol/
    health.yaml           # GET /health endpoint
    unpair.yaml           # POST /unpair endpoint
    noise_subscribe.yaml  # POST /noise/subscribe endpoint
    noise_unsubscribe.yaml # POST /noise/unsubscribe endpoint
    websocket_upgrade.yaml # GET /control/ws upgrade
    websocket_messages.yaml # WebSocket frame handling
    mtls.yaml             # mTLS certificate validation
```

## Spec Format

Each YAML file defines test cases for a specific endpoint or feature.

### Top-Level Fields

| Field | Type | Description |
|-------|------|-------------|
| `endpoint` | string | HTTP path (e.g., `/health`) |
| `method` | string | HTTP method (GET, POST) |
| `description` | string | What this spec tests |
| `cases` | array | List of test cases |

### Test Case Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Unique identifier (snake_case) |
| `description` | string | Human-readable description |
| `setup` | object | Optional server-side setup |
| `request` | object | Request configuration |
| `expect` | object | Expected response |

### Request Fields

| Field | Type | Description |
|-------|------|-------------|
| `client_cert` | string/null | Certificate to use: `trusted`, `untrusted`, `expired`, or `null` |
| `headers` | object | Additional HTTP headers |
| `body` | object | JSON request body |

### Expect Fields

| Field | Type | Description |
|-------|------|-------------|
| `status` | int | Expected HTTP status code |
| `headers` | object | Expected response headers |
| `body` | object | Expected JSON response body |

### Special Matchers

Use these in `expect` values for dynamic matching:

| Matcher | Description |
|---------|-------------|
| `$nonempty` | Any non-empty string |
| `$positive_int` | Any integer > 0 |
| `$iso8601` | Valid ISO 8601 datetime string |
| `$uuid` | Valid UUID format |
| `$contains:text` | String containing "text" |
| `$regex:pattern` | String matching regex pattern |
| `$any` | Any value (just check key exists) |

## Running Tests

### Dart
```bash
dart test test/protocol_conformance_test.dart
```

### Kotlin
```bash
cd android && ./gradlew test --tests "ProtocolConformanceTest"
```

## Adding New Tests

1. Add test case to appropriate `.yaml` file
2. Run both Dart and Kotlin tests
3. Both must pass before merging
