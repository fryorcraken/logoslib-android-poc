#!/usr/bin/env bash
# wallet-android: boot the x86_64 API 34 AVD headless (detached) and wait for boot.
set -u
EXP=${REPO_ROOT}/.work/experiments/wallet-android
mkdir -p "$EXP/logs"
exec > >(tee "$EXP/logs/emu-start.log") 2>&1
export ANDROID_SDK_ROOT=${HOME}/android-sdk
export ANDROID_HOME=${HOME}/android-sdk
EMU=${HOME}/android-sdk/emulator/emulator

adb devices -l
if adb devices | grep -q 'emulator-'; then
  echo "emulator already running"
else
  echo "== starting AVD delivery-demo $(date -Is)"
  # attempt 1 (-no-window -gpu swiftshader_indirect -no-snapshot) and attempt 2
  # (-no-window -gpu guest -feature -Vulkan) both SIGSEGV in
  # qemu-system-x86_64-headless at cold boot. Attempt 3: windowed binary, defaults.
  echo "DISPLAY=${DISPLAY:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
  nohup setsid "$EMU" -avd delivery-demo -no-audio -no-boot-anim \
    -no-snapshot-save \
    > "$EXP/logs/emulator.out" 2>&1 < /dev/null &
  echo "emulator pid $!"
fi

START=$(date +%s)
sleep 5
pgrep -fa 'qemu-system|emulator' | head -3
timeout 180 adb wait-for-device
for i in $(seq 1 120); do
  B=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  if [ "$B" = "1" ]; then break; fi
  sleep 2
done
echo "boot_completed=$B after $(( $(date +%s) - START ))s"
adb shell getprop ro.build.version.sdk
adb shell getprop ro.product.cpu.abi
adb shell uname -a
echo "== network check from device"
adb shell ping -c 1 -W 3 8.8.8.8 2>&1 | tail -2
adb shell 'toybox nslookup testnet.lez.logos.co 2>&1 || getent hosts testnet.lez.logos.co 2>&1' | tail -3
tail -5 "$EXP/logs/emulator.out"
echo DONE
