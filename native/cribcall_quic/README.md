# cribcall_quic

Rust/quiche-powered QUIC bindings for CribCall built with Cargokit.

## Structure

- `rust/`: Rust crate exposing a small C ABI (`cc_quic_*`) around quiche. Built as both `cdylib` and `staticlib`.
- `cargokit/` (repo root): Build glue vendored from https://github.com/irondash/cargokit to drive cargo builds from Flutter toolchains.
- `lib/cribcall_quic.dart`: Minimal Dart FFI wrapper that loads the platform library, initializes logging, and allocates a default QUIC config handle.
- Platform glue:
  - Android Gradle + Cargokit (`android/build.gradle`)
  - CocoaPods script phases for iOS/macOS (`ios/cribcall_quic.podspec`, `macos/cribcall_quic.podspec`)
  - Linux CMake integration via `apply_cargokit` (`linux/CMakeLists.txt`)

The FFI surface is declared in `src/cribcall_quic.h`. Use `CribcallQuic` from Dart to load the library, call `initLogging()`, and create/free configs.

## Development

- Ensure Rust (rustup) is installed; Cargokit handles target setup when invoked by Flutter/Pod/CMake builds.
- For tests or local checks, run `cargo test` inside `rust/`.
- Example app in `example/` exercises loading the library and building a default config.
