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
          config = {
            android_sdk.accept_license = true;
            allowUnfree = true;
          };
        };

        androidComposition = pkgs.androidenv.composeAndroidPackages {
          cmdLineToolsVersion = "11.0";
          buildToolsVersions = [
            "28.0.3"
            "30.0.3"
            "35.0.0"
          ];
          platformVersions = [
            "28"
            "29"
            "30"
            "31"
            "32"
            "33"
            "34"
            "35"
            "36"
          ];
          includeNDK = true;
          ndkVersions = [ "28.2.13676358" ];
          cmakeVersions = [ "3.22.1" ];
          abiVersions = [
            # "armeabi-v7a"
            # "arm64-v8a"
            # "x86"
            "x86_64"
          ];
          includeEmulator = true;
          includeSystemImages = true;
          systemImageTypes = [ "google_apis_playstore" ];
          extraLicenses = [
            "android-googletv-license"
            "android-sdk-arm-dbt-license"
            "android-sdk-license"
            "android-sdk-preview-license"
            "google-gdk-license"
            "intel-android-extra-license"
            "intel-android-sysimage-license"
            "mips-android-sysimage-license"
          ];
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

        flutter = pkgs.flutter;
      in
      {
        devShells.default = pkgs.mkShell rec {
          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.cmake
            pkgs.ninja
          ];

          buildInputs = [
            androidSdk
            flutter
            pkgs.alsa-lib
            pkgs.clang
            pkgs.dart
            pkgs.glib
            pkgs.gtk3
            pkgs.libdrm
            pkgs.libgbm
            pkgs.libGL
            pkgs.libsecret
            pkgs.llvmPackages.bintools
            pkgs.openjdk
            pkgs.openssl
            pkgs.protobuf
            pkgs.pulseaudio
            pkgs.rustup
            pkgs.sysprof
            pkgs.lua54Packages.lua
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
            export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/28.2.13676358"
            export ANDROID_NDK_ROOT=$ANDROID_NDK_HOME
            echo "CribCall dev shell ready (Flutter, Dart, rustup-managed Rust, Android SDK)."
          '';
        };

        formatter = pkgs.alejandra;
      }
    );
}
