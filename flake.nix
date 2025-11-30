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

        isDarwin = pkgs.stdenv.isDarwin;
        isLinux = pkgs.stdenv.isLinux;

        rustToolchain = builtins.fromTOML (builtins.readFile (self + "/rust-toolchain.toml"));
        rustcChannel = rustToolchain.toolchain.channel;
        hostTriple = pkgs.stdenv.hostPlatform.config;

        libPath = pkgs.lib.makeLibraryPath (
          [
            pkgs.glib
            pkgs.gtk3
            pkgs.libsecret
          ]
          ++ pkgs.lib.optionals isLinux [
            pkgs.alsa-lib
            pkgs.pulseaudio
            pkgs.libGL
            pkgs.libdrm
            pkgs.libgbm
          ]
        );

        bindgenIncludePath = [
          ''-I"${pkgs.llvmPackages_latest.libclang.lib}/lib/clang/${pkgs.llvmPackages_latest.libclang.version}/include"''
          ''-I"${pkgs.glib.dev}/include/glib-2.0"''
          ''-I${pkgs.glib.out}/lib/glib-2.0/include/''
        ]
        ++ pkgs.lib.optionals isLinux [
          ''-I"${pkgs.glibc.dev}/include"''
        ];
      in
      {
        devShells.default = pkgs.mkShell (rec {
          # Prevent Nix from setting iOS-incompatible environment variables
          NIX_CFLAGS_COMPILE = "";
          NIX_LDFLAGS = "";
          
          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.cmake
            pkgs.ninja
          ];

          buildInputs = [
            androidSdk
            pkgs.clang
            pkgs.glib
            pkgs.gtk3
            pkgs.libsecret
            pkgs.llvmPackages.bintools
            pkgs.openjdk
            pkgs.openssl
            pkgs.protobuf
            pkgs.rustup
            pkgs.lua54Packages.lua
            pkgs.google-cloud-sdk
          ]
          ++ pkgs.lib.optionals (!isDarwin) [
            pkgs.flutter
            pkgs.dart
          ]
          ++ pkgs.lib.optionals isDarwin [
            # Use system Flutter on Darwin for iOS support
            # pkgs.flutter  # Commented out to use system Flutter
            pkgs.cocoapods
          ]
          ++ pkgs.lib.optionals isLinux [
            pkgs.alsa-lib
            pkgs.sysprof
            pkgs.pulseaudio
            pkgs.libdrm
            pkgs.libgbm
            pkgs.libGL
          ];

          RUSTC_VERSION = rustcChannel;

          LIBCLANG_PATH = pkgs.lib.makeLibraryPath [ pkgs.llvmPackages_latest.libclang.lib ];

          BINDGEN_EXTRA_CLANG_ARGS =
            pkgs.lib.optionals isLinux (
              builtins.map (a: ''-I"${a}/include"'') [
                pkgs.glibc.dev
              ]
            )
            ++ bindgenIncludePath;

          RUSTFLAGS = builtins.map (a: ''-L ${a}/lib'') [
            # add libraries here (e.g. pkgs.libvmi)
          ];

          LD_LIBRARY_PATH = libPath;

          LIBRARY_PATH = libPath;

          # Note: DEVELOPER_DIR and SDKROOT will be fixed in shellHook

          shellHook = ''
            ${pkgs.lib.optionalString (!isDarwin) ''
              export FLUTTER_ROOT=${pkgs.flutter}
              export PATH="$FLUTTER_ROOT/bin:$FLUTTER_ROOT/bin/cache/dart-sdk/bin:$PATH"
            ''}
            ${pkgs.lib.optionalString isDarwin ''
              # Fix iOS development environment by overriding Nix-provided values
              unset DEVELOPER_DIR
              unset SDKROOT  
              unset MACOSX_DEPLOYMENT_TARGET
              export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
              # Use system Flutter for iOS support
              # Ensure Flutter and Xcode are in PATH
              export PATH="/Applications/Xcode.app/Contents/Developer/usr/bin:/opt/homebrew/bin:$PATH"
              # Flutter iOS build requirements - preload iOS dependencies
              flutter precache --ios 2>/dev/null || true
              
              # Create iOS build wrapper script
              cat > ios-build.sh << 'EOF'
#!/bin/bash
echo "Building iOS with clean environment..."
unset DEVELOPER_DIR SDKROOT MACOSX_DEPLOYMENT_TARGET
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export PATH="/Applications/Xcode.app/Contents/Developer/usr/bin:/opt/homebrew/bin:$PATH"
flutter build ios --no-codesign "$@"
EOF
              chmod +x ios-build.sh
              echo "Created iOS build wrapper: ./ios-build.sh"
            ''}
            export PATH=$PATH:''${CARGO_HOME:-~/.cargo}/bin
            export PATH=$PATH:''${RUSTUP_HOME:-~/.rustup}/toolchains/$RUSTC_VERSION-${hostTriple}/bin/
            export ANDROID_SDK_ROOT="${androidSdk}/libexec/android-sdk"
            export ANDROID_HOME=$ANDROID_SDK_ROOT
            export ANDROID_AVD_HOME="$HOME/.config/.android/avd"
            export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/28.2.13676358"
            export ANDROID_NDK_ROOT=$ANDROID_NDK_HOME
            echo "CribCall dev shell ready (Flutter, Dart, rustup-managed Rust, Android SDK)."
            ${pkgs.lib.optionalString isDarwin ''
              echo "iOS development: Xcode tools available for Flutter iOS builds"
            ''}
            ${pkgs.lib.optionalString (!isDarwin) ''
              echo "Android development: Full Android SDK available"
            ''}
          '';
        } // pkgs.lib.optionalAttrs isDarwin {
          # Override problematic Nix environment variables for iOS development
          DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer";
        });

        formatter = pkgs.alejandra;
      }
    );
}
