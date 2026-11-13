#!/usr/bin/env bash
set +e
for name in cloudflared ttyd stream-droid emulator; do
  file="/tmp/cloud-android-${name}.pid"
  if [[ -f "$file" ]]; then
    kill "$(cat "$file")" 2>/dev/null || true
  fi
done
sudo systemctl stop nginx 2>/dev/null || true
