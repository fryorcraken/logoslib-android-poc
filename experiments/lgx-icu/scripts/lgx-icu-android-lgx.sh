#!/usr/bin/env bash
# lgx-icu: cross-build the PATCHED liblgx (logos-package 4cdb302 + ICU C-API
# port + Android CMake branch + __ANDROID__ variant) with NDK r27c for
# x86_64 and arm64, API 34. Deps: NDK zlib, NDK libicu.so, libsodium 1.0.20
# cross-built here (static, PIC), nlohmann_json + cpp-semver via FetchContent.
# Also shows that configure at API 28 stops with the CMake message.
# No device or emulator is touched.
set -u
EXP=${REPO_ROOT}/.work/experiments/lgx-icu
mkdir -p "$EXP/logs" "$EXP/deps" "$EXP/build"
LOG="$EXP/logs/android-lgx.log"
exec > >(tee "$LOG") 2>&1

NDK=${HOME}/android-ndk/android-ndk-r27c
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
SRC=$EXP/src/logos-package-4cdb302
API=34
SODIUM_VER=1.0.20
TARBALL=$EXP/deps/libsodium-$SODIUM_VER.tar.gz

echo "== libsodium $SODIUM_VER source"
if [ ! -s "$TARBALL" ]; then
  curl -fsSL -o "$TARBALL" "https://download.libsodium.org/libsodium/releases/libsodium-$SODIUM_VER.tar.gz" \
    || curl -fsSL -o "$TARBALL" "https://github.com/jedisct1/libsodium/releases/download/$SODIUM_VER-RELEASE/libsodium-$SODIUM_VER.tar.gz"
fi
sha256sum "$TARBALL"

for ABI in x86_64 arm64-v8a; do
  case $ABI in
    x86_64)    TRIPLE=x86_64-linux-android;  EXTRA_LD="" ;;
    arm64-v8a) TRIPLE=aarch64-linux-android; EXTRA_LD="-Wl,-z,max-page-size=16384" ;;
  esac
  PREFIX=$EXP/deps/sodium-$ABI
  echo
  echo "################ $ABI ($TRIPLE$API)"
  if [ ! -f "$PREFIX/lib/libsodium.a" ]; then
    echo "== build libsodium (static, PIC)"
    rm -rf "$EXP/deps/sodium-src-$ABI"; mkdir -p "$EXP/deps/sodium-src-$ABI"
    tar -xzf "$TARBALL" -C "$EXP/deps/sodium-src-$ABI" --strip-components=1
    start=$(date +%s)
    (
      cd "$EXP/deps/sodium-src-$ABI" &&
      ./configure --host="$TRIPLE" --prefix="$PREFIX" --disable-shared --enable-static --with-pic \
        CC="$TC/$TRIPLE$API-clang" AR="$TC/llvm-ar" RANLIB="$TC/llvm-ranlib" STRIP="$TC/llvm-strip" \
        CFLAGS="-O2" > "$EXP/logs/sodium-$ABI.configure.log" 2>&1 &&
      make -j16 > "$EXP/logs/sodium-$ABI.make.log" 2>&1 &&
      make install > "$EXP/logs/sodium-$ABI.install.log" 2>&1
    )
    echo "libsodium exit=$? after $(( $(date +%s) - start ))s"
  fi
  ls -la "$PREFIX/lib/libsodium.a"

  B=$EXP/build/lgx-$ABI-$API
  rm -rf "$B"
  echo "== configure liblgx"
  start=$(date +%s)
  cmake -S "$SRC" -B "$B" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=$ABI -DANDROID_PLATFORM=android-$API -DANDROID_STL=c++_shared \
    -DCMAKE_BUILD_TYPE=Release -DLGX_BUILD_SHARED=ON -DLGX_BUILD_TESTS=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS="$EXTRA_LD" -DCMAKE_EXE_LINKER_FLAGS="$EXTRA_LD" \
    -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON \
    -DSODIUM_LIBRARIES="$PREFIX/lib/libsodium.a" -DSODIUM_INCLUDE_DIRS="$PREFIX/include" \
    > "$EXP/logs/lgx-$ABI.configure.log" 2>&1
  echo "configure exit=$?"
  grep -e 'ZLIB' -e 'ICU' -e 'nlohmann' -e 'semver' -e 'Error' -e 'error' "$EXP/logs/lgx-$ABI.configure.log" | head -20
  grep -e '^LGX_ANDROID_ICU_LIBRARY' -e '^ZLIB_LIBRARY' -e '^ZLIB_INCLUDE_DIR' "$B/CMakeCache.txt"

  echo "== build liblgx (lgx_core, lgx_shared, lgx CLI)"
  cmake --build "$B" -j16 > "$EXP/logs/lgx-$ABI.build.log" 2>&1
  echo "build exit=$? after $(( $(date +%s) - start ))s (configure+build)"
  grep -e 'error' -e 'warning: .*unavailable' "$EXP/logs/lgx-$ABI.build.log" | head -20
  tail -3 "$EXP/logs/lgx-$ABI.build.log"

  for f in "$B/liblgx.so" "$B/lgx"; do
    [ -f "$f" ] || { echo "MISSING $f"; continue; }
    echo "-- $(basename "$f"): $(file -b "$f" | cut -c1-110)"
    echo "   size $(stat -c %s "$f") B; stripped:"
    "$TC/llvm-strip" -o "$f.stripped" "$f" && stat -c '   %s B' "$f.stripped"
    echo "   NEEDED:"; "$TC/llvm-readelf" -d "$f" | grep NEEDED
    echo "   ICU / zlib / sodium imports:"
    "$TC/llvm-nm" -D --undefined-only "$f" | grep -e ' u_' -e ' unorm2_' -e 'icu' -e ' inflate' -e ' deflate' -e ' crc32' -e 'sodium' -e 'crypto_' | sed 's/^ */     /' | tr '\n' ' '; echo
    echo "   LOAD align: $("$TC/llvm-readelf" -lW "$f" | grep LOAD | awk '{print $NF}' | sort -u | tr '\n' ' ')"
  done
  echo "-- lgx_host_variant() in liblgx.so .rodata:"
  "$TC/llvm-strings" -a "$B/liblgx.so" | grep -x -e 'android-x86_64' -e 'android-arm64' -e 'linux-x86_64' -e 'linux-arm64'
  echo "-- exported lgx_* C API symbols: $("$TC/llvm-nm" -D --defined-only "$B/liblgx.so" | grep -c ' T lgx_')"
done

echo
echo "################ negative check: ANDROID_PLATFORM=android-28"
B=$EXP/build/lgx-x86_64-28
rm -rf "$B"
cmake -S "$SRC" -B "$B" -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=x86_64 -DANDROID_PLATFORM=android-28 -DANDROID_STL=c++_shared \
  -DCMAKE_BUILD_TYPE=Release -DLGX_BUILD_SHARED=ON -DLGX_BUILD_TESTS=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON \
  -DSODIUM_LIBRARIES="$EXP/deps/sodium-x86_64/lib/libsodium.a" -DSODIUM_INCLUDE_DIRS="$EXP/deps/sodium-x86_64/include" \
  > "$EXP/logs/lgx-x86_64-28.configure.log" 2>&1
echo "configure exit=$? (expected non-zero)"
grep -A4 -e 'CMake Error' "$EXP/logs/lgx-x86_64-28.configure.log" | head -12
