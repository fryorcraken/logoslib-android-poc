#!/usr/bin/env bash
# ndk-runtime step 1: cross-build Boost 1.87.0 for x86_64-linux-android API 34
# with NDK r27c clang + libc++ (b2 toolset=clang-android via user-config.jam).
set -u
W=${REPO_ROOT}/.work/experiments/ndk-runtime
NDK=${HOME}/android-ndk/android-ndk-r27c
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64
API=34
PREFIX=$W/prefix/x86_64
SRC=$W/src/boost_1_87_0
BUILD=$W/build/boost-x86_64
LOG=$W/logs/boost.log
if [ "${1:-}" = clean ]; then
  # clean-build timing run: drop b2's object tree, keep source/download/bootstrap
  LOG=$W/logs/boost-clean.log
  rm -rf "$BUILD/obj"
fi
mkdir -p "$W/logs" "$W/src" "$W/dl" "$BUILD" "$PREFIX"
exec 3>&1 > >(tee "$LOG" | grep -E '^(B2 EXIT|B2 INVOCATION)' >&3) 2>&1
set -x
date -Is

TARBALL=$W/dl/boost_1_87_0.tar.bz2
if [ ! -s "$TARBALL" ]; then
  curl -fL --retry 3 -o "$TARBALL" https://archives.boost.io/release/1.87.0/source/boost_1_87_0.tar.bz2 \
    || curl -fL --retry 3 -o "$TARBALL" https://github.com/boostorg/boost/releases/download/boost-1.87.0/boost-1.87.0-b2-nodocs.tar.xz
fi
sha256sum "$TARBALL"
if [ ! -d "$SRC" ]; then
  tar -xjf "$TARBALL" -C "$W/src"
fi

export TMPDIR=$W/tmp
mkdir -p "$TMPDIR"

# PATCH (Android): bionic has no <wordexp.h>, which Boost.Process v2's
# libs/process/src/shell.cpp includes on every non-Windows, non-OpenBSD target.
# Minimal fix: route __ANDROID__ through the existing OpenBSD branch
# (bp2::shell parsing throws ENOTSUP; logos never uses bp2::shell).
SHELL_CPP=$SRC/libs/process/src/shell.cpp
[ -f "$SHELL_CPP.orig" ] || cp "$SHELL_CPP" "$SHELL_CPP.orig"
cp "$SHELL_CPP.orig" "$SHELL_CPP"
sed -i 's/^#elif !defined(__OpenBSD__)$/#elif !defined(__OpenBSD__) \&\& !defined(__ANDROID__)/' "$SHELL_CPP"
( cd "$W/src" && diff -u boost_1_87_0/libs/process/src/shell.cpp.orig boost_1_87_0/libs/process/src/shell.cpp ) > "$W/patches/boost-1.87.0-process-shell-android.diff"
cat "$W/patches/boost-1.87.0-process-shell-android.diff"

cd "$SRC" || exit 1
if [ ! -x ./b2 ]; then
  ./bootstrap.sh --with-toolset=gcc || { cat bootstrap.log; exit 1; }
fi

cat > "$BUILD/user-config.jam" <<EOF
using clang : android
  : $TC/bin/x86_64-linux-android$API-clang++
  : <archiver>$TC/bin/llvm-ar
    <ranlib>$TC/bin/llvm-ranlib
    <compileflags>-fPIC
    <compileflags>-ffunction-sections
    <compileflags>-fdata-sections
    <linkflags>-Wl,-z,max-page-size=16384
    <linkflags>-Wl,--build-id=sha1
  ;
EOF
cat "$BUILD/user-config.jam"

B2ARGS=(
  --user-config="$BUILD/user-config.jam"
  --build-dir="$BUILD/obj"
  --prefix="$PREFIX"
  --layout=system
  toolset=clang-android
  target-os=android
  architecture=x86 address-model=64 abi=sysv binary-format=elf
  link=static,shared runtime-link=shared threading=multi variant=release
  cxxstd=17
  --with-process --with-filesystem --with-system --with-context --with-atomic --with-date_time
  -j16 -d+2
  install
)
echo "B2 INVOCATION: ./b2 ${B2ARGS[*]}"
T0=$(date +%s)
./b2 "${B2ARGS[@]}"
RC=$?
T1=$(date +%s)
echo "B2 EXIT=$RC WALL_SECONDS=$((T1-T0))"

set +x
echo "== installed libs"
ls -la "$PREFIX/lib" | grep -i boost
echo "== cmake configs"
ls "$PREFIX/lib/cmake" 2>/dev/null
echo "== ELF check (shared)"
for f in "$PREFIX"/lib/libboost_*.so*; do
  [ -L "$f" ] && continue
  echo "--- $f"
  "$TC/bin/llvm-readelf" -h -d -l "$f" | grep -E 'Machine|SONAME|NEEDED|LOAD ' | head -20
done
echo "== sizes"
du -b "$PREFIX"/lib/libboost_* | sort -k2
date -Is
exit $RC
