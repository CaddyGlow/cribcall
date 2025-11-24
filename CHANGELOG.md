# Changelog

## Unreleased
- Task: SPEC-boot — Scaffolded Flutter app, added QUIC control/pairing data models with canonical transcript + framing helpers, and built monitor/listener shells matching SPEC v0.2 (tests cover canonical JSON, HMAC auth tags, and frame parsing).
- Task: build-linux-sysprof — Added sysprof dev dependency to Nix shell and documented pkg-config fix for `sysprof-capture-4` when building Linux artifacts.
- Task: build-fix-linux — Updated CardTheme to CardThemeData and pulled Riverpod legacy providers so Flutter 3.38 Linux builds succeed; reran tests.
- Task: spec-state-models — Added SPEC-aligned domain models (QR payloads, mDNS ads, noise settings), Riverpod Notifier state for roles/settings, UI wiring, and unit tests for models/state defaults.
- Task: identity-ed25519 — Implemented Ed25519 self-signed X.509 generation with SHA-256 fingerprinting + subjectAltName (cribcall:<deviceId>), wired identity into dashboards, and added certificate parsing tests.
- Task: identity-storage-service — Added persisted identity repository (filesystem) with tests, service identity builder for QR/mDNS payloads, and UI wiring to render live pairing payloads.
- Task: sound-detector — Implemented RMS-based sound detector core with threshold/min-duration/cooldown per SPEC and added unit coverage.
- Task: qr-mdns-secure-store — Added QR scanning flow on listener, service identity QR rendering, mDNS channel stubs, secure identity storage abstraction (prefers secure storage on mobile), and tests for service identity and sound detection.
