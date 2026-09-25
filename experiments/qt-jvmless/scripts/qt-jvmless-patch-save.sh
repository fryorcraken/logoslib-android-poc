#!/usr/bin/env bash
# qt-jvmless: save the drafted logos-module-loader-qt diff (copy only; original untouched).
set -u
EXP=${REPO_ROOT}/.work/experiments/qt-jvmless
C="$EXP/src-copies/logos-module-loader-qt"
P="$EXP/patches/logos-module-loader-qt-android-nojvm-shim.patch"
git -C "$C" add -N src/host/qt/android_nojvm_shim.h
git -C "$C" diff > "$P"
echo "base: $(git -C "$C" rev-parse HEAD)"
wc -l "$P"
git -C "$C" diff --stat
echo "original repo status (must be clean of our changes):"
git -C ${HOME}/src/logos-co/logos-module-loader-qt status --short | head -5
echo "== libraryPaths / applicationFilePath seen in JVM-less helper =="
grep -h -m3 -E "libraryPaths=|applicationDirPath=" "$EXP/logs/x1-run.log"
grep -h -m2 -E "libraryPaths=" "$EXP"/logs/x2-R1-A-default.logcat
