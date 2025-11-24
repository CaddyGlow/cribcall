# CribCall

Local-only baby monitor using QUIC for control and WebRTC for media. Android/Linux focus for the first milestone (audio + sound detection only). See `SPEC.md` for the full product and protocol specification.

## Features (milestone scope)
- Monitor/listener roles on the same LAN.
- Sound detection on the monitor with configurable thresholds.
- Noise events delivered over a QUIC control channel.
- Audio-only monitoring initially; video later.

## Getting Started
- Dev env (Nix): `nix develop` (direnv: allow and it will load `.envrc`).
  - If Linux builds complain about `sysprof-capture-4` via pkg-config, install `sysprof`/`libsysprof-capture-dev` (included in the Nix shell).
- Flutter deps: `flutter pub get`
- Lint: `flutter analyze`
- Tests: `flutter test`

## Architecture
- Flutter UI/state in `lib/`.
- Native layers for QUIC, audio capture, and WebRTC shims in platform dirs (`android/`, `linux/`).
- Control channel is QUIC with pinned cert fingerprints; media is WebRTC over UDP. JSON framing is length-prefixed; canonical JSON (RFC 8785) for signed/HMAC’d payloads.

## Contributing
- Read `SPEC.md` and `AGENTS.md` before landing changes.
- Keep commits small, tests first, and follow the error/pinning rules in the spec.
- Update the changelog/release notes for every change with task/ticket reference and summary of what was done; reference the active plan/task.
- To stay aligned: read `SPEC.md` for requirements, `AGENTS.md` for process, and project plans/tickets to know next steps.

## License
- MIT — see `LICENSE`.
