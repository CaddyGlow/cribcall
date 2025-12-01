# CribCall

Local-only baby monitor using mTLS HTTP+WebSocket control channels and WebRTC for media. Supports Android and Linux with audio capture, sound detection, and push notifications, plus a macOS preview target (mDNS is stubbed while native code lands). See `SPEC.md` for the full product and protocol specification.

## Features

### Current Implementation
- **Dual-role architecture**: Monitor (baby's room) and Listener (parent's device) on the same LAN
- **Sound detection**: RMS-based noise detection with configurable threshold, min-duration, and cooldown
- **Noise events**: Delivered via WebSocket (primary) with FCM fallback for backgrounded listeners
- **Secure pairing**: QR code scanning or numeric comparison (P-256 ECDH) with certificate pinning
- **mTLS control channel**: Mutual TLS with SHA-256 fingerprint validation
- **mDNS discovery**: Automatic monitor discovery on local network
- **Audio capture**: Platform-specific implementations (Android AudioRecord, Linux PipeWire/PulseAudio)
- **WebRTC signaling**: Offer/answer/ICE exchange over control channel
- **Push notifications**: Firebase Cloud Messaging for offline noise alerts
- **Background operation**: Android foreground services for continuous monitoring
- **Per-listener settings**: Individual noise thresholds and cooldowns per subscription

### Planned
- Full WebRTC audio streaming
- Video support
- iOS platform

## Getting Started

### Development Environment

**Nix (recommended)**:
```bash
nix develop   # or: direnv allow
```

The Nix shell includes:
- Flutter SDK and Dart
- Android SDK (28-36), NDK, build tools
- Rust toolchain (via rustup)
- PulseAudio/PipeWire, GTK3, OpenGL for Linux desktop
- Google Cloud SDK for Firebase operations

**Manual setup**:
- Flutter 3.10+
- Android SDK with NDK
- For Linux: libsecret, gtk3, alsa-lib, pulseaudio

### Build Commands
```bash
flutter pub get       # Install dependencies
flutter analyze       # Lint Dart code
flutter test          # Run unit/widget tests
flutter run -d linux  # Run on Linux desktop
flutter run -d android  # Run on connected Android device
```

### macOS (preview)
- Requires Xcode + CocoaPods (`sudo xcode-select --install` then `sudo gem install cocoapods`).
- Run `flutter run -d macos`; entitlements are unsandboxed for now while microphone/local network permissions and incoming connections are documented.
- mDNS is currently a no-op on macOS; pair by entering QR JSON manually or using direct IPs until the native NetService implementation lands.

### Firebase Setup
Copy and configure your Firebase project:
```bash
cp android/app/google-services.json.example android/app/google-services.json
# Edit with your Firebase project credentials
```

### Testing Audio (Linux)
```bash
./scripts/setup-virtual-mic.sh  # Create virtual microphone for testing
```

## Architecture

### Directory Structure
```
lib/
  src/
    control/       # mTLS WebSocket/HTTP control channel
    discovery/     # mDNS service discovery
    fcm/           # Firebase Cloud Messaging
    features/      # UI pages (landing, listener, monitor)
    identity/      # P-256 keys, X.509 certs, secure storage
    notifications/ # Local notification handling
    pairing/       # PAKE engine, QR parsing, PIN flow
    sound/         # Audio capture, sound detection
    state/         # Riverpod providers and controllers
    storage/       # Persistent settings repositories
    webrtc/        # WebRTC session management
android/
  app/src/main/kotlin/com/cribcall/cribcall/
    MainActivity.kt           # Platform channel hub
    AudioCaptureService.kt    # Foreground service for mic
    MonitorService.kt         # mTLS WebSocket server
    MonitorTlsManager.kt      # TLS/certificate handling
    ControlWebSocketServer.kt # WebSocket protocol
    ControlMessageCodec.kt    # Length-prefixed JSON framing
```

### Key Technologies
- **State management**: Riverpod (async notifiers, providers)
- **Routing**: GoRouter with shell routes
- **Cryptography**: P-256 ECDSA, HMAC-SHA256, canonical JSON (RFC 8785)
- **Networking**: dart:io HttpClient/WebSocket, Android NSD/NsdManager
- **Audio**: Android AudioRecord, Linux PipeWire (pw-record subprocess)

### Control Channel
- Monitor hosts mTLS WebSocket server on configurable port (default 48080)
- Listener connects with client certificate; fingerprint must be in trusted list
- Messages are 4-byte length-prefixed JSON (big-endian)
- Canonical JSON (RFC 8785) for HMAC'd payloads
- HTTP endpoints: `/health`, `/noise/subscribe`, `/noise/unsubscribe`, `/unpair`

### Security Model
- Self-signed P-256 certificates with SHA-256 fingerprints
- Certificate pinning from QR/mDNS before any connection
- mTLS for all post-pairing control traffic
- HMAC-SHA256 auth tags on pairing transcripts
- No cloud backend; all data stays on LAN

## Contributing
- Read `SPEC.md` for protocol requirements and `AGENTS.md` for coding guidelines
- Keep commits small with imperative mood messages (e.g., "feat: add noise cooldown")
- Write tests for new logic; update fixtures when schemas change
- Update `CHANGELOG.md` with task reference and description
- Never commit keys/certs; use runtime generation

## License
MIT - see `LICENSE`.
