# Repository Guidelines

## Project Structure & Module Organization
- Flutter-first: keep UI/state in `lib/`, widget tests in `test/`.
- Platform code: Android in `android/` (foreground service, AudioRecord), Linux/native glue in `linux/` or `native/` (PulseAudio/ALSA, QUIC/WebRTC shims).
- Specs live in `SPEC.md`; mirror its pairing/control rules in code.
- Assets/config: place generated keys/certs in app data, never in repo.

## Build, Test, and Development Commands
- `flutter pub get` – fetch dependencies.
- `flutter analyze` – lint Dart.
- `flutter test` – run unit/widget tests; add `--coverage` when touching core logic.
- Android smoke (when available): `flutter test --platform android` or Gradle task for instrumentation; Linux: run CLI harness/tests in `linux/` as added.

## Coding Style & Naming Conventions
- Dart: `dart format` (2-space indent), prefer idiomatic Flutter patterns (widgets immutable, state via provider/riverpod/bloc per module choice).
- Native C/C++/Rust shims: match platform defaults; use clang-format/rustfmt if present.
- Names: `PascalCase` for widgets/types, `camelCase` for fields/methods, `snake_case` for native files. Avoid abbreviations in message/field names.
- Follow SPEC for message types and field names exactly (e.g., `monitorCertFingerprint`).

## Testing Guidelines
- Tests co-locate under `test/` with `_test.dart` suffix; native tests live beside native code.
- Cover: sound detection thresholds/cooldowns, JSON framing/canonicalization (RFC 8785), pinning rules, and pairing transcripts.
- Add integration tests for control channel framing and `NOISE_EVENT` delivery on Linux when possible.
- New logic requires tests; update fixtures when schemas change.

## Commit & Pull Request Guidelines
- Commits: small, scope-limited, imperative mood (e.g., “feat: wire capture to detector”). Commit per phase; keep WIP behind flags.
- PRs: include summary, testing done (`flutter analyze`, `flutter test`, native checks), and any screenshots/logs for UX changes. Link issues/tasks; call out risk areas (audio capture, pinning).
- Change log: every change must update the changelog file (or release notes) with task/ticket reference and concrete description of what changed. Reference the active plan/task ID in the entry.

## Security & Configuration Tips
- Never commit keys/certs; generate per device at runtime. Pin server cert fingerprints from QR/mDNS before pairing.
- Use RFC 8785 canonical JSON for any signed/HMAC’d payloads; reject non-canonical forms on verification.
- Enforce control-channel rules: untrusted clients pairing-only; trusted clients mTLS+pinned fingerprints.
