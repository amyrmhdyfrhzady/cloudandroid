#!/usr/bin/env bash
set -euo pipefail

: "${WEB_ACCESS_USER:?WEB_ACCESS_USER secret is required}"
: "${WEB_ACCESS_PASSWORD:?WEB_ACCESS_PASSWORD secret is required}"
: "${AVD_NAME:=cloud-android}"
: "${ANDROID_RUNTIME_MINUTES:=270}"
ANDROID_HOME="${ANDROID_HOME:-/usr/local/lib/android/sdk}"
export ANDROID_HOME
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

# The emulator runs headless. stream-droid provides the interactive browser UI
# directly from ADB/scrcpy, so no X11/VNC desktop is needed.
: "${ANDROID_HOME:=/usr/local/lib/android/sdk}"
: "${ANDROID_SDK_ROOT:=$ANDROID_HOME}"
export ANDROID_HOME ANDROID_SDK_ROOT
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
: "${STREAM_DROID_PORT:=3200}"

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
        proxy_pass http://127.0.0.1:3200;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
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

AVD_INI="$ANDROID_AVD_HOME/${AVD_NAME}.ini"
AVD_DIR="$ANDROID_AVD_HOME/${AVD_NAME}.avd"
if [[ ! -s "$AVD_INI" || ! -d "$AVD_DIR" ]]; then
  echo "ERROR: AVD '$AVD_NAME' is not present in $ANDROID_AVD_HOME." >&2
  echo "Expected metadata: $AVD_INI" >&2
  echo "Run scripts/create-avd.sh before starting the emulator." >&2
  find "$ANDROID_AVD_HOME" -maxdepth 2 -type f -printf '%p (%s bytes)\n' >&2 || true
  exit 1
fi
if ! emulator -list-avds | grep -Fxq "$AVD_NAME"; then
  echo "ERROR: Emulator does not list AVD '$AVD_NAME'." >&2
  emulator -list-avds >&2 || true
  cat "$AVD_INI" >&2 || true
  exit 1
fi

echo "Starting Android Emulator (AVD: $AVD_NAME)..."
emulator -avd "$AVD_NAME" -port 5554 -accel auto \
  -gpu swiftshader_indirect -no-window -no-snapshot -no-boot-anim -no-audio \
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

# ADB becoming online and sys.boot_completed=1 are not enough: wait for
# boot animation shutdown, Package Manager readiness and a resolvable HOME.
BOOTED=0
STABLE_READY=0
for elapsed in $(seq 1 120); do
  BOOT_PROP="$(timeout 15s adb -s emulator-5554 shell getprop sys.boot_completed 2>>"$ADB_LOG" | tr -d '\r' || true)"
  BOOT_ANIM="$(timeout 15s adb -s emulator-5554 shell getprop init.svc.bootanim 2>>"$ADB_LOG" | tr -d '\r' || true)"
  PACKAGE_READY=0
  HOME_ACTIVITY=''
  if [[ "$BOOT_PROP" == '1' && "$BOOT_ANIM" != 'running' ]]; then
    if timeout 20s adb -s emulator-5554 shell 'service check package' 2>>"$ADB_LOG" | grep -q 'found'; then
      PACKAGE_READY=1
      HOME_ACTIVITY="$(timeout 20s adb -s emulator-5554 shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>>"$ADB_LOG" | tr -d '\r' | tail -n 1 || true)"
    fi
  fi

  if [[ "$BOOT_PROP" == '1' && "$BOOT_ANIM" != 'running' && "$PACKAGE_READY" == '1' && -n "$HOME_ACTIVITY" && "$HOME_ACTIVITY" != 'No activity found' ]]; then
    STABLE_READY=$((STABLE_READY + 1))
    if (( STABLE_READY >= 3 )); then
      BOOTED=1
      echo "Android framework, Package Manager and HOME are ready (checked for 3 consecutive intervals; ${elapsed}s)."
      break
    fi
  else
    STABLE_READY=0
  fi

  if (( elapsed % 4 == 0 )); then
    echo "Waiting for complete Android startup (approximately $((elapsed * 5))/600 seconds)..."
    echo "sys.boot_completed=${BOOT_PROP:-unset}; init.svc.bootanim=${BOOT_ANIM:-unset}; package_ready=${PACKAGE_READY}; home=${HOME_ACTIVITY:-not-ready}"
    timeout 15s adb -s emulator-5554 shell getprop dev.bootcomplete 2>&1 | tail -n 2 || true
    tail -n 20 "$EMULATOR_LOG" || true
  fi
  sleep 5
done

if (( BOOTED == 0 )); then
  echo 'ERROR: Android did not reach a stable, usable HOME state within 600 seconds.' >&2
  echo '--- Boot properties ---' >&2
  timeout 20s adb -s emulator-5554 shell 'getprop sys.boot_completed; getprop init.svc.bootanim; getprop dev.bootcomplete' >&2 || true
  echo '--- Package and HOME readiness ---' >&2
  timeout 20s adb -s emulator-5554 shell 'service check package; cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME' >&2 || true
  echo '--- Recent Android errors ---' >&2
  timeout 30s adb -s emulator-5554 logcat -b all -d -v time -t 1200 2>&1 | grep -iE 'fatal|crash|watchdog|boot|package manager|system_server|zygote|setupwizard' | tail -n 180 >&2 || true
  timeout 20s adb -s emulator-5554 exec-out screencap -p >/tmp/cloud-android-boot-failure.png 2>/dev/null || true
  timeout 30s adb -s emulator-5554 logcat -b all -d -v time -t 2500 >/tmp/cloud-android-boot-failure-logcat.txt 2>/dev/null || true
  echo '--- Emulator log (last 200 lines) ---' >&2
  tail -n 200 "$EMULATOR_LOG" >&2 || true
  exit 1
fi

# Skip the first-run welcome wizard on this disposable emulator profile and
# bring the actual launcher to the foreground for a usable remote session.
adb shell settings put global device_provisioned 1 || true
adb shell settings put secure user_setup_complete 1 || true
adb shell am force-stop com.google.android.setupwizard >/dev/null 2>&1 || true
adb shell svc power stayon true || true
adb shell settings put system screen_off_timeout 2147483647 || true
adb shell am start -W -a android.intent.action.MAIN -c android.intent.category.HOME || true
sleep 5
adb shell input keyevent 82 || true
# Set only after the framework is ready and the launcher has been requested.
touch /tmp/cloud-android-boot-complete

# Start the full interactive browser controller (video, touch, keyboard,
# navigation and clipboard) against the already-running emulator.
if ! command -v npx >/dev/null 2>&1; then
  echo 'ERROR: Node.js/npm is missing; browser control cannot start.' >&2
  exit 1
fi
npx --yes stream-droid@latest --serial emulator-5554 --capture scrcpy --headless --port "$STREAM_DROID_PORT" \
  >/tmp/cloud-android-stream-droid.log 2>&1 &
echo $! >/tmp/cloud-android-stream-droid.pid
STREAM_READY=0
for elapsed in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${STREAM_DROID_PORT}/" -o /tmp/cloud-android-stream-droid.html; then
    STREAM_READY=1
    echo "Browser controller is ready on port ${STREAM_DROID_PORT}."
    break
  fi
  if ! kill -0 "$(cat /tmp/cloud-android-stream-droid.pid)" 2>/dev/null; then
    echo 'ERROR: stream-droid exited during startup.' >&2
    tail -n 120 /tmp/cloud-android-stream-droid.log >&2 || true
    exit 1
  fi
  sleep 2
done
if (( STREAM_READY == 0 )); then
  echo 'ERROR: Browser controller did not become ready within 240 seconds.' >&2
  tail -n 160 /tmp/cloud-android-stream-droid.log >&2 || true
  exit 1
fi

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
  echo '- **Android control:** open the URL for the live stream-droid screen; tap, swipe, keyboard, navigation and clipboard controls are available.'
  echo '- **ADB terminal:** open `/terminal/` after signing in, then run commands such as `adb devices` and `adb shell`.'
  echo
  echo "Android 17 booted. Runtime target: ${ANDROID_RUNTIME_MINUTES} minutes."
} >> "$GITHUB_STEP_SUMMARY"

echo "Cloud Android is available at: $TUNNEL_URL"
echo 'Open the URL and authenticate using WEB_ACCESS_USER / WEB_ACCESS_PASSWORD. The root page is the interactive Android controller.'
