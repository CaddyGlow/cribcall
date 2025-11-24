{
  description = "CribCall dev shell (Flutter + Android/Linux audio tooling)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      fenix,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
          overlays = [ fenix.overlays.default ];
        };
        lib = pkgs.lib;
        isLinux = pkgs.stdenv.isLinux;
        flutter = pkgs.flutter;
        javaToolchain = pkgs.openjdk17;
        androidPackages =
          if isLinux then
            pkgs.androidenv.composeAndroidPackages {
              platformVersions = [ "36" ];
              buildToolsVersions = [ "36.0.0" ];
              includeNDK = true;
              includeEmulator = false;
              ndkVersions = [ "27.0.12077973" ];
            }
          else
            null;
        rustToolchain = fenix.packages.${system}.latest.toolchain;
        rustAnalyzer = fenix.packages.${system}.latest.rust-analyzer;
        androidRustStd =
          lib.optionals isLinux [
            fenix.packages.${system}.targets."aarch64-linux-android".latest.rust-std
            fenix.packages.${system}.targets."armv7-linux-androideabi".latest.rust-std
            fenix.packages.${system}.targets."x86_64-linux-android".latest.rust-std
          ];
        commonPackages =
          [
            flutter
            pkgs.dart
            pkgs.android-tools
            javaToolchain
            pkgs.cmake
            pkgs.ninja
            pkgs.pkg-config
            pkgs.clang
            rustToolchain
            rustAnalyzer
            pkgs.cargo-edit
            pkgs.cargo-deny
            pkgs.cargo-audit
            pkgs.cargo-ndk
            pkgs.perl
            pkgs.protobuf
            pkgs.openssl
            pkgs.sysprof
            pkgs.alsa-lib
            pkgs.pulseaudio
            pkgs.glib
            pkgs.gtk3
            pkgs.libsecret
            pkgs.libGL
          ]
          ++ androidRustStd;
        linuxPackages =
          if isLinux then
            [
              androidPackages.androidsdk
              pkgs.androidStudioPackages.dev
            ]
          else
            [];
      in
      {
        devShells.default = pkgs.mkShell {
          packages = commonPackages ++ linuxPackages;

          shellHook = ''
            export FLUTTER_ROOT=${flutter}
            export PATH="$FLUTTER_ROOT/bin:$FLUTTER_ROOT/bin/cache/dart-sdk/bin:$PATH"
            export JAVA_HOME=${javaToolchain}
          ''
          + lib.optionalString isLinux ''
            export ANDROID_HOME=${androidPackages.androidsdk}
            export ANDROID_SDK_ROOT=${androidPackages.androidsdk}
            if [ -d "${androidPackages.androidsdk}/ndk" ]; then
              export ANDROID_NDK_HOME=$(ls -d ${androidPackages.androidsdk}/ndk/* | head -n1)
              export ANDROID_NDK_ROOT=$ANDROID_NDK_HOME
            fi
          ''
          + ''
            echo "CribCall dev shell ready (Flutter, Dart, fenix Rust, Android SDK/NDK tooling)."
          '';
        };

        formatter = pkgs.alejandra;
      }
    );
}
