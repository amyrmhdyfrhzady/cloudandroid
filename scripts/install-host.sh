#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  qemu-kvm libvirt-daemon-system libvirt-clients cpu-checker \
  xvfb openbox x11vnc novnc websockify nginx apache2-utils \
  zstd jq curl unzip python3-venv python3-pip ca-certificates

if [[ -e /dev/kvm ]]; then
  sudo chmod 666 /dev/kvm || true
else
  echo 'WARNING: /dev/kvm is unavailable. Emulator may be very slow or fail.' >&2
fi

# Install a fixed ttyd release; it provides a browser terminal restricted to ADB commands.
TTYD_VERSION='1.7.7'
sudo curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
  -o /usr/local/bin/ttyd
sudo chmod 0755 /usr/local/bin/ttyd

# Cloudflare Quick Tunnel is used only as a temporary network path to this ephemeral runner.
sudo curl -fsSL \
  'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64' \
  -o /usr/local/bin/cloudflared
sudo chmod 0755 /usr/local/bin/cloudflared

python3 -m venv /tmp/cloud-android-venv
/tmp/cloud-android-venv/bin/pip install --disable-pip-version-check --quiet 'cryptography>=44,<47'
echo 'Host dependencies installed.'
