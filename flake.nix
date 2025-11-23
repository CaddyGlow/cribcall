{
  description = "CribCall dev shell (Flutter + Android/Linux audio tooling)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        flutter = pkgs.flutter;
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
            pkgs.protobuf
            pkgs.alsa-lib
            pkgs.pulseaudio
            pkgs.glib
            pkgs.gtk3
            pkgs.libGL
          ];

          shellHook = ''
            export FLUTTER_ROOT=${flutter}
            export PATH="$FLUTTER_ROOT/bin:$FLUTTER_ROOT/bin/cache/dart-sdk/bin:$PATH"
            echo "CribCall dev shell ready (Flutter, Dart, Android tools)."
          '';
        };
      });
}
