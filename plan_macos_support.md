# macOS Support Plan

Goal: ship macOS desktop parity with Android listener/monitor roles while honoring SPEC constraints (pairing, mTLS, canonical JSON) and keeping native surface area minimal.

## Scope and constraints
- Target macOS 12+; validate Intel + Apple Silicon builds and Rosetta behavior.
- Stay unsandboxed initially; enumerate required entitlements (microphone, camera, local network, outbound sockets, incoming connections if hosting server).
- No secrets/certs in repo; store per-device keys/certs in app data/Keychain.
- Keep feature-flag guard for macOS until parity and QA complete.

## Platform channels and native surface
- `cribcall/mdns`: Swift implementation using `NetService`/DNSService APIs; parity with Android JSON shapes and advertising rules from SPEC.
- `cribcall/audio`: AVAudioEngine/CoreAudio capture with RMS stats; permission prompt on first use; expose start/stop + level callbacks matching Dart expectations.
- `cribcall/audio_playback`: AVAudioPlayer/AudioQueue playback; volume/mute controls aligned with listener UI.
- `cribcall/listener`: manage long-lived listener lifecycle; map to a background-friendly model (app stays active with menu bar indicator if needed).
- `cribcall/monitor_server`: host mTLS control server; bind advertised port; feed certificate fingerprints; surface events/errors consistent with Android channel.
- `cribcall/device_info`: expose stable deviceId (Keychain-backed UUID), model name, OS/version.
- Decide pure-Dart vs. Swift per channel; prefer Dart where APIs exist (e.g., WebSocket client) and native only when needed (audio, mDNS, server sockets with certs).

## Audio capture and noise detection
- Permissions: request mic (and camera if WebRTC video); document prompts and failure states.
- Capture: AVAudioEngine input node with desired sample rate/channel; route RMS frames to existing Dart noise detector; ensure low-latency buffer sizes.
- Echo/feedback: configure audio session/category to avoid playback bleed when in listener role; test headphones vs. speakers.
- Virtual mic/testing: script or doc path using BlackHole/Soundflower for loopback validation.

## Networking, discovery, and control channel
- mDNS advertise/resolve via `NetService`; ensure TTL, service type, TXT payloads match SPEC; handle multiple interfaces (Wi-Fi/Ethernet).
- mTLS control server/client: use Security framework for P-256 keys/certs; store identity in Keychain; pin fingerprints from QR/mDNS; ensure canonical JSON framing enforcement.
- WebSocket/HTTP server for control: confirm socket binding permissions on macOS; support idle timeout, heartbeat, and trust gates identical to Android.
- QUIC/WebRTC signaling: reuse existing Dart/Rust pipeline; verify native dependencies build on macOS (via Cargokit/FFI) and handle cert validation on client side.

## WebRTC media
- Confirm `flutter_webrtc` macOS support; handle camera/mic permission prompts; ensure ICE host candidates work on LAN without relay.
- Audio playback path: align jitter/buffer settings with Android defaults; verify sample rate conversion if needed.
- Video (if enabled): test window embedding and render performance on Intel/Apple Silicon; consider hardware acceleration flags.

## Notifications
- Local notifications/actions via UserNotifications; map existing action identifiers and payload shapes.
- Foreground/background behavior: ensure alerts while app in background; document any limitations (no true background services).
- Badge/sound control aligned with Android notification semantics.

## Identity, storage, and persistence
- Key storage: generate/store P-256 keypair + cert in Keychain; persist fingerprints/trusted devices in app data directory.
- File locations: choose app support directory for cached certs/config; ensure cleanup on unpairing/uninstall.
- Canonical JSON: validate `canonical_json` package works on macOS; add tests if platform-specific issues arise.

## Build, signing, and distribution
- Xcode target: enable macOS in Flutter; set bundle id, deployment target, entitlements (mic, camera, local network, incoming connections), and hardened runtime flags.
- Codesigning: use ad-hoc for dev; plan Developer ID cert for distribution; notarization pipeline for release builds.
- Packaging: DMG/ZIP with launch instructions; include first-run permission prompt expectations.
- CI: add macOS job to run `flutter pub get`, `flutter analyze`, `flutter test`, and a smoke `flutter build macos`.

## Testing and validation
- Matrix: macOS 12/13/14 on Intel and Apple Silicon; Wi-Fi vs. Ethernet; NAT vs. same subnet scenarios.
- Manual scenarios: pairing via QR/mDNS, fingerprint mismatch handling, monitor hosting control server, listener reconnect, noise event flow, notification actions.
- Automated: expand unit/widget tests to cover macOS where platform channels are mocked; add integration tests for mDNS discovery and control handshake where feasible.
- Performance: measure CPU/memory for audio capture + WebRTC; verify latency comparable to Android targets.

## Milestones
- M1: Enable Flutter macOS build, get app launching with feature flag, device_info channel stubbed.
- M2: mDNS discovery/advertising + control channel (mTLS server/client) functional on LAN with pinning.
- M3: Audio capture/playback and noise detection parity; notifications wired.
- M4: WebRTC audio/video path validated; permissions UX polished.
- M5: QA, CI, packaging/notarization, documentation, and feature flag removal.

## Documentation
- Add macOS setup guide (brew deps, Xcode tools, signing, virtual mic), permission prompt glossary, and known differences vs. Android.
- Update SPEC/README/CHANGELOG with macOS support scope, feature flag, and testing status.
