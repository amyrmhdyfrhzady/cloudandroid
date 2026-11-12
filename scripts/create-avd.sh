#!/usr/bin/env bash
set -euo pipefail

: "${ANDROID_HOME:?ANDROID_HOME is not set by setup-android}"
: "${AVD_NAME:=cloud-android}"
: "${SYSTEM_IMAGE:=system-images;android-37.1;google_apis_playstore_ps16k;x86_64}"

# Pin one AVD directory for avdmanager, emulator, restore and snapshot scripts.
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"

mkdir -p "$ANDROID_AVD_HOME"
AVD_INI="$ANDROID_AVD_HOME/${AVD_NAME}.ini"
AVD_DIR="$ANDROID_AVD_HOME/${AVD_NAME}.avd"

echo "ANDROID_AVD_HOME=$ANDROID_AVD_HOME"
echo "Checking Android system image: $SYSTEM_IMAGE"
if ! sdkmanager --list_installed | grep -Fq "$SYSTEM_IMAGE"; then
  echo "ERROR: Required system image is not installed: $SYSTEM_IMAGE" >&2
  sdkmanager --list_installed | grep -E 'system-images;android-|Installed packages:' >&2 || true
  exit 1
fi

# Do not trust `avdmanager list` alone: the emulator requires the matching .ini.
if [[ ! -s "$AVD_INI" ]]; then
  echo "AVD metadata is missing; creating $AVD_NAME..."
  if [[ -d "$AVD_DIR" ]]; then
    echo "Removing incomplete AVD directory without metadata: $AVD_DIR"
    rm -rf "$AVD_DIR"
  fi
  avdmanager create avd \
    --name "$AVD_NAME" \
    --package "$SYSTEM_IMAGE" \
    --device pixel_2 \
    --force <<< "no"
fi

# Fail here with a useful diagnostic rather than waiting for ADB later.
if [[ ! -s "$AVD_INI" || ! -d "$AVD_DIR" ]]; then
  echo "ERROR: avdmanager did not create the expected AVD metadata and directory." >&2
  echo "--- AVD files ---" >&2
  find "$ANDROID_AVD_HOME" -maxdepth 2 -type f -printf '%p (%s bytes)\n' >&2 || true
  echo "--- avdmanager list ---" >&2
  avdmanager list avd >&2 || true
  exit 1
fi

if ! grep -Fq "Name: ${AVD_NAME}" < <(avdmanager list avd); then
  echo "ERROR: avdmanager does not recognize AVD '$AVD_NAME'." >&2
  cat "$AVD_INI" >&2 || true
  exit 1
fi

CONFIG="$AVD_DIR/config.ini"
touch "$CONFIG"
set_config() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$CONFIG"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG"
  else
    printf '%s=%s\n' "$key" "$value" >> "$CONFIG"
  fi
}
set_config 'hw.ramSize' '4096'
set_config 'vm.heapSize' '512'
set_config 'hw.cpu.ncore' '2'
set_config 'hw.gpu.enabled' 'yes'
set_config 'hw.gpu.mode' 'swiftshader_indirect'
set_config 'hw.sdCard' 'yes'
set_config 'sdcard.path' "$AVD_DIR/sdcard.img"
set_config 'disk.dataPartition.size' '4096M'
set_config 'showDeviceFrame' 'no'

if [[ ! -s "$AVD_DIR/sdcard.img" ]]; then
  mksdcard 2G "$AVD_DIR/sdcard.img"
fi

echo "AVD metadata:"
cat "$AVD_INI"
echo "AVD ready at $AVD_DIR"
