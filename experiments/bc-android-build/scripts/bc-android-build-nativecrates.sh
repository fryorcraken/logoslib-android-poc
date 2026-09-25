#!/usr/bin/env bash
set -u
EXP=${REPO_ROOT}/.work/experiments/bc-android-build
python3 ${REPO_ROOT}/.work/scripts/bc-android-build-nativecrates.py "$EXP/out/metadata-x86_64-android.json" 2>&1 | tee "$EXP/out/native-crates-x86_64-android.txt"
echo "== libc++ linker scripts in NDK r27c (API 34)"
L=${HOME}/android-ndk/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib
for f in x86_64-linux-android/34/libc++.so x86_64-linux-android/34/libc++.a aarch64-linux-android/34/libc++.so; do echo "$f: $(head -c 200 "$L/$f" | tr -d '\0')"; done
echo "== setup.log tail"
tail -3 "$EXP/logs/setup.log"
