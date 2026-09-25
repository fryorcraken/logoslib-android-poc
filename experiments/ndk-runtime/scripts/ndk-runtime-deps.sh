#!/usr/bin/env bash
# ndk-runtime step 2: cross-build fmt 10.2.1 + spdlog 1.15.2 (external fmt, shared,
# as nixpkgs builds them for liblogos) and install nlohmann_json 3.11.3 headers
# into the x86_64 prefix with the NDK CMake toolchain.
set -u
W=${REPO_ROOT}/.work/experiments/ndk-runtime
NDK=${HOME}/android-ndk/android-ndk-r27c
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64
PREFIX=$W/prefix/x86_64
NINJA=/nix/store/7bgiqc706pzzb1gmwgpzdfg491w4a8nx-ninja-1.13.1/bin/ninja
LOG=$W/logs/deps.log
mkdir -p "$W/logs" "$W/src" "$W/dl" "$W/build"
exec > >(tee "$LOG") 2>&1
date -Is

fetch() { # url out
  [ -s "$2" ] || curl -fL --retry 3 -o "$2" "$1" || exit 1
  sha256sum "$2"
}
fetch https://github.com/fmtlib/fmt/archive/refs/tags/10.2.1.tar.gz "$W/dl/fmt-10.2.1.tar.gz"
fetch https://github.com/gabime/spdlog/archive/refs/tags/v1.15.2.tar.gz "$W/dl/spdlog-1.15.2.tar.gz"
fetch https://github.com/nlohmann/json/archive/refs/tags/v3.11.3.tar.gz "$W/dl/json-3.11.3.tar.gz"
[ -d "$W/src/fmt-10.2.1" ] || tar -xzf "$W/dl/fmt-10.2.1.tar.gz" -C "$W/src"
[ -d "$W/src/spdlog-1.15.2" ] || tar -xzf "$W/dl/spdlog-1.15.2.tar.gz" -C "$W/src"
[ -d "$W/src/json-3.11.3" ] || tar -xzf "$W/dl/json-3.11.3.tar.gz" -C "$W/src"

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
)

step() { # name srcdir extra-args...
  local name=$1 src=$2; shift 2
  local b=$W/build/$name-x86_64
  rm -rf "$b"
  echo "=================== $name configure"
  echo "CMD: cmake -S $src -B $b ${COMMON[*]} $*"
  local t0=$(date +%s)
  cmake -S "$src" -B "$b" "${COMMON[@]}" "$@" || { echo "$name CONFIGURE FAILED"; return 1; }
  cmake --build "$b" -j16 || { echo "$name BUILD FAILED"; return 1; }
  cmake --install "$b" || { echo "$name INSTALL FAILED"; return 1; }
  echo "$name OK WALL_SECONDS=$(( $(date +%s) - t0 ))"
}

step fmt "$W/src/fmt-10.2.1" -DBUILD_SHARED_LIBS=ON -DFMT_TEST=OFF -DFMT_DOC=OFF -DFMT_INSTALL=ON || exit 1
step spdlog "$W/src/spdlog-1.15.2" -DSPDLOG_BUILD_SHARED=ON -DSPDLOG_FMT_EXTERNAL=ON \
  -DSPDLOG_BUILD_EXAMPLE=OFF -DSPDLOG_BUILD_TESTS=OFF -DSPDLOG_BUILD_BENCH=OFF -DSPDLOG_INSTALL=ON || exit 1
step nlohmann_json "$W/src/json-3.11.3" -DJSON_BuildTests=OFF -DJSON_Install=ON || exit 1

echo "== installed"
ls -la "$PREFIX/lib" | grep -E 'fmt|spdlog'
ls "$PREFIX/lib/cmake" "$PREFIX/share/cmake" 2>/dev/null
for f in "$PREFIX"/lib/libfmt.so "$PREFIX"/lib/libspdlog.so; do
  echo "--- $f"; "$TC/bin/llvm-readelf" -h -d -l "$f" | grep -E 'Machine|SONAME|NEEDED|LOAD ' | head
done
du -bL "$PREFIX"/lib/libfmt.so "$PREFIX"/lib/libspdlog.so
date -Is
