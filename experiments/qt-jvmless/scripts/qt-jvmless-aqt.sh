#!/usr/bin/env bash
# qt-jvmless X1.1: install Qt 6.11.1 android_x86_64 (qtbase + qtremoteobjects)
# and host linux_gcc_64 6.11.1 (qtbase + icu + qtremoteobjects) with aqt.
set -u
EXP=${REPO_ROOT}/.work/experiments/qt-jvmless
LOG="$EXP/logs/aqt.log"
mkdir -p "$EXP/logs" "$EXP/src" "$EXP/patches" "$EXP/build"
exec > >(tee "$LOG") 2>&1
PROBE=${REPO_ROOT}/.work/probe
AQT="$PROBE/qt-venv/bin/aqt"
OUT="$PROBE/qt"
cd "$OUT" || exit 1
echo "== aqt version =="
"$AQT" version
echo "== CMD: aqt install-qt all_os android 6.11.1 android_x86_64 --archives qtbase -m qtremoteobjects --outputdir $OUT =="
"$AQT" install-qt all_os android 6.11.1 android_x86_64 --archives qtbase -m qtremoteobjects --outputdir "$OUT"
echo "rc=$?"
echo "== CMD: aqt install-qt linux desktop 6.11.1 linux_gcc_64 --archives qtbase icu -m qtremoteobjects --outputdir $OUT =="
"$AQT" install-qt linux desktop 6.11.1 linux_gcc_64 --archives qtbase icu -m qtremoteobjects --outputdir "$OUT"
echo "rc=$?"
echo "== tree =="
ls -la "$OUT/6.11.1"
du -sh "$OUT"/6.11.1/*
ls "$OUT/6.11.1/android_x86_64/lib" | grep -E '\.so$'
ls "$OUT/6.11.1/gcc_64/libexec" "$OUT/6.11.1/gcc_64/bin" 2>&1 | head -60
cat "$OUT/6.11.1/android_x86_64/bin/target_qt.conf" 2>&1
