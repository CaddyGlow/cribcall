{
  description = "CribCall dev shell (Flutter + Android/Linux audio tooling)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        flutter = pkgs.flutter;
        rustToolchain = builtins.fromTOML (builtins.readFile (self + "/rust-toolchain.toml"));
        rustcChannel = rustToolchain.toolchain.channel;
        libPath =
          pkgs.lib.makeLibraryPath [
            pkgs.alsa-lib
            pkgs.pulseaudio
            pkgs.glib
            pkgs.gtk3
            pkgs.libsecret
            pkgs.libGL
          ];
        bindgenIncludePath = [
          ''-I"${pkgs.llvmPackages_latest.libclang.lib}/lib/clang/${pkgs.llvmPackages_latest.libclang.version}/include"''
          ''-I"${pkgs.glib.dev}/include/glib-2.0"''
          ''-I${pkgs.glib.out}/lib/glib-2.0/include/''
        ];
      in {
        devShells.default = pkgs.mkShell rec {
          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.cmake
            pkgs.ninja
          ];

          buildInputs = [
            flutter
            pkgs.dart
            pkgs.android-tools # adb/fastboot
            pkgs.openjdk
            pkgs.clang
            pkgs.llvmPackages.bintools
            pkgs.rustup
            pkgs.protobuf
            pkgs.sysprof
            pkgs.alsa-lib
            pkgs.pulseaudio
            pkgs.glib
            pkgs.gtk3
            pkgs.libsecret
            pkgs.libGL
          ];

          RUSTC_VERSION = rustcChannel;

          LIBCLANG_PATH = pkgs.lib.makeLibraryPath [ pkgs.llvmPackages_latest.libclang.lib ];

          BINDGEN_EXTRA_CLANG_ARGS =
            (builtins.map (a: ''-I"${a}/include"'') [
              pkgs.glibc.dev
            ])
            ++ bindgenIncludePath;

          RUSTFLAGS =
            builtins.map (a: ''-L ${a}/lib'') [
              # add libraries here (e.g. pkgs.libvmi)
            ];

          LD_LIBRARY_PATH = libPath;

          shellHook = ''
            export FLUTTER_ROOT=${flutter}
            export PATH="$FLUTTER_ROOT/bin:$FLUTTER_ROOT/bin/cache/dart-sdk/bin:$PATH"
            export PATH=$PATH:''${CARGO_HOME:-~/.cargo}/bin
            export PATH=$PATH:''${RUSTUP_HOME:-~/.rustup}/toolchains/$RUSTC_VERSION-x86_64-unknown-linux-gnu/bin/
            export ANDROID_SDK_ROOT="''${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
            export ANDROID_HOME=$ANDROID_SDK_ROOT
            if [ -z "''${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_SDK_ROOT/ndk" ]; then
              android_ndk_version=$(ls -1 "$ANDROID_SDK_ROOT/ndk" 2>/dev/null | sort -V | tail -n1)
              if [ -n "$android_ndk_version" ]; then
                export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/$android_ndk_version"
              fi
            fi
            if [ -n "''${ANDROID_NDK_HOME:-}" ]; then
              export ANDROID_NDK_ROOT=$ANDROID_NDK_HOME
            fi
            echo "CribCall dev shell ready (Flutter, Dart, rustup-managed Rust, Android tools)."
          '';
        };

        formatter = pkgs.alejandra;
      });
}
