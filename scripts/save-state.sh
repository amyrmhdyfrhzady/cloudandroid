#!/usr/bin/env bash
set -euo pipefail

# This workflow step runs with `always()` so it can save after later failures.
# But if setup/boot failed, there is no valid running phone state to publish.
if [[ ! -f /tmp/cloud-android-boot-complete ]]; then
  echo 'Android never reached sys.boot_completed=1; skipping snapshot publication.'
  exit 0
fi

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${STATE_ENCRYPTION_KEY:?STATE_ENCRYPTION_KEY is required}"
: "${AVD_NAME:=cloud-android}"
: "${STATE_CHUNK_MIB:=1800}"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
export PATH="${ANDROID_HOME:-/usr/local/lib/android/sdk}/platform-tools:${ANDROID_HOME:-/usr/local/lib/android/sdk}/emulator:$PATH"

AVD_DIR="$HOME/.android/avd/${AVD_NAME}.avd"
TMP_DIR="$(mktemp -d /tmp/cloud-android-save.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Stop Android cleanly before reading the userdata disk.
adb emu kill >/dev/null 2>&1 || true
if [[ -f /tmp/cloud-android-emulator.pid ]]; then
  for _ in $(seq 1 60); do
    kill -0 "$(cat /tmp/cloud-android-emulator.pid)" 2>/dev/null || break
    sleep 2
  done
fi
sync
[[ -s "$AVD_DIR/userdata-qemu.img" ]] || { echo 'userdata-qemu.img is missing or empty; refusing to publish state.' >&2; exit 1; }
[[ -s "$AVD_DIR/sdcard.img" ]] || { echo 'sdcard.img is missing or empty; refusing to publish state.' >&2; exit 1; }

# Sparse tar keeps mostly-empty emulator disk regions compact.
tar --sparse -I 'zstd -T0 -3' -cf "$TMP_DIR/state.tar.zst" -C "$AVD_DIR" userdata-qemu.img sdcard.img
/tmp/cloud-android-venv/bin/python scripts/crypto.py encrypt "$TMP_DIR/state.tar.zst" "$TMP_DIR/state.enc"
sha256sum "$TMP_DIR/state.enc" | awk '{print $1}' > "$TMP_DIR/encrypted.sha256"

# GitHub limits each release asset to less than 2 GiB; split at 1,800 MiB.
split --bytes="${STATE_CHUNK_MIB}M" --numeric-suffixes=1 --suffix-length=4 "$TMP_DIR/state.enc" "$TMP_DIR/state-"
for part in "$TMP_DIR"/state-[0-9][0-9][0-9][0-9]; do
  [[ -e "$part" ]] || continue
  mv "$part" "${part}.bin"
done
CHUNK_COUNT="$(find "$TMP_DIR" -maxdepth 1 -type f -name 'state-*.bin' | wc -l | tr -d ' ')"
[[ "$CHUNK_COUNT" -gt 0 ]] || { echo 'No snapshot chunks were created.' >&2; exit 1; }

TAG="cloud-android-$(date -u +%Y%m%dT%H%M%SZ)-${GITHUB_RUN_ID:-manual}"
cat > "$TMP_DIR/manifest.json" <<JSON
{
  "format": "cloud-android-state-v1",
  "android_api": 37.1,
  "avd_name": "${AVD_NAME}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "encryption": "AES-256-GCM",
  "compression": "zstd",
  "encrypted_sha256": "$(cat "$TMP_DIR/encrypted.sha256")",
  "chunks": ${CHUNK_COUNT}
}
JSON

# Publish new state first. The old release remains intact until the new one verifies.
gh release create "$TAG" "$TMP_DIR"/state-*.bin "$TMP_DIR/manifest.json" \
  --repo "$GITHUB_REPOSITORY" --title "Cloud Android state ${TAG}" \
  --notes 'Encrypted Cloud Android persistent userdata snapshot. Do not edit assets.' --latest

REMOTE_COUNT="$(gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${TAG}" --jq '.assets | length')"
EXPECTED_COUNT="$((CHUNK_COUNT + 1))"
[[ "$REMOTE_COUNT" -eq "$EXPECTED_COUNT" ]] || {
  echo "Release verification failed: expected ${EXPECTED_COUNT} assets, found ${REMOTE_COUNT}." >&2
  exit 1
}

# Keep the newest two snapshots. This leaves one known-good rollback point.
mapfile -t RELEASE_TAGS < <(gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" --jq '.[].tag_name' | grep '^cloud-android-' || true)
for OLD in "${RELEASE_TAGS[@]:2}"; do
  [[ -n "$OLD" && "$OLD" != "$TAG" ]] || continue
  OLD_ID="$(gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${OLD}" --jq '.id' 2>/dev/null || true)"
  if [[ -n "$OLD_ID" ]]; then
    gh api -X DELETE "repos/${GITHUB_REPOSITORY}/releases/${OLD_ID}" || true
    gh api -X DELETE "repos/${GITHUB_REPOSITORY}/git/refs/tags/${OLD}" >/dev/null 2>&1 || true
  fi
done

echo "Snapshot published and verified: $TAG (${CHUNK_COUNT} chunks)."
echo "Snapshot release: https://github.com/${GITHUB_REPOSITORY}/releases/tag/${TAG}" >> "$GITHUB_STEP_SUMMARY"
