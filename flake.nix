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

  outputs = { self, nixpkgs, flake-utils, fenix, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
          overlays = [ fenix.overlays.default ];
        };
        flutter = pkgs.flutter;
        rustToolchain = fenix.packages.${system}.latest.toolchain;
        rustAnalyzer = fenix.packages.${system}.latest.rust-analyzer;
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            flutter
            pkgs.dart
            pkgs.android-tools # adb/fastboot
            pkgs.openjdk
            pkgs.cmake
            pkgs.ninja
            pkgs.pkg-config
            pkgs.clang
            rustToolchain
            rustAnalyzer
            pkgs.protobuf
            pkgs.sysprof
            pkgs.alsa-lib
            pkgs.pulseaudio
            pkgs.glib
            pkgs.gtk3
            pkgs.libsecret
            pkgs.libGL
          ];

          shellHook = ''
            export FLUTTER_ROOT=${flutter}
            export PATH="$FLUTTER_ROOT/bin:$FLUTTER_ROOT/bin/cache/dart-sdk/bin:$PATH"
            echo "CribCall dev shell ready (Flutter, Dart, fenix Rust, Android tools)."
          '';
        };

        formatter = pkgs.alejandra;
      });
}
