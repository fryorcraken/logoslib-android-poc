#!/usr/bin/env bash
# qt-jvmless: confirm the built APKs contain the current Kotlin code.
set -u
APP=${REPO_ROOT}/.work/experiments/qt-jvmless/app/app/build/outputs/apk
for v in withjar nojar; do
  APK="$APP/$v/debug/app-$v-debug.apk"
  echo "== $v =="
  unzip -l "$APK" | grep -E 'dex'
  for s in 'HELPER posix_spawn' 'libart' 'spawnHelper' 'org/logos/qrotest/MainActivity'; do
    n=$(unzip -p "$APK" 'classes*.dex' | strings | grep -c "$s")
    echo "  '$s' occurrences in dex: $n"
  done
done
