#!/usr/bin/env bash
# ndk-runtime: build the smoke executable + Qt-free host probe against the
# x86_64/API34 prefix, then run API-level checks for a lower minSdk (28 = the
# Qt 6.11 prebuilt minimum).
set -u
W=${REPO_ROOT}/.work/experiments/ndk-runtime
NDK=${HOME}/android-ndk/android-ndk-r27c
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64
SYSROOT=$TC/sysroot
PREFIX=$W/prefix/x86_64
NINJA=/nix/store/7bgiqc706pzzb1gmwgpzdfg491w4a8nx-ninja-1.13.1/bin/ninja
LOG=$W/logs/smoke-build.log
export TMPDIR=$W/tmp
mkdir -p "$W/logs" "$W/build" "$TMPDIR" "$W/out/x86_64"
exec 3>&1 >"$LOG" 2>&1
trap 'grep -E "^(RESULT|API28)" "$LOG" >&3' EXIT
date -Is

B=$W/build/smoke-x86_64
rm -rf "$B"
cmake -S "$W/src/smoke" -B "$B" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=x86_64 -DANDROID_PLATFORM=android-34 -DANDROID_STL=c++_shared \
  -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON \
  -DCMAKE_EXE_LINKER_FLAGS=-Wl,-z,max-page-size=16384 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_FIND_ROOT_PATH="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH -DBoost_USE_STATIC_LIBS=ON \
  -DLOADER_QT_SRC="$W/src/logos-module-loader-qt" \
  -DCONTAINER_SUBPROCESS_SRC="$W/src/logos-container-subprocess" \
  && cmake --build "$B" -j16 -v -- -k 0
echo "RESULT smoke build exit=$?"

rm -f "$W/out/x86_64"/*
cp -f "$B/ndk_smoke" "$B/ndk_smoke_fdenum" "$B/liblogos_host_probe.so" "$B/libndkrt_activity.so" "$W/out/x86_64/" 2>/dev/null
# same probe under the name patch B gives logos_host_qt, for patch C's discovery
cp -f "$B/liblogos_host_probe.so" "$W/out/x86_64/liblogos_host_qt.so"
cp -f "$PREFIX/lib/libspdlog.so" "$PREFIX/lib/libfmt.so" "$SYSROOT/usr/lib/x86_64-linux-android/libc++_shared.so" "$W/out/x86_64/"
for f in "$W/out/x86_64"/*; do
  echo "--- $f"
  "$TC/bin/llvm-readelf" -h -d -l "$f" | grep -E 'Type:|NEEDED|RUNPATH|RPATH|LOAD '
done
ls -la "$W/out/x86_64"
cp -f "$W/out/x86_64/ndk_smoke" "$W/out/x86_64/ndk_smoke.stripped"
"$TC/bin/llvm-strip" --strip-unneeded "$W/out/x86_64/ndk_smoke.stripped"
cp -f "$W/out/x86_64/liblogos_host_probe.so" "$W/out/x86_64/liblogos_host_probe.stripped"
"$TC/bin/llvm-strip" --strip-unneeded "$W/out/x86_64/liblogos_host_probe.stripped"
echo "RESULT sizes (bytes): $(stat -c '%n=%s' "$W/out/x86_64"/* | sed "s#$W/out/x86_64/##g" | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# API-28 checks
# ---------------------------------------------------------------------------
CXX28="$TC/bin/clang++ --target=x86_64-linux-android28 --sysroot=$SYSROOT -std=c++17 -fsyntax-only -isystem $PREFIX/include"
echo "== API28: upstream crash handler shape (unguarded ::backtrace)"
cat > "$TMPDIR/bt.cpp" <<'EOF'
#include <execinfo.h>
int f() { void* fr[64]; return ::backtrace(fr, 64); }
EOF
if $CXX28 "$TMPDIR/bt.cpp"; then echo "API28 backtrace: compiles"; else echo "API28 backtrace: COMPILE ERROR (see above)"; fi
echo "== API28: subprocess_container.cpp"
if $CXX28 -I"$W/src/logos-container-subprocess/src" -DSPDLOG_COMPILED_LIB -DSPDLOG_FMT_EXTERNAL -DSPDLOG_SHARED_LIB -DFMT_SHARED \
    "$W/src/logos-container-subprocess/src/subprocess_container.cpp"; then echo "API28 subprocess_container.cpp: compiles"; else echo "API28 subprocess_container.cpp: COMPILE ERROR"; fi
echo "== API28: qt_plugin_format_loader.cpp"
if $CXX28 -I"$W/src/logos-module-loader-qt/src" -DSPDLOG_COMPILED_LIB -DSPDLOG_FMT_EXTERNAL -DSPDLOG_SHARED_LIB -DFMT_SHARED \
    "$W/src/logos-module-loader-qt/src/qt_plugin_format_loader.cpp"; then echo "API28 qt_plugin_format_loader.cpp: compiles"; else echo "API28 qt_plugin_format_loader.cpp: COMPILE ERROR"; fi
for t in token_source command_line_parser module_path module_dll_search; do
  if $CXX28 -I"$W/src/logos-module-loader-qt/src/host" -DSPDLOG_COMPILED_LIB -DSPDLOG_FMT_EXTERNAL -DSPDLOG_SHARED_LIB -DFMT_SHARED \
      "$W/src/logos-module-loader-qt/src/host/$t.cpp"; then echo "API28 host/$t.cpp: compiles"; else echo "API28 host/$t.cpp: COMPILE ERROR"; fi
done

echo "== API28: libc symbols the API-34 prefix references that API-28 libc lacks"
# Undefined symbols of everything that would end up in the app, vs the
# dynamic symbols the API-28 NDK stubs export.
LIBDIR28=$SYSROOT/usr/lib/x86_64-linux-android/28
{ for s in libc.so libm.so libdl.so liblog.so; do "$TC/bin/llvm-nm" -D --defined-only "$LIBDIR28/$s"; done
  "$TC/bin/llvm-nm" -D --defined-only "$SYSROOT/usr/lib/x86_64-linux-android/libc++_shared.so"
  for f in "$PREFIX"/lib/libfmt.so "$PREFIX"/lib/libspdlog.so; do "$TC/bin/llvm-nm" -D --defined-only "$f"; done
} | awk '{print $NF}' | sed 's/@.*//' | sort -u > "$TMPDIR/def28.txt"
for f in "$PREFIX"/lib/libboost_*.a "$PREFIX"/lib/liblogos_*.a "$PREFIX"/lib/libprocess_stats.a "$PREFIX"/lib/libspdlog.so "$PREFIX"/lib/libfmt.so "$W/out/x86_64/liblogos_host_probe.so" "$W/out/x86_64/ndk_smoke"; do
  "$TC/bin/llvm-nm" -u "$f" 2>/dev/null | awk '{print $NF}' | sed 's/@.*//' | sort -u > "$TMPDIR/undef.txt"
  # also defined inside the same archive
  "$TC/bin/llvm-nm" --defined-only "$f" 2>/dev/null | awk '{print $NF}' | sort -u > "$TMPDIR/self.txt"
  miss=$(comm -23 "$TMPDIR/undef.txt" "$TMPDIR/def28.txt" | comm -23 - "$TMPDIR/self.txt" | grep -v -E '^(_ZN|_ZT|_ZS|_ZNK|_ZdlPv|_Znwm|_ZdaPv|_Znam|__cxa_|_Unwind_|__gxx_personality|_ZSt|_ZNSt|_ZNKSt|__dso_handle|_GLOBAL_OFFSET_TABLE_|__stack_chk_guard)' | tr '\n' ' ')
  echo "API28 $(basename "$f"): missing-at-28 libc-level symbols: ${miss:-none}"
done
date -Is
