#!/usr/bin/env bash
set -euo pipefail

: "${WEB_ACCESS_USER:?WEB_ACCESS_USER secret is required}"
: "${WEB_ACCESS_PASSWORD:?WEB_ACCESS_PASSWORD secret is required}"
: "${AVD_NAME:=cloud-android}"
: "${ANDROID_RUNTIME_MINUTES:=270}"
ANDROID_HOME="${ANDROID_HOME:-/usr/local/lib/android/sdk}"
export ANDROID_HOME
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

# Start a virtual display and a lightweight window manager for the emulator UI.
export DISPLAY=:0
Xvfb :0 -screen 0 1440x2560x24 -ac +extension RANDR >/tmp/cloud-android-xvfb.log 2>&1 &
echo $! >/tmp/cloud-android-xvfb.pid
sleep 2
openbox >/tmp/cloud-android-openbox.log 2>&1 &
echo $! >/tmp/cloud-android-openbox.pid

# VNC is loopback-only; all remote HTTP access is protected by nginx Basic Auth.
x11vnc -display :0 -localhost -nopw -forever -shared -rfbport 5900 >/tmp/cloud-android-vnc.log 2>&1 &
echo $! >/tmp/cloud-android-vnc.pid
websockify --web=/usr/share/novnc 127.0.0.1:6081 127.0.0.1:5900 >/tmp/cloud-android-websockify.log 2>&1 &
echo $! >/tmp/cloud-android-websockify.pid

# Generate a bcrypt htpasswd file without putting the password in process arguments.
printf '%s\n' "$WEB_ACCESS_PASSWORD" | sudo htpasswd -i -B -c /etc/nginx/.cloud-android.htpasswd "$WEB_ACCESS_USER"
sudo chmod 640 /etc/nginx/.cloud-android.htpasswd
sudo chown root:www-data /etc/nginx/.cloud-android.htpasswd
sudo tee /etc/nginx/sites-available/cloud-android >/dev/null <<'NGINX'
server {
    listen 8080;
    server_name _;
    client_max_body_size 20m;
    auth_basic "Cloud Android";
    auth_basic_user_file /etc/nginx/.cloud-android.htpasswd;

    location /terminal/ {
        proxy_pass http://127.0.0.1:7681/terminal/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
    }

    location / {
        proxy_pass http://127.0.0.1:6081/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
    }
}
NGINX
sudo ln -sf /etc/nginx/sites-available/cloud-android /etc/nginx/sites-enabled/cloud-android
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx

# A marker prevents the always-run save step from trying to publish a disk
# when setup or emulator boot failed before a usable Android instance existed.
rm -f /tmp/cloud-android-boot-complete

# Start the emulator with the persistent userdata image in the AVD directory.
emulator -avd "$AVD_NAME" -gpu swiftshader_indirect -no-snapshot -no-boot-anim -no-audio \
  -camera-back none -camera-front none >/tmp/cloud-android-emulator.log 2>&1 &
echo $! >/tmp/cloud-android-emulator.pid
adb wait-for-device
for _ in $(seq 1 180); do
  BOOTED="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
  [[ "$BOOTED" == '1' ]] && break
  sleep 2
done
[[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" == '1' ]] || {
  echo 'Android did not finish booting within six minutes.' >&2
  tail -n 100 /tmp/cloud-android-emulator.log || true
  exit 1
}
# Set immediately after verified boot, before starting optional access services.
touch /tmp/cloud-android-boot-complete
adb shell svc power stayon true || true
adb shell settings put system screen_off_timeout 2147483647 || true
adb shell input keyevent 82 || true

# Start a restricted ADB-only browser terminal.
ttyd --port 7681 --writable --base-path /terminal "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}/scripts/adb-terminal.sh" \
  >/tmp/cloud-android-ttyd.log 2>&1 &
echo $! >/tmp/cloud-android-ttyd.pid

# Quick Tunnel creates a temporary HTTPS URL. No Cloudflare account or domain is required.
cloudflared tunnel --no-autoupdate --url http://127.0.0.1:8080 \
  >/tmp/cloud-android-cloudflared.log 2>&1 &
echo $! >/tmp/cloud-android-cloudflared.pid
TUNNEL_URL=''
for _ in $(seq 1 60); do
  TUNNEL_URL="$(grep -Eo 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' /tmp/cloud-android-cloudflared.log | head -n1 || true)"
  [[ -n "$TUNNEL_URL" ]] && break
  sleep 2
done
if [[ -z "$TUNNEL_URL" ]]; then
  echo 'Cloudflare Quick Tunnel did not provide a URL. Check /tmp/cloud-android-cloudflared.log.' >&2
  tail -n 80 /tmp/cloud-android-cloudflared.log || true
  exit 1
fi

{
  echo '## Cloud Android access'
  echo
  echo "- **URL:** ${TUNNEL_URL}"
  echo "- **HTTP username:** ${WEB_ACCESS_USER}"
  echo '- **HTTP password:** the value stored in the `WEB_ACCESS_PASSWORD` repository secret'
  echo '- **VNC:** open the URL in a browser; noVNC is served at the root path.'
  echo '- **ADB terminal:** open `/terminal/` after signing in, then run commands such as `adb devices` and `adb shell`.'
  echo
  echo "Android 17 booted. Runtime target: ${ANDROID_RUNTIME_MINUTES} minutes."
} >> "$GITHUB_STEP_SUMMARY"

echo "Cloud Android is available at: $TUNNEL_URL"
echo 'Open the URL and authenticate using WEB_ACCESS_USER / WEB_ACCESS_PASSWORD.'
