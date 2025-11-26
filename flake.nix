{
  description = "CribCall dev shell (Flutter + Android/Linux audio tooling)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          config.android_sdk.accept_license = true;
        };
        flutter = pkgs.flutter;
        androidComposition = pkgs.androidenv.composeAndroidPackages {
          cmdLineToolsVersion = "11.0";
          platformToolsVersion = "36.0.2";
          buildToolsVersions = [ "36.0.0" ];
          platformVersions = [ "34" ];
          includeEmulator = true;
          emulatorVersion = "36.4.1";
          includeSystemImages = true;
          systemImageTypes = [ "google_apis_playstore" ];
          abiVersions = [ "x86_64" ];
          includeNDK = true;
          ndkVersions = [ "26.1.10909125" ];
        };
        androidSdk = androidComposition.androidsdk;
        rustToolchain = builtins.fromTOML (builtins.readFile (self + "/rust-toolchain.toml"));
        rustcChannel = rustToolchain.toolchain.channel;
        libPath = pkgs.lib.makeLibraryPath [
          pkgs.alsa-lib
          pkgs.pulseaudio
          pkgs.glib
          pkgs.gtk3
          pkgs.libsecret
          pkgs.libGL
          pkgs.libdrm
          pkgs.libgbm
        ];
        bindgenIncludePath = [
          ''-I"${pkgs.llvmPackages_latest.libclang.lib}/lib/clang/${pkgs.llvmPackages_latest.libclang.version}/include"''
          ''-I"${pkgs.glib.dev}/include/glib-2.0"''
          ''-I${pkgs.glib.out}/lib/glib-2.0/include/''
        ];
      in
      {
        devShells.default = pkgs.mkShell rec {
          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.cmake
            pkgs.ninja
          ];

          buildInputs = [
            pkgs.openssl
            flutter
            pkgs.dart
            androidSdk
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
            pkgs.libdrm
            pkgs.libgbm
          ];

          RUSTC_VERSION = rustcChannel;

          LIBCLANG_PATH = pkgs.lib.makeLibraryPath [ pkgs.llvmPackages_latest.libclang.lib ];

          BINDGEN_EXTRA_CLANG_ARGS =
            (builtins.map (a: ''-I"${a}/include"'') [
              pkgs.glibc.dev
            ])
            ++ bindgenIncludePath;

          RUSTFLAGS = builtins.map (a: ''-L ${a}/lib'') [
            # add libraries here (e.g. pkgs.libvmi)
          ];

          LD_LIBRARY_PATH = libPath;

          LIBRARY_PATH = libPath;

          shellHook = ''
            export FLUTTER_ROOT=${flutter}
            export PATH="$FLUTTER_ROOT/bin:$FLUTTER_ROOT/bin/cache/dart-sdk/bin:$PATH"
            export PATH=$PATH:''${CARGO_HOME:-~/.cargo}/bin
            export PATH=$PATH:''${RUSTUP_HOME:-~/.rustup}/toolchains/$RUSTC_VERSION-x86_64-unknown-linux-gnu/bin/
            export ANDROID_SDK_ROOT="${androidSdk}/libexec/android-sdk"
            export ANDROID_HOME=$ANDROID_SDK_ROOT
            export ANDROID_AVD_HOME="$HOME/.config/.android/avd"
            export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/26.1.10909125"
            export ANDROID_NDK_ROOT=$ANDROID_NDK_HOME
            echo "CribCall dev shell ready (Flutter, Dart, rustup-managed Rust, Android SDK)."
          '';
        };

        formatter = pkgs.alejandra;
      }
    );
}
