#!/usr/bin/env bash
# wallet-android: JVM-less runtime smoke test of libwallet_ffi.so on the x86_64
# API 34 emulator. A = no-prove, platform verifier (default TLS), dynamic pcsc
# stub. B = no-prove + webpki-roots (patch 02), static pcsc stub.
set -u
EXP=${REPO_ROOT}/.work/experiments/wallet-android
NDK=${HOME}/android-ndk/android-ndk-r27c
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
CLANG="$TC/x86_64-linux-android34-clang"
T=x86_64-linux-android
SM="$EXP/smoke"
mkdir -p "$EXP/logs" "$SM/A" "$SM/B"
exec > >(tee "$EXP/logs/smoke.log") 2>&1
SEQ=https://testnet.lez.logos.co/
DEV=/data/local/tmp/wsmoke

echo "== build harness"
cp "$EXP/out/$T/libwallet_ffi.stripped.so" "$SM/A/libwallet_ffi.so"
cp "$EXP/pcsc-stub/$T/libpcsclite.so" "$SM/A/libpcsclite.so"
cp "$EXP/out/$T-webpki/libwallet_ffi.stripped.so" "$SM/B/libwallet_ffi.so"
for V in A B; do
  HDR="$EXP/out/$T"; [ "$V" = B ] && HDR="$EXP/out/$T-webpki"
  "$CLANG" -O1 -Wall -I"$HDR" -o "$SM/$V/wallet_smoke" "$SM/wallet_smoke.c" \
    -L"$SM/$V" -lwallet_ffi -Wl,-rpath-link,"$SM/$V" -Wl,-z,max-page-size=16384
  echo "harness $V exit=$?"
done
"$TC/llvm-readelf" -d "$SM/A/wallet_smoke" | grep NEEDED

echo "== device"
adb devices -l
adb shell getprop ro.build.version.sdk
echo "== wait for network"
for i in $(seq 1 30); do
  if adb shell ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then echo "net up after ${i} tries"; break; fi
  sleep 2
done
adb shell ping -c 1 -W 3 testnet.lez.logos.co 2>&1 | head -2

echo "== push"
adb shell rm -rf "$DEV"
adb shell mkdir -p "$DEV/A" "$DEV/B"
adb push "$SM/A/." "$DEV/A/" | tail -1
adb push "$SM/B/." "$DEV/B/" | tail -1
adb shell chmod 755 "$DEV/A/wallet_smoke" "$DEV/B/wallet_smoke"
adb shell ls -la "$DEV/A" "$DEV/B"

for V in A B; do
  echo "================ run $V  $(date -Is)"
  adb logcat -c
  timeout 180 adb shell "cd $DEV/$V && LD_LIBRARY_PATH=$DEV/$V ./wallet_smoke $DEV/$V/w $SEQ; echo EXIT=\$?"
  echo "adb-exit=$?"
  echo "-- logcat (crash / rust / tls lines)"
  adb logcat -d | grep -i -E 'wallet_smoke|panick|rustls|platform.verifier|abort|DEBUG   :|signal [0-9]|Fatal' | head -40
  echo "-- written config"
  adb shell cat "$DEV/$V/w/wallet_config.json" | head -5
done
echo DONE
