#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${STATE_ENCRYPTION_KEY:?STATE_ENCRYPTION_KEY is required}"
: "${AVD_NAME:=cloud-android}"
export PATH="${ANDROID_HOME:-/usr/local/lib/android/sdk}/platform-tools:${ANDROID_HOME:-/usr/local/lib/android/sdk}/emulator:$PATH"
TMP_DIR="$(mktemp -d /tmp/cloud-android-restore.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

OLD_TAG=''
if OLD_TAG="$(gh api "repos/${GITHUB_REPOSITORY}/releases/latest" --jq '.tag_name' 2>/dev/null)" && [[ -n "$OLD_TAG" ]]; then
  printf '%s\n' "$OLD_TAG" > /tmp/cloud-android-previous-tag
  echo "Restoring latest snapshot: $OLD_TAG"
  gh release download "$OLD_TAG" --repo "$GITHUB_REPOSITORY" --dir "$TMP_DIR"
  [[ -f "$TMP_DIR/manifest.json" ]] || { echo 'Snapshot manifest missing.' >&2; exit 1; }
  cat "$TMP_DIR"/state-[0-9][0-9][0-9][0-9].bin > "$TMP_DIR/state.enc"
  EXPECTED="$(jq -r '.encrypted_sha256' "$TMP_DIR/manifest.json")"
  ACTUAL="$(sha256sum "$TMP_DIR/state.enc" | awk '{print $1}')"
  [[ "$EXPECTED" == "$ACTUAL" ]] || { echo 'Encrypted snapshot SHA-256 mismatch.' >&2; exit 1; }
  /tmp/cloud-android-venv/bin/python scripts/crypto.py decrypt "$TMP_DIR/state.enc" "$TMP_DIR/state.tar.zst"
  tar -I zstd -tf "$TMP_DIR/state.tar.zst" > "$TMP_DIR/archive-list.txt"
  grep -qx 'userdata-qemu.img' "$TMP_DIR/archive-list.txt" || { echo 'userdata-qemu.img missing from snapshot.' >&2; exit 1; }
  AVD_DIR="$HOME/.android/avd/${AVD_NAME}.avd"
  tar --sparse -I zstd -xf "$TMP_DIR/state.tar.zst" -C "$AVD_DIR"
  echo "Snapshot restored successfully from $OLD_TAG"
else
  echo 'No previous release snapshot found. First boot will initialize a clean Android profile.'
fi
