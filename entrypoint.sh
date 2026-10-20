#!/usr/bin/env bash
set -Eeuo pipefail

# easyworker Android sandbox.
#
# FINAL SHAPE: the Go worker AND the Kotlin easystream daemon both run INSIDE
# the emulator. This container only boots the emulator, installs the baked APK,
# grants the accessibility + screen-capture (MediaProjection) consents, pushes
# the static Go worker into the guest, starts it, and forwards its port out.
#
#   container                                guest (Android x86_64, bionic)
#   ┌─────────────────────────┐   adb       ┌──────────────────────────────┐
#   │ emulator + entrypoint   │ ─────────▶  │ easystream APK  (est :48079) │
#   │  adb forward 48080      │             │ Go worker       (:48080)     │
#   └─────────────────────────┘             └──────────────────────────────┘
#   worker :48080 <--adb forward-- :48080

AVD="${ANDROID_AVD:-sandbox}"
MEM="${ANDROID_MEM:-6144}"
CPUS="${ANDROID_CPUS:-4}"
GPU="${ANDROID_GPU:-swiftshader_indirect}"
WIPE="${ANDROID_WIPE_DATA:-N}"
ADB="adb -s emulator-5554"
GUEST_WORKER=/data/local/tmp/easyworker
GUEST_WS=/data/local/tmp/workspace

export ANDROID_SDK_ROOT=/opt/android-sdk
export ANDROID_HOME=/opt/android-sdk
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-/opt/android-avd}"
export PATH="/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:${PATH}"

if [ "${ANDROID_AVD_HOME}" != "/opt/android-avd" ] && [ ! -f "${ANDROID_AVD_HOME}/${AVD}.avd/config.ini" ]; then
  echo "android: seeding AVD ${AVD} -> ${ANDROID_AVD_HOME}"
  mkdir -p "${ANDROID_AVD_HOME}"
  cp -a /opt/android-avd/. "${ANDROID_AVD_HOME}/" 2>/dev/null || true
fi
mkdir -p /workspace

cleanup() { kill "$(cat /tmp/emu.pid 2>/dev/null)" 2>/dev/null || true; }
trap cleanup TERM INT

# --- bring up the emulator + the in-guest stack ----------------------------
bring_up_guest() {
  WIPE_ARG=""; [ "${WIPE^^}" = "Y" ] && WIPE_ARG="-wipe-data"
  PROXY_ARG=""; P="${SANDBOX_PROXY:-${HTTP_PROXY:-}}"; [ -n "$P" ] && PROXY_ARG="-http-proxy ${P}"
  echo "android: starting emulator (headless, kvm, ${CPUS} vCPU, ${MEM} MB, gpu=${GPU})"
  emulator -avd "$AVD" \
    -no-window -no-audio -no-boot-anim -no-snapshot ${WIPE_ARG} ${PROXY_ARG} \
    -gpu "$GPU" -accel on -memory "$MEM" -cores "$CPUS" -port 5554 \
    >/tmp/emulator.log 2>&1 &
  echo $! > /tmp/emu.pid

  adb start-server >/dev/null 2>&1 || true
  booted=""
  for _ in $(seq 1 180); do
    bc="$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    [ "$bc" = "1" ] && { booted=1; break; }
    sleep 5
  done
  [ -z "$booted" ] && { echo "android: guest did not boot" >&2; tail -40 /tmp/emulator.log >&2; return 0; }
  echo "android: guest is up"
  $ADB shell "svc power stayon true" >/dev/null 2>&1 || true
  $ADB shell "wm dismiss-keyguard" >/dev/null 2>&1 || true

  # --- install + authorize the easystream daemon --------------------------
  # Do NOT swallow the error: a silent failure here left the daemon dead and
  # only produced a vague "est daemon not listening" further down.
  if ! out="$($ADB install -r /opt/easystream.apk 2>&1)"; then
    echo "android: apk install FAILED:" >&2
    printf '%s\n' "$out" >&2
  fi
  # Grant PROJECT_MEDIA BEFORE starting the app: the app requests the projection
  # on launch, so the appop must already be set or the consent dialog appears and
  # blocks the automatic flow. The app asks for
  # createConfigForDefaultDisplay() (whole screen, no range selector), so with
  # the appop the grant is fully automatic — no UI taps.
  $ADB shell appops set dev.easystream PROJECT_MEDIA allow >/dev/null 2>&1 || true
  sleep 1
  # Lock the daemon: control needs the token, view stays open. The APK reads it
  # from the Intent (an APK's System.getenv never sees `am start`'s env), and it
  # defaults to the worker's own token — the worker already drives the GUI
  # through its ComputerService, so the same secret grants no more.
  EST_CONTROL_TOKEN="${EAZYSTREAM_CONTROL_TOKEN:-${WORKER_TOKEN:-}}"
  $ADB shell am start -n dev.easystream/.MainActivity --ez autoGrant true \
    --es controlToken "'$EST_CONTROL_TOKEN'" >/dev/null 2>&1 || true
  sleep 6
  sleep 2
  $ADB shell settings put secure enabled_accessibility_services dev.easystream/dev.easystream.A11yService >/dev/null 2>&1 || true
  $ADB shell settings put secure accessibility_enabled 1 >/dev/null 2>&1 || true
  # Enable + select our headless IME. The daemon cannot inject keys with
  # `input keyevent` (that needs INJECT_EVENTS = shell/system); an
  # InputMethodService may send them through its InputConnection instead, so
  # Backspace/arrows/Enter/... work.
  $ADB shell ime enable dev.easystream/.EasyIme >/dev/null 2>&1 || true
  $ADB shell ime set dev.easystream/.EasyIme >/dev/null 2>&1 || true
  # Do NOT pre-grant PROJECT_MEDIA: with the appop set, the consent dialog is
  # auto-accepted with the DEFAULT range ("A single app") and the projection then
  # captures nothing. The dialog must appear so "Entire screen" can be chosen.
  sleep 2
  # --- wait until BOTH daemon ports are actually up -------------------------
  #
  # `am start` returning success only means the Intent was delivered; the app
  # then spends seconds bringing up MediaProjection before its two listeners
  # appear. One single check (the previous code) raced that: on a cold boot it
  # fired before 48079/48078 were bound, "restarted" an app that was still
  # starting, and then nothing ever verified the result — the pod ended up with
  # NO easystream at all (both ports refused, /desktop/ 502), which looked like a
  # token/permission failure but was simply a dead daemon.
  #
  # So: poll for up to ~90s, kicking the app once at the halfway mark, and FAIL
  # LOUDLY if it never comes up.
  est_up() { $ADB shell "nc -z 127.0.0.1 $1" >/dev/null 2>&1; }
  ready=0
  for i in $(seq 1 30); do
    if est_up 48079 && est_up 48078; then ready=1; break; fi
    if [ "$i" = 10 ]; then
      echo "android: daemon slow to bind (48079/48078); restarting the app once" >&2
      $ADB shell am force-stop dev.easystream >/dev/null 2>&1 || true
      sleep 2
      $ADB shell appops set dev.easystream PROJECT_MEDIA allow >/dev/null 2>&1 || true
      $ADB shell am start -n dev.easystream/.MainActivity --ez autoGrant true \
        --es controlToken "'$EST_CONTROL_TOKEN'" >/dev/null 2>&1 || true
    fi
    sleep 3
  done
  if [ "$ready" = 1 ]; then
    echo "android: easystream is up (est 48079, http 48078)"
  else
    echo "android: ERROR: easystream never bound 48079/48078 after 90s" >&2
    $ADB shell "logcat -d -s easystream:* AndroidRuntime:E 2>/dev/null | tail -20" >&2 || true
  fi

  # --- get the app OUT of the foreground -----------------------------------
  #
  # MainActivity is a setup screen ("3. Start the control service" + two
  # permission buttons). Launching it puts it in front of the Launcher, and it
  # STAYS there: the daemon is running and the screen streams fine, but the
  # "desktop" a viewer sees is that config page — and every injected pointer
  # event lands on its buttons instead of Android. Pressing HOME after the
  # daemon is up leaves the service running in the background (an
  # AccessibilityService and a MediaProjection are not tied to the Activity) and
  # puts the Launcher back in front.
  # Only background the app once the daemon is really up — pressing HOME while
  # it is still starting would just hide a config screen with no service behind
  # it, which is indistinguishable from a broken daemon.
  if [ "$ready" = 1 ]; then
    $ADB shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
    sleep 2
    $ADB shell am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1 || true
    sleep 1
  else
    echo "android: leaving the setup screen visible (daemon is down)" >&2
  fi

  # --- the Go worker (static) runs INSIDE the guest ------------------------
  $ADB push /opt/easyworker-android "$GUEST_WORKER" >/dev/null 2>&1 || echo "android: worker push failed" >&2
  $ADB shell chmod 755 "$GUEST_WORKER" >/dev/null 2>&1 || true
  $ADB shell mkdir -p "$GUEST_WS" >/dev/null 2>&1 || true
  $ADB shell "pkill -f $GUEST_WORKER" >/dev/null 2>&1 || true
  $ADB shell "cd /data/local/tmp && WORKER_OS=android WORKER_TOKEN='${WORKER_TOKEN:-}' WORKER_WORKSPACE=$GUEST_WS setsid $GUEST_WORKER -addr 127.0.0.1:48080 -workspace $GUEST_WS -db $GUEST_WS/jobs.db >/data/local/tmp/easyworker.log 2>&1 </dev/null &" >/dev/null 2>&1 || true
  sleep 3
  $ADB shell "cat /data/local/tmp/easyworker.log" 2>/dev/null | tail -5 >&2 || true
}
bring_up_guest &

# --- publish the in-guest worker's port ------------------------------------
# adb forward binds 127.0.0.1 ONLY, but the k8s Service dials the pod IP, so a
# front proxy must listen on 0.0.0.0 and relay to the adb-forwarded loopback.
echo "android: forwarding :48080 -> guest worker"
for _ in $(seq 1 240); do
  adb -s emulator-5554 forward tcp:14880 tcp:48080 >/dev/null 2>&1 || true
  if curl -s -m 2 -o /dev/null "http://127.0.0.1:14880/"; then break; fi
  sleep 3
done
echo "android: worker reachable on 127.0.0.1:14880; fronting on 0.0.0.0:48080"

# --- publish the in-guest easystream HTTP surface on :48078 ---------------
#
# easystream inside the emulator is the SAME daemon as on every other platform:
# it listens on :48079 (est binary protocol) AND :48078 (HTTP + the shared web
# UI). Only the worker port used to be forwarded, so /desktop/ (the worker's
# proxy to 127.0.0.1:48078) could not reach it on Android and the panel showed
# a dead link.
#
# adb forward binds 127.0.0.1 only, and the worker dials 127.0.0.1:48078 — so
# forwarding container:48078 -> guest:48078 is enough; no extra front proxy is
# needed because both processes live in this pod.
echo "android: forwarding :48078 -> guest easystream http"
adb -s emulator-5554 forward tcp:48078 tcp:48078 >/dev/null 2>&1 || true

# Front proxy: socat binds 0.0.0.0:48080 (the k8s Service targetPort) and relays
# to the adb-forwarded loopback. Run it in the foreground of its own subshell so
# it is restarted if it ever exits.
(
  while true; do
    socat TCP-LISTEN:48080,fork,reuseaddr TCP:127.0.0.1:14880
    echo "android: socat exited ($?); restarting" >&2
    sleep 2
  done
) &

# NOTE: no socat front proxy for :48078, on purpose.
#
# `adb forward tcp:48078 tcp:48078` already binds 127.0.0.1:48078, which is
# exactly what the worker dials for /desktop/ — verified: GET 127.0.0.1:48078
# returns the daemon's 17 KB UI. A socat in front of it fails with
# "Address already in use" and would be pointless: nothing outside the pod
# talks to :48078 directly, the worker proxies it.

# Keep the container (and the emulator) alive; re-assert the adb forward if it
# drops.
while true; do
  adb -s emulator-5554 forward tcp:14880 tcp:48080 >/dev/null 2>&1 || true
  sleep 10
done
