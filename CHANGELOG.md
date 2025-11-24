# Changelog

## Unreleased
- Task: quic-cargokit (plan_quic) — Added Rust toolchain (rustc/cargo/rustfmt/clippy) and BoringSSL build deps to Nix dev shell to support quiche + Cargokit work.
- Task: quic-cargokit (plan_quic) — Implemented Rust/quiche Cargokit FFI plugin with multi-connection server/client loops, trusted-listener enforcement via fingerprint allowlist, Dart bindings (event stream + config), identity-to-PEM helpers, and native QUIC transport wiring stubs for control channel.
- Task: remove-flutter-quic — Removed flutter_quic dependency and stubbed QUIC control transport pending a native implementation.
- Task: android-deploy-script — Added `bin/deploy_android.sh` to build Flutter APKs, install over ADB, and launch `com.cribcall.cribcall`.
- Task: quic-flutter-quic — Integrated flutter_quic for control transport scaffolding (client connect + server config), added PKCS#8 export for Ed25519 identities, and guarded init via RustLib (initial experiment later removed; see remove-flutter-quic).
- Task: remove-native-spake2 — Removed the optional SPAKE2+ native bindings (libspake2_ffi C shim, Android CMake wiring, platform method channels) and aligned PIN pairing UI to the Dart PAKE path.
- Task: mdns-native — Implemented mDNS advertise/browse via Android NSD, iOS NetService, and Linux (multicast_dns + avahi publish); wired real browse events into providers to persist last-known IPs.
- Task: pin-pairing-ui — Added PIN pairing controller with Dart PAKE plumbing, monitor PIN display, listener PIN entry sheet, and persisted trusted listeners/monitors with revoke confirmations.
- Task: settings-persistence — Added disk-backed monitor/listener settings with async controllers, monitor dashboard sliders/name editing/auto-stream selectors, listener notification defaults, and trusted monitor revocation + last-known-IP updates from mDNS browse (with tests).
- Task: linux-build-warnings — Relaxed Linux CMake flags to avoid treating plugin (json.hpp) warnings as errors so `flutter run -d linux` succeeds with flutter_secure_storage.
- Task: SPEC-boot — Scaffolded Flutter app, added QUIC control/pairing data models with canonical transcript + framing helpers, and built monitor/listener shells matching SPEC v0.2 (tests cover canonical JSON, HMAC auth tags, and frame parsing).
- Task: build-linux-sysprof — Added sysprof dev dependency to Nix shell and documented pkg-config fix for `sysprof-capture-4` when building Linux artifacts.
- Task: build-fix-linux — Updated CardTheme to CardThemeData and pulled Riverpod legacy providers so Flutter 3.38 Linux builds succeed; reran tests.
- Task: spec-state-models — Added SPEC-aligned domain models (QR payloads, mDNS ads, noise settings), Riverpod Notifier state for roles/settings, UI wiring, and unit tests for models/state defaults.
- Task: identity-ed25519 — Implemented Ed25519 self-signed X.509 generation with SHA-256 fingerprinting + subjectAltName (cribcall:<deviceId>), wired identity into dashboards, and added certificate parsing tests.
- Task: identity-storage-service — Added persisted identity repository (filesystem) with tests, service identity builder for QR/mDNS payloads, and UI wiring to render live pairing payloads.
- Task: sound-detector — Implemented RMS-based sound detector core with threshold/min-duration/cooldown per SPEC and added unit coverage.
- Task: qr-mdns-secure-store — Added QR scanning flow on listener, service identity QR rendering, mDNS channel stubs, secure identity storage abstraction (prefers secure storage on mobile), and tests for service identity and sound detection.
