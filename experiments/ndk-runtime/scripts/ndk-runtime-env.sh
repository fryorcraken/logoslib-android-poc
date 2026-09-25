#!/usr/bin/env bash
# ndk-runtime: probe host tooling available for the Android cross-build.
set -u
W=${REPO_ROOT}/.work/experiments/ndk-runtime
mkdir -p "$W/logs" "$W/src" "$W/build" "$W/prefix/x86_64" "$W/patches" "$W/dl"
exec > >(tee "$W/logs/env.log") 2>&1
echo "== date"; date -Is
for t in cmake ninja make python3 curl wget git tar unzip nproc file readelf; do
  printf '%-8s ' "$t"; command -v "$t" || echo MISSING
done
cmake --version 2>&1 | head -1
ninja --version 2>&1 | head -1
NDK=${HOME}/android-ndk/android-ndk-r27c
cat "$NDK/source.properties"
ls "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin" | grep -E '^(clang|clang\+\+|llvm-ar|llvm-ranlib|llvm-strip|llvm-readelf|x86_64-linux-android34-clang)' | head -20
"$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" --version | head -1
ls "$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android/" | head -50
ls /nix/store | grep -E -- '-(cmake|ninja)-[0-9]' | grep -v '\.drv$' | head -20
echo "== adb devices"; /usr/bin/adb devices 2>&1 | head
echo "== disk"; df -h "$W" | tail -1
