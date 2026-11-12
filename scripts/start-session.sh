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
# Never use an unbounded `adb wait-for-device`: a failed emulator launch would
# otherwise leave the Actions job apparently frozen until the 6-hour job timeout.
EMULATOR_LOG=/tmp/cloud-android-emulator.log
ADB_LOG=/tmp/cloud-android-adb.log
rm -f "$EMULATOR_LOG" "$ADB_LOG"

echo "Checking emulator acceleration..."
if [[ -e /dev/kvm ]]; then
  ls -l /dev/kvm
  emulator -accel-check > /tmp/cloud-android-accel.log 2>&1 || {
    echo 'WARNING: Emulator acceleration check failed; see diagnostic output:' >&2
    cat /tmp/cloud-android-accel.log >&2 || true
  }
else
  echo 'WARNING: /dev/kvm is unavailable; emulator may be extremely slow or fail.' >&2
fi

echo "Starting Android Emulator (AVD: $AVD_NAME)..."
emulator -avd "$AVD_NAME" -port 5554 -accel auto \
  -gpu swiftshader_indirect -no-snapshot -no-boot-anim -no-audio \
  -camera-back none -camera-front none -verbose \
  >"$EMULATOR_LOG" 2>&1 &
EMULATOR_PID=$!
echo "$EMULATOR_PID" >/tmp/cloud-android-emulator.pid

adb start-server >"$ADB_LOG" 2>&1 || true

# Wait at most 180 seconds for the emulator device to become online.
DEVICE_READY=0
for elapsed in $(seq 1 180); do
  if adb devices 2>>"$ADB_LOG" | awk '$1 == "emulator-5554" && $2 == "device" { found=1 } END { exit !found }'; then
    DEVICE_READY=1
    echo "ADB device connected after approximately ${elapsed} seconds."
    break
  fi

  if ! kill -0 "$EMULATOR_PID" 2>/dev/null; then
    echo "ERROR: Emulator process exited before ADB became available." >&2
    break
  fi

  if (( elapsed % 15 == 0 )); then
    echo "Waiting for emulator ADB connection (${elapsed}/180 seconds)..."
    adb devices -l 2>&1 | tee -a "$ADB_LOG" || true
    tail -n 30 "$EMULATOR_LOG" || true
  fi
  sleep 1
done

if (( DEVICE_READY == 0 )); then
  echo 'ERROR: No online emulator device appeared within 180 seconds.' >&2
  echo '--- Emulator process ---' >&2
  ps -p "$EMULATOR_PID" -o pid,stat,etime,args >&2 || true
  echo '--- ADB devices ---' >&2
  adb devices -l >&2 || true
  echo '--- ADB log (last 100 lines) ---' >&2
  tail -n 100 "$ADB_LOG" >&2 || true
  echo '--- Emulator log (last 160 lines) ---' >&2
  tail -n 160 "$EMULATOR_LOG" >&2 || true
  exit 1
fi

# An online ADB transport does not mean Android has completed booting.
BOOTED=0
for elapsed in $(seq 1 360); do
  BOOT_PROP="$(timeout 15s adb -s emulator-5554 shell getprop sys.boot_completed 2>>"$ADB_LOG" | tr -d '\r' || true)"
  if [[ "$BOOT_PROP" == '1' ]]; then
    BOOTED=1
    echo "Android boot completed after approximately ${elapsed} seconds."
    break
  fi

  if (( elapsed % 15 == 0 )); then
    echo "Android is still booting (${elapsed}/360 seconds)..."
    timeout 15s adb -s emulator-5554 shell getprop dev.bootcomplete 2>&1 | tail -n 2 || true
    tail -n 20 "$EMULATOR_LOG" || true
  fi
  sleep 1
done

if (( BOOTED == 0 )); then
  echo 'ERROR: Emulator connected, but Android did not finish booting within 360 seconds.' >&2
  echo '--- ADB devices ---' >&2
  adb devices -l >&2 || true
  echo '--- Boot property ---' >&2
  timeout 15s adb -s emulator-5554 shell getprop sys.boot_completed >&2 || true
  echo '--- Emulator log (last 160 lines) ---' >&2
  tail -n 160 "$EMULATOR_LOG" >&2 || true
  exit 1
fi
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
