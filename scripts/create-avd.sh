#!/usr/bin/env bash
set -euo pipefail

: "${ANDROID_HOME:?ANDROID_HOME is not set by setup-android}"
: "${AVD_NAME:=cloud-android}"
: "${SYSTEM_IMAGE:=system-images;android-37.1;google_apis_playstore_ps16k;x86_64}"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"

mkdir -p "$HOME/.android/avd"
if ! avdmanager list avd | grep -q "Name: ${AVD_NAME}"; then
  echo no | avdmanager create avd --name "$AVD_NAME" --package "$SYSTEM_IMAGE" --device pixel_2 --force
fi

AVD_DIR="$HOME/.android/avd/${AVD_NAME}.avd"
mkdir -p "$AVD_DIR"
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

if [[ ! -f "$AVD_DIR/sdcard.img" ]]; then
  mksdcard 2G "$AVD_DIR/sdcard.img"
fi

echo "AVD ready at $AVD_DIR"
