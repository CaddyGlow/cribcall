# Repository Guidelines

## Project Structure & Module Organization

### Dart/Flutter (`lib/`)
- `lib/src/control/` - mTLS WebSocket/HTTP control channel (ControlService, ControlClient, AndroidControlServer)
- `lib/src/discovery/` - mDNS service discovery (platform-specific implementations)
- `lib/src/fcm/` - Firebase Cloud Messaging for background notifications
- `lib/src/features/` - UI pages organized by role (landing, listener, monitor)
- `lib/src/identity/` - P-256 keys, X.509 certs, PKCS#8 encoding, secure storage
- `lib/src/notifications/` - Local notification service and action handling
- `lib/src/pairing/` - PAKE engine, QR payload parsing, PIN flow
- `lib/src/sound/` - Audio capture and RMS-based sound detection
- `lib/src/state/` - Riverpod providers and async controllers (app_state.dart)
- `lib/src/storage/` - Persistent repositories for settings and trusted devices
- `lib/src/webrtc/` - WebRTC session management and signaling

### Android Native (`android/app/src/main/kotlin/com/cribcall/cribcall/`)
- `MainActivity.kt` - Platform channel hub for all Flutter-native communication
- `AudioCaptureService.kt` - Foreground service for microphone capture + mDNS advertising
- `MonitorService.kt` - Foreground service hosting mTLS WebSocket server
- `MonitorTlsManager.kt` - TLS/certificate validation with P-256 ECDSA
- `ControlWebSocketServer.kt` - WebSocket upgrade, frame reading, HTTP routing
- `ControlMessageCodec.kt` - Length-prefixed JSON framing (matches Dart codec)

### Platform Channels
| Channel | Purpose |
|---------|---------|
| `cribcall/mdns` | mDNS discovery and advertising |
| `cribcall/audio` | Audio capture lifecycle |
| `cribcall/audio_playback` | Audio playback for listener |
| `cribcall/listener` | Listener foreground service |
| `cribcall/monitor_server` | Control server lifecycle and events |
| `cribcall/device_info` | Device identification |

### Configuration
- Specs live in `SPEC.md`; mirror its pairing/control rules in code
- Firebase config: `android/app/google-services.json` (not in git; use `.example` template)
- Assets/config: place generated keys/certs in app data, never in repo

## Build, Test, and Development Commands
```bash
flutter pub get          # Fetch dependencies
flutter analyze          # Lint Dart code
flutter test             # Run unit/widget tests
flutter test --coverage  # With coverage (for core logic changes)
flutter run -d linux     # Run on Linux desktop
flutter run -d android   # Run on Android device
```

### Scripts
- `scripts/rotate_api_keys.sh` - Rotate GCP/Firebase API keys
- `scripts/setup-virtual-mic.sh` - Create virtual microphone for Linux testing

## Coding Style & Naming Conventions

### Dart
- Format: `dart format` (2-space indent)
- State: Riverpod AsyncNotifier for async state, StateNotifier for sync
- Widgets: Immutable, use ConsumerWidget/ConsumerStatefulWidget
- Providers: Use `ref.watch()` for reactive, `ref.read()` for one-time access

### Naming
- `PascalCase` for widgets/types/classes
- `camelCase` for fields/methods/variables
- `snake_case` for native files and platform channel names
- Follow SPEC exactly for message types and field names (e.g., `certFingerprint`, `remoteDeviceId`)

### Kotlin (Android)
- Match Android/Kotlin conventions
- Use `ConcurrentHashMap` and `AtomicBoolean` for thread safety
- Foreground services require notification channels

## Testing Guidelines
- Tests in `test/` with `_test.dart` suffix
- Cover: sound detection (thresholds, cooldowns), JSON framing, RFC 8785 canonicalization, pinning rules, pairing transcripts
- Integration tests for control channel framing and NOISE_EVENT delivery
- New logic requires tests; update fixtures when schemas change
- Mock platform channels for unit tests

## Commit & Pull Request Guidelines
- Commits: small, scope-limited, imperative mood
  - `feat: add noise cooldown per listener`
  - `fix: handle certificate mismatch on reconnect`
  - `refactor: extract TLS validation to MonitorTlsManager`
- Keep WIP behind feature flags
- PRs: include summary, testing done, screenshots/logs for UX
- Link issues/tasks; call out risk areas (audio, pinning, FCM)
- Update `CHANGELOG.md` with task reference and description

## Security & Configuration

### Keys & Certificates
- Never commit keys/certs; generate per device at runtime
- P-256 ECDSA for device identity
- SHA-256 fingerprints for certificate pinning
- Pin server cert fingerprints from QR/mDNS before pairing

### Control Channel Security
- mTLS required for all post-pairing traffic
- Untrusted clients restricted to pairing messages only
- Trusted clients validated by certificate fingerprint
- HMAC-SHA256 auth tags on pairing transcripts

### Canonical JSON
- Use RFC 8785 for all signed/HMAC'd payloads
- Reject non-canonical forms on verification
- Use `canonical_json` package for serialization

### FCM Token Handling
- Bind tokens to authenticated fingerprints
- Reject mismatched deviceId claims
- Clean up superseded/invalid tokens
- WebSocket-only fallback for platforms without FCM

## State Management Patterns

### Provider Types (Riverpod)
- `AsyncNotifierProvider` - Async initialization with loading/error states
- `StateNotifierProvider` - Sync state with explicit updates
- `StreamProvider` - For event streams (mDNS, noise events)
- `FutureProvider` - One-time async computations

### Key Controllers
- `IdentityController` - Device identity lifecycle
- `AudioCaptureController` - Demand-driven audio capture
- `ControlServerController` - Monitor-side mTLS server
- `ControlClientController` - Listener-side WebSocket client
- `NoiseSubscriptionsController` - Per-listener subscription management
- `TrustedListenersController` / `TrustedMonitorsController` - Peer trust lists

### Demand-Driven Resources
Audio capture starts/stops based on:
- Active noise subscriptions
- Active streaming sessions
- Monitoring enabled state
