#!/usr/bin/env bash
# ndk-runtime step 3/4: configure + build the Qt-free runtime repos (copies under
# experiments/ndk-runtime/src, test-gate patch applied by ndk-runtime-prep-src.sh)
# with the NDK toolchain against the x86_64 prefix. Keeps going after a failure
# so every compile error is recorded; per-project status is summarised at the end.
set -u
W=${REPO_ROOT}/.work/experiments/ndk-runtime
NDK=${HOME}/android-ndk/android-ndk-r27c
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64
PREFIX=$W/prefix/x86_64
NINJA=/nix/store/7bgiqc706pzzb1gmwgpzdfg491w4a8nx-ninja-1.13.1/bin/ninja
LOG=$W/logs/container.log
export TMPDIR=$W/tmp
mkdir -p "$W/logs" "$W/build" "$TMPDIR"
exec 3>&1 >"$LOG" 2>&1
trap 'grep -A20 "=== SUMMARY" "$LOG" >&3' EXIT
date -Is

COMMON=(
  -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA"
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
  -DANDROID_ABI=x86_64 -DANDROID_PLATFORM=android-34 -DANDROID_STL=c++_shared
  -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON
  -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384
  -DCMAKE_EXE_LINKER_FLAGS=-Wl,-z,max-page-size=16384
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_FIND_ROOT_PATH="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX"
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH
  -DBoost_USE_STATIC_LIBS=ON
)

declare -A STATUS
step() { # name srcdir extra-args...
  local name=$1 src=$2; shift 2
  local b=$W/build/$name-x86_64
  rm -rf "$b"
  echo "=================== $name configure"
  echo "CMD: cmake -S $src -B $b ${COMMON[*]} $*"
  local t0=$(date +%s)
  if ! cmake -S "$src" -B "$b" "${COMMON[@]}" "$@"; then STATUS[$name]="CONFIGURE-FAILED"; return 1; fi
  echo "=================== $name build"
  if ! cmake --build "$b" -j16 -v -- -k 0; then STATUS[$name]="BUILD-FAILED"; return 1; fi
  if ! cmake --install "$b"; then STATUS[$name]="INSTALL-FAILED"; return 1; fi
  STATUS[$name]="OK wall=$(( $(date +%s) - t0 ))s"
}

# CLI11 2.5.0 (header-only; version nixpkgs ships to logos_host_qt) -- needed only
# for the Qt-free host probe compiled by the smoke step.
if [ ! -f "$PREFIX/include/CLI/CLI.hpp" ]; then
  [ -s "$W/dl/CLI11-2.5.0.tar.gz" ] || curl -fL --retry 3 -o "$W/dl/CLI11-2.5.0.tar.gz" https://github.com/CLIUtils/CLI11/archive/refs/tags/v2.5.0.tar.gz
  sha256sum "$W/dl/CLI11-2.5.0.tar.gz"
  [ -d "$W/src/CLI11-2.5.0" ] || tar -xzf "$W/dl/CLI11-2.5.0.tar.gz" -C "$W/src"
  step cli11 "$W/src/CLI11-2.5.0" -DCLI11_BUILD_TESTS=OFF -DCLI11_BUILD_EXAMPLES=OFF -DCLI11_BUILD_DOCS=OFF -DCLI11_PRECOMPILED=OFF -DCLI11_INSTALL=ON
fi

step logos-container "$W/src/logos-container" -DLOGOS_CONTAINER_BUILD_TESTS=OFF
step logos-module-loader "$W/src/logos-module-loader" -DLOGOS_MODULE_LOADER_BUILD_TESTS=OFF \
  -DLOGOS_CONTAINER_ROOT="$PREFIX"
step logos-container-subprocess "$W/src/logos-container-subprocess" \
  -DLOGOS_CONTAINER_ROOT="$PREFIX" -DLOGOS_CONTAINER_SUBPROCESS_BUILD_TESTS=OFF
step process-stats "$W/src/process-stats" -DPROCESS_STATS_BUILD_TESTS=OFF
# Parent-side loader lib only: the repo's top-level CMakeLists hard-requires Qt,
# OpenSSL, CLI11, logos-protocol/qt-sdk/module for logos_host_qt, so a tiny
# out-of-tree wrapper (not a patch) builds just logos_module_loader_qt.
step logos-module-loader-qt-parent "$W/src/wrap/loader-qt-parent" \
  -DLOADER_QT_SRC="$W/src/logos-module-loader-qt" \
  -DLOGOS_CONTAINER_ROOT="$PREFIX" -DLOGOS_MODULE_LOADER_ROOT="$PREFIX"

echo "=================== SUMMARY"
for k in "${!STATUS[@]}"; do echo "$k: ${STATUS[$k]}"; done | sort
echo "== artifacts"
ls -la "$PREFIX/lib"/liblogos_* "$PREFIX/lib"/libprocess_stats* 2>/dev/null
ls "$PREFIX/include" "$PREFIX/lib/cmake"
date -Is
