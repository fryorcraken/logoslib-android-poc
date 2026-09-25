#!/usr/bin/env bash
# ndk-runtime step 3a: copy (git clone --shared) the Qt-free runtime repos into the
# experiment tree and apply the minimal test-disable patch. Diffs are saved under
# patches/. Idempotent: re-running resets each clone to its source HEAD first.
set -u
W=${REPO_ROOT}/.work/experiments/ndk-runtime
LC=${HOME}/src/logos-co
LOG=$W/logs/prep-src.log
mkdir -p "$W/logs" "$W/src" "$W/patches"
exec > >(tee "$LOG") 2>&1
date -Is

for r in logos-container logos-container-subprocess logos-module-loader logos-module-loader-qt process-stats; do
  if [ ! -d "$W/src/$r/.git" ]; then
    git clone -q --shared "$LC/$r" "$W/src/$r" || exit 1
  fi
  git -C "$W/src/$r" checkout -q -- .
  git -C "$W/src/$r" clean -qfd
  echo "$r $(git -C "$W/src/$r" rev-parse HEAD)"
done

# Minimal test gate, the same shape process-stats already has
# (PROCESS_STATS_BUILD_TESTS): an option defaulting ON wrapped around the GTest
# FetchContent + tests subdirectory, so native builds are unchanged and a cross
# build passes -D<X>_BUILD_TESTS=OFF.
gate_tests() { # repo optname
  local f=$W/src/$1/CMakeLists.txt opt=$2
  python3 - "$f" "$opt" <<'PY'
import sys, re
path, opt = sys.argv[1], sys.argv[2]
s = open(path).read()
start = s.index("# GoogleTest setup")
end_marker = "add_subdirectory(tests)\n"
end = s.index(end_marker, start) + len(end_marker)
block = s[start:end]
new = (f'option({opt} "Build the test suite (needs GoogleTest)" ON)\n'
       f'if({opt})\n' + block + f'endif()  # {opt}\n')
s = s[:start] + new + s[end:]
open(path, "w").write(s)
PY
  git -C "$W/src/$1" diff > "$W/patches/$1-test-gate.diff"
  echo "--- patch $1"; cat "$W/patches/$1-test-gate.diff"
}
gate_tests logos-container LOGOS_CONTAINER_BUILD_TESTS
gate_tests logos-container-subprocess LOGOS_CONTAINER_SUBPROCESS_BUILD_TESTS
gate_tests logos-module-loader LOGOS_MODULE_LOADER_BUILD_TESTS
date -Is
