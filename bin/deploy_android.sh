#!/usr/bin/env bash
set -euo pipefail

mode="debug"
serial="${ADB_SERIAL:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--mode debug|profile|release] [--serial DEVICE_SERIAL]

Builds a Flutter APK, installs it over ADB, and launches the app.
Defaults to debug mode and the first connected device. Override the device with
--serial or ADB_SERIAL.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mode)
      mode="${2:-}"
      shift 2
      ;;
    -s|--serial)
      serial="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

case "$mode" in
  debug|profile|release)
    ;;
  *)
    echo "Invalid mode: $mode (expected debug, profile, or release)"
    exit 1
    ;;
esac

command -v flutter >/dev/null || { echo "flutter is not on PATH"; exit 1; }
command -v adb >/dev/null || { echo "adb is not on PATH"; exit 1; }

adb_args=()

ensure_device() {
  if [[ -n "$serial" ]]; then
    adb_args=("-s" "$serial")
    adb "${adb_args[@]}" get-state >/dev/null
    echo "Using device serial: $serial"
    return
  fi

  mapfile -t connected < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')
  if [[ "${#connected[@]}" -eq 0 ]]; then
    echo "No ADB devices found. Connect a device or start an emulator."
    exit 1
  fi
  if [[ "${#connected[@]}" -gt 1 ]]; then
    echo "Multiple devices detected (${connected[*]}). Set --serial or ADB_SERIAL."
    exit 1
  fi

  serial="${connected[0]}"
  adb_args=("-s" "$serial")
  echo "Using detected device: $serial"
}

ensure_device

cd "$project_root"
echo "Building Flutter APK ($mode)..."
flutter build apk --"$mode"

apk_path="$project_root/build/app/outputs/flutter-apk/app-$mode.apk"
if [[ ! -f "$apk_path" ]]; then
  echo "APK not found at $apk_path"
  exit 1
fi

if [[ -n "$serial" && "${#adb_args[@]}" -eq 0 ]]; then
  adb_args=("-s" "$serial")
fi

echo "Installing $apk_path to $serial..."
adb "${adb_args[@]}" install -r "$apk_path"

echo "Launching com.cribcall.cribcall/.MainActivity..."
adb "${adb_args[@]}" shell am start -n com.cribcall.cribcall/.MainActivity >/dev/null

echo "Done."
