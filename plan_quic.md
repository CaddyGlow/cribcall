# QUIC + Cargokit Integration Plan

Goal: add a Rust-based QUIC transport (quiche) packaged as a Cargokit Flutter plugin, expose FFI surface to Dart for control channel per SPEC, and ensure Nix flake includes required Rust deps.

## Phase 1: Groundwork and design alignment
- Re-read SPEC.md control channel rules (pairing-only vs trusted, pinning, framing, error codes) and current QUIC helpers in `lib/`.
- Audit existing native scaffolding (android/linux/ios, `third_party/`, any prior QUIC stubs) to avoid conflicts and reuse shared identity/pinning logic.
- Define target platforms for the first slice (Android/iOS/Linux desktop) and build settings expected by Cargokit (Rust toolchain version, crate layout).

## Phase 2: Rust crate + Cargokit scaffolding
- Scaffold Cargokit plugin structure (per matejknopp/hello_rust_ffi_plugin) with a `crate` directory, Rust lib, and generated bindings placement.
- Pull in `quiche` crate and supporting deps (ring, boring-sys vendoring as needed) with a minimal Cargo.toml; pin versions compatible with mobile.
- Design FFI surface: init with pinned cert fingerprint, endpoint configuration, connect/listen helpers, bidirectional control stream send/recv with canonical framing, NOISE_EVENT push, and error mapping to Dart-friendly enums.
- Plan background threading/event loop strategy (tokio vs no_std/reactor) to drive quiche; define how callbacks/streams surface into Dart (ports, method channels, streams).
- Document lifetime/ownership rules (per-connection handles, buffers ownership, shutdown) and security hooks (mTLS, fingerprint validation, canonical JSON enforcement before signing).

## Phase 3: Dart/Flutter integration plan
- Decide binding approach (ffigen/cargokit generated bindings) and where to place Dart wrapper (e.g., `lib/native/quic_client.dart`).
- Outline API surface matching SPEC messages: connect, sendControlMessage, receive event stream, trust gating (reject non-trusted commands), pairing-only mode toggle.
- Plan unit/integration tests: Rust-side QUIC handshake with self-signed certs, fingerprint rejection, framing errors, NOISE_EVENT delivery; Dart wrapper tests with fake handles.
- Map UI/state touchpoints (listener/monitor controllers) that will consume the new transport and how to guard existing flows until the native layer is ready.

## Phase 4: Tooling and Nix updates
- Update `flake.nix` to include Rust toolchain components and build inputs for quiche (openssl/boringssl, pkg-config, clang/llvm as needed); ensure cargo build works on Linux dev.
- Add Cargokit build steps to project scripts (Makefile/cargo xtask/Flutter build hooks) and document commands for Android/iOS desktop targets.
- Note changelog entry scope for when implementation lands and any artifacts/keys that must remain runtime-only (no repo commits).
