#!/usr/bin/env bash
# ndk-runtime: rebuild smoke -> package APK -> run on emulator (shell + app).
S=${REPO_ROOT}/.work/scripts
bash "$S/ndk-runtime-smoke-build.sh" | grep -v '^API28'
bash "$S/ndk-runtime-apk.sh"
bash "$S/ndk-runtime-smoke-run.sh"
