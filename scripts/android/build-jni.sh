#!/usr/bin/env bash
# scripts/android/build-jni.sh -- compile the :logos-core JNI shim into liblogos_jni.so.
#
# Compiles android/logos-core/src/main/cpp/ (logos_jni.cpp, qt_loop.cpp, stdio_logcat.cpp;
# CMakeLists.txt there) with the NDK through Qt's Android toolchain file, against the Qt
# 6.11.1 Android prebuilt (QtCore only) and the Logos runtime installed in the prefix by
# build-deps.sh + build-runtime.sh. Gradle does not build native code: stage.sh copies the
# result into :logos-core's jniLibs.
#
# Inputs
#   build/android/<abi>/prefix/include/logos_core.h      (logos-liblogos, LOGOS_LIBLOGOS_REV)
#   build/android/<abi>/prefix/include/logos_protocol.h  (logos-protocol, LOGOS_PROTOCOL_REV)
#   build/android/<abi>/prefix/lib/liblogos_core.so, liblogos_protocol.so
#   Qt: $QT_ROOT/android_<abi> (target) + $QT_ROOT/gcc_64 (host tools), see env.sh
# Outputs
#   build/android/<abi>/jni/liblogos_jni.so   SONAME liblogos_jni.so, 16 KB-aligned LOADs,
#                                             NEEDED liblogos_core/liblogos_protocol/Qt6Core
#   build/android/<abi>/obj/logos-jni/        CMake build tree (incremental)
#   build/logs/build-jni-<abi>.log            full log
# Pinned versions: scripts/android/versions.env (NDK r27c, API 34, Qt 6.11.1, liblogos
#   db45024, logos-protocol 8bbc027 / 0.9.0), read through env.sh.
#
# Usage
#   bash scripts/android/build-jni.sh [x86_64|arm64-v8a] [--compile-only]
#     --compile-only   only compile the objects (syntax/ABI check), no link: works before
#                      the runtime exists when LOGOS_CORE_INCLUDE_DIR and
#                      LOGOS_PROTOCOL_INCLUDE_DIR name header directories (e.g. the pinned
#                      upstream sources); output goes to obj/logos-jni-compile-only.
#   Environment: ABI, FORCE=1 (reconfigure from scratch), COMPILE_ONLY=1 (= --compile-only),
#   LOGOS_CORE_INCLUDE_DIR, LOGOS_PROTOCOL_INCLUDE_DIR, plus everything env.sh reads.
# Re-runnable: the CMake tree is reused and the build is incremental unless FORCE=1.
set -euo pipefail

COMPILE_ONLY="${COMPILE_ONLY:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    x86_64|arm64-v8a) export ABI=$1 ;;
    --compile-only) COMPILE_ONLY=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 0 ;;
    *) echo "build-jni.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done
export ABI="${ABI:-x86_64}"
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
log_setup build-jni
trap 'on_error build-jni' ERR

SRC="$REPO_ROOT/android/logos-core/src/main/cpp"
OUT_DIR="$ANDROID_BUILD/jni"
if [ "$COMPILE_ONLY" = 1 ]; then B="$OBJ_DIR/logos-jni-compile-only"; else B="$OBJ_DIR/logos-jni"; fi

args=(-DLOGOS_PREFIX="$PREFIX")
[ -z "${LOGOS_CORE_INCLUDE_DIR:-}" ] || args+=(-DLOGOS_CORE_INCLUDE_DIR="$LOGOS_CORE_INCLUDE_DIR")
[ -z "${LOGOS_PROTOCOL_INCLUDE_DIR:-}" ] || args+=(-DLOGOS_PROTOCOL_INCLUDE_DIR="$LOGOS_PROTOCOL_INCLUDE_DIR")
[ "$COMPILE_ONLY" = 1 ] && args+=(-DLOGOS_JNI_COMPILE_ONLY=ON) || args+=(-DLOGOS_JNI_COMPILE_ONLY=OFF)

if [ "$COMPILE_ONLY" != 1 ]; then
  for f in "$PREFIX/lib/liblogos_core.so" "$PREFIX/lib/liblogos_protocol.so"; do
    [ -f "$f" ] || die "$f missing: run scripts/android/build-deps.sh and build-runtime.sh for $ABI first (or use --compile-only)"
  done
fi

step_begin "logos-jni$([ "$COMPILE_ONLY" = 1 ] && echo ' (compile only)')"
# A changed argument set (other header dirs, compile-only switch) needs a fresh configure.
cfg_key="${args[*]} | ${QT_CMAKE_ARGS[*]}"
if [ "$FORCE" = 1 ] || [ ! -f "$B/CMakeCache.txt" ] || [ "$(cat "$B/.configure-key" 2>/dev/null)" != "$cfg_key" ]; then
  rm -rf "$B"
  echo "-- cmake configure: cmake -S $SRC -B $B ${QT_CMAKE_ARGS[*]} ${args[*]}"
  cmake -S "$SRC" -B "$B" "${QT_CMAKE_ARGS[@]}" "${args[@]}"
  printf '%s\n' "$cfg_key" > "$B/.configure-key"
else
  say "-- reusing CMake tree $B (incremental; FORCE=1 to reconfigure)"
fi
cmake --build "$B" -j "$JOBS" --verbose

if [ "$COMPILE_ONLY" = 1 ]; then
  objs=$(find "$B" -name '*.o' | sort)
  say "-- compiled (no link): $(printf '%s\n' "$objs" | wc -l) object files"
  printf '%s\n' "$objs"
  step_done logos-jni-compile-only "$cfg_key"
  say "build-jni: OK (compile only, ABI=$ABI)"
  exit 0
fi

mkdir -p "$OUT_DIR"
cp -f "$B/liblogos_jni.so" "$OUT_DIR/liblogos_jni.so"
SO="$OUT_DIR/liblogos_jni.so"

# ---- sanity: what the Kotlin side and stage.sh rely on
hdr=$("$READELF" -h -l -d -W "$SO")
soname=$(printf '%s\n' "$hdr" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
needed=$(printf '%s\n' "$hdr" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')
aligns=$(printf '%s\n' "$hdr" | awk '$1 == "LOAD" {print $NF}' | sort -u | tr '\n' ' ')
exports=$("$NM" -D --defined-only "$SO" | awk '{print $3}')
njni=$(printf '%s\n' "$exports" | grep -c '^Java_com_fryorcraken_logoslib_core_internal_LogosNative_' || true)
[ "$soname" = liblogos_jni.so ] || die "SONAME is '$soname', expected liblogos_jni.so"
grep -qx JNI_OnLoad <<< "$exports" || die "JNI_OnLoad is not exported"
for al in $aligns; do [ $((al)) -ge $((0x4000)) ] || die "LOAD p_align $al < 0x4000"; done
say "-- $SO: $(stat -c %s "$SO") bytes, SONAME $soname, LOAD align $aligns"
say "-- NEEDED: $needed"
say "-- exports: JNI_OnLoad + $njni LogosNative entry points"
step_done logos-jni "$cfg_key"
say "build-jni: OK ($SO)"
