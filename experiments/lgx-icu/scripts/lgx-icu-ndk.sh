#!/usr/bin/env bash
# lgx-icu: compile + link the ported path_normalizer.cpp (ICU C API) with NDK
# r27c against the sysroot libicu.so stub. No device/emulator is used.
set -u
EXP=${REPO_ROOT}/.work/experiments/lgx-icu
mkdir -p "$EXP/logs" "$EXP/bin/android"
LOG="$EXP/logs/ndk.log"
exec > >(tee "$LOG") 2>&1

NDK=${HOME}/android-ndk/android-ndk-r27c
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
SYSROOT=$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot
ORIG_SRC=/nix/store/7f6d5ba9jv4hkn2r923kxjxac271i5hn-source
PORT=$EXP/src/logos-package-4cdb302/src/core
B=$EXP/bin/android
READELF=$TC/llvm-readelf
NM=$TC/llvm-nm
echo "clang: $($TC/clang++ --version | head -1)"
grep -e Pkg.Revision "$NDK/source.properties"

echo
echo "== 0. what the NDK libicu.so stub exports for the six functions the port uses"
for api in 31 34; do
  for triple in x86_64-linux-android aarch64-linux-android; do
    S=$SYSROOT/usr/lib/$triple/$api/libicu.so
    echo "-- $triple/$api/libicu.so ($(stat -c %s "$S") bytes, $($NM -D --defined-only "$S" | wc -l) defined dynsyms)"
    $NM -D --defined-only "$S" | grep -w -e unorm2_getNFCInstance -e unorm2_normalize -e unorm2_isNormalized \
      -e u_strFromUTF8WithSub -e u_strToUTF8WithSub -e u_strToLower
  done
done
echo "-- does any NDK libicu.so export C++ (icu::) symbols?"
$NM -D --defined-only "$SYSROOT/usr/lib/x86_64-linux-android/34/libicu.so" | grep -c -e ' _ZN' -e ' _ZNK'

cc() { # label target outfile extra-args...
  local label=$1 target=$2 out=$3; shift 3
  echo
  echo "== $label ($target)"
  set -x
  "$TC/clang++" --target="$target" -stdlib=libc++ -std=c++17 -O2 -Wall -Wextra "$@" -o "$B/$out"
  local rc=$?
  { set +x; } 2>/dev/null
  echo "exit=$rc"
  if [ $rc -eq 0 ]; then
    echo "-- file: $(file -b "$B/$out" | cut -c1-120)"
    echo "-- NEEDED:"; $READELF -d "$B/$out" | grep NEEDED
    echo "-- undefined ICU imports:"; $NM -D --undefined-only "$B/$out" | grep -e ' u_' -e ' unorm2_' -e icu
    echo "-- LOAD alignment:"; $READELF -lW "$B/$out" | grep LOAD | awk '{print $NF}' | sort -u | tr '\n' ' '; echo
  fi
}

# 1. test executable, x86_64 API 34 (what the task asks for)
cc "port + vector test, exe" x86_64-linux-android34 vectors-port-x86_64-34 \
  -I"$PORT" "$EXP/test/pathnorm_vectors.cpp" "$PORT/path_normalizer.cpp" -licu

# 2. shared library, x86_64 API 34
cc "port as shared lib" x86_64-linux-android34 libpathnorm-port-x86_64-34.so \
  -shared -fPIC -I"$PORT" "$PORT/path_normalizer.cpp" -licu

# 3. static libc++ variant (what an APK would ship without libc++_shared)
cc "port + vector test, exe, static libc++" x86_64-linux-android34 vectors-port-x86_64-34-staticcxx \
  -static-libstdc++ -I"$PORT" "$EXP/test/pathnorm_vectors.cpp" "$PORT/path_normalizer.cpp" -licu

# 4. aarch64 API 34 with 16 KB pages
cc "port as shared lib" aarch64-linux-android34 libpathnorm-port-arm64-34.so \
  -shared -fPIC -Wl,-z,max-page-size=16384 -I"$PORT" "$PORT/path_normalizer.cpp" -licu
cc "port + vector test, exe" aarch64-linux-android34 vectors-port-arm64-34 \
  -Wl,-z,max-page-size=16384 -I"$PORT" "$EXP/test/pathnorm_vectors.cpp" "$PORT/path_normalizer.cpp" -licu

# 5. minimum API for libicu.so
cc "port, API 31 (floor)" x86_64-linux-android31 vectors-port-x86_64-31 \
  -I"$PORT" "$EXP/test/pathnorm_vectors.cpp" "$PORT/path_normalizer.cpp" -licu

# 6. API 28 (Qt 6.11 / posix_spawn floor): expected to fail
cc "port, API 28 (expected failure)" x86_64-linux-android28 vectors-port-x86_64-28 \
  -I"$PORT" "$EXP/test/pathnorm_vectors.cpp" "$PORT/path_normalizer.cpp" -licu
cc "port, API 28 + weak unavailable symbols + API-31 stub" x86_64-linux-android28 vectors-port-x86_64-28-weak \
  -D__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__ -I"$PORT" "$EXP/test/pathnorm_vectors.cpp" "$PORT/path_normalizer.cpp" \
  "$SYSROOT/usr/lib/x86_64-linux-android/31/libicu.so"

# 7. the ORIGINAL (C++ API) file against the NDK: expected to fail
cc "ORIGINAL path_normalizer.cpp (expected failure)" x86_64-linux-android34 orig-x86_64-34.o \
  -c -I"$ORIG_SRC/src/core" "$ORIG_SRC/src/core/path_normalizer.cpp"
echo "-- and with U_SHOW_CPLUSPLUS_API forced on (still no unistr.h/normalizer2.h in the sysroot):"
ls "$SYSROOT/usr/include/unicode/" | grep -c -e unistr.h -e normalizer2.h

# 8. patched platform_variant.cpp: which variant each target reports
echo
echo "== platform_variant.cpp patch: compile-time hostVariant() per target"
cat > "$B/hv.cpp" <<'EOF'
#include "platform_variant.h"
#include <cstdio>
int main() { std::printf("%s\n", lgx::hostVariant().c_str()); }
EOF
for t in x86_64-linux-android34 aarch64-linux-android34 armv7a-linux-androideabi34 i686-linux-android34; do
  for src in "$ORIG_SRC/src/core" "$EXP/src/logos-package-4cdb302/src/core"; do
    tag=$([ "$src" = "$ORIG_SRC/src/core" ] && echo orig || echo patched)
    # Emit the literal returned by hostVariant() without running target code.
    "$TC/clang++" --target=$t -std=c++17 -O0 -S -I"$src" "$src/platform_variant.cpp" -o "$B/pv-$t-$tag.s" 2>&1 | head -5
    lit=$(grep -o -e '"[a-z]*-[a-z0-9_]*"' -e '"unknown"' "$B/pv-$t-$tag.s" | tr '\n' ' ')
    echo "  $t [$tag]: string literals in hostVariant/variantSpellings object: $lit"
  done
done
