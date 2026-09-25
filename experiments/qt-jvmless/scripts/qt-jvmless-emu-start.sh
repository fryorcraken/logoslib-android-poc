#!/usr/bin/env bash
# qt-jvmless: boot a private read-only instance of AVD delivery-demo on port 5570
# (so it cannot collide with other sessions' emulators) and wait for boot.
# Attempt 1 (-no-window -gpu swiftshader_indirect) SIGSEGVs at cold boot on this host
# (same as seen by wallet-android and ndk-runtime), so this uses the windowed
# qemu binary with the Qt window hidden (-qt-hide-window).
set -u
EXP=${REPO_ROOT}/.work/experiments/qt-jvmless
mkdir -p "$EXP/logs"
exec > >(tee "$EXP/logs/emu-start.log") 2>&1
export ANDROID_SDK_ROOT=${HOME}/android-sdk
export ANDROID_HOME=${HOME}/android-sdk
ADB=/usr/bin/adb
EMU=${HOME}/android-sdk/emulator/emulator
PORT=5570
S=emulator-$PORT
MODE="${1:-hidden}"
date -Is
"$ADB" devices -l
echo "DISPLAY=${DISPLAY:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
if "$ADB" devices | grep -q "^$S"; then
  echo "emulator $S already running"
else
  if [ "$MODE" = "hidden" ]; then
    ARGS=(-avd delivery-demo -read-only -port $PORT -no-audio -no-boot-anim -no-snapshot-save -qt-hide-window)
  else
    ARGS=(-avd delivery-demo -read-only -port $PORT -no-audio -no-boot-anim -no-snapshot-save)
  fi
  echo "CMD: $EMU ${ARGS[*]}"
  setsid nohup "$EMU" "${ARGS[@]}" > "$EXP/logs/emulator-$MODE.log" 2>&1 < /dev/null &
  echo "emulator pid $!"
fi
START=$(date +%s)
sleep 5
pgrep -fa "qemu-system.*-port $PORT" | head -3
timeout 180 "$ADB" -s $S wait-for-device
echo "wait-for-device rc=$?"
B=0
for i in $(seq 1 150); do
  B=$("$ADB" -s $S shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  if [ "$B" = "1" ]; then break; fi
  sleep 2
done
echo "boot_completed=$B after $(( $(date +%s) - START ))s"
"$ADB" devices -l
"$ADB" -s $S shell getprop ro.build.version.sdk
"$ADB" -s $S shell getprop ro.product.cpu.abilist
"$ADB" -s $S shell getprop ro.build.fingerprint
"$ADB" -s $S shell getenforce
"$ADB" -s $S shell uname -a
"$ADB" -s $S shell getconf PAGE_SIZE
"$ADB" -s $S shell id
"$ADB" -s $S shell 'echo shell TMPDIR=$TMPDIR'
tail -5 "$EXP/logs/emulator-$MODE.log"
