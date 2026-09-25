#!/usr/bin/env bash
# qt-jvmless: sparse shallow clone of qtbase/qtremoteobjects v6.11.1 sources (read-only
# reference, to locate the JNI-touching code paths hit in X1).
set -u
EXP=${REPO_ROOT}/.work/experiments/qt-jvmless
mkdir -p "$EXP/logs" "$EXP/qtsrc"
exec > >(tee "$EXP/logs/qtsrc.log") 2>&1
cd "$EXP/qtsrc" || exit 1
if [ ! -d qtbase ]; then
  git clone --depth 1 --branch v6.11.1 --filter=blob:none --sparse https://github.com/qt/qtbase.git qtbase
  git -C qtbase sparse-checkout set src/corelib src/network/socket src/android/jar/src
fi
if [ ! -d qtremoteobjects ]; then
  git clone --depth 1 --branch v6.11.1 https://github.com/qt/qtremoteobjects.git qtremoteobjects
fi
git -C qtbase log -1 --oneline
git -C qtremoteobjects log -1 --oneline
echo "== appVersion / applicationVersionSet in qcoreapplication.cpp =="
grep -n -E 'appVersion|applicationVersionSet|Q_OS_ANDROID|QJni|QtAndroid' qtbase/src/corelib/kernel/qcoreapplication.cpp
