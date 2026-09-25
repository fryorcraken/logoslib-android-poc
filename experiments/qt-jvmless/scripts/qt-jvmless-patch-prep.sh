#!/usr/bin/env bash
# qt-jvmless: shared clone of logos-module-loader-qt to draft the Android no-JVM patch
# (the original repo is never modified).
set -u
EXP=${REPO_ROOT}/.work/experiments/qt-jvmless
C="$EXP/src-copies/logos-module-loader-qt"
mkdir -p "$EXP/src-copies" "$EXP/patches"
if [ ! -d "$C" ]; then
  git clone --shared ${HOME}/src/logos-co/logos-module-loader-qt "$C"
fi
git -C "$C" log -1 --format='%H %cd %s'
git -C "$C" status --short
