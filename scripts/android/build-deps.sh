#!/usr/bin/env bash
# scripts/android/build-deps.sh -- M2: cross-build the third-party native prefix the Logos
# runtime links against, for one Android ABI.
#
# Output: build/android/<abi>/prefix (include/, lib/, lib/cmake/, share/, bin/), plus
#   build/android/<abi>/prefix/share/logos-android/deps-manifest.txt  (what was built from what)
#   build/android/<abi>/timings.tsv                                   (wall time per step)
#   build/logs/build-deps-<abi>.log                                   (full log)
# and it finishes by running scripts/android/check-prefix.sh on the prefix.
#
# Built (versions and revisions pinned in scripts/android/versions.env):
#   boost    Boost 1.87.0: process filesystem system context atomic date_time, static +
#            shared, b2 toolset=clang-android. patches/boost/*.diff (bionic has no wordexp.h).
#   fmt      fmt 10.2.1, shared
#   spdlog   spdlog 1.15.2, shared, against the external fmt (SPDLOG_FMT_EXTERNAL, as nixpkgs)
#   json     nlohmann_json 3.11.3, headers + CMake package
#   cli11    CLI11 2.5.0, headers + CMake package (logos-module-loader-qt's logos_host_qt)
#   semver   cpp-semver 0.4.0, headers + CMake package (liblgx; vendored so no FetchContent)
#   openssl  OpenSSL 3.5.x, shared only, SONAMEs libcrypto_3.so / libssl_3.so: the names
#            QtNetwork's TLS backend dlopen()s on Android, so ONE copy serves Qt and the Logos
#            libraries (libcrypto.so / libssl.so symlinks are for CMake's FindOpenSSL only).
#   sodium   libsodium 1.0.20, static PIC (only liblgx uses it)
#   lgx      liblgx = logos-package @ LOGOS_PACKAGE_REV + patches/logos-package/0001,0002
#            (platform ICU C API, NDK libicu.so, API >= 31) [+0003 if LGX_ANDROID_VARIANT_PATCH=1];
#            liblgx.so, liblgx_core.a, lgx.h, logos/semver.hpp, and the lgx CLI in bin/.
#   lpm      package_manager_lib = logos-package-manager @ LOGOS_PACKAGE_MANAGER_REV, shared
#            (liblogos imports it as a SHARED library next to liblgx); lgpm CLI in bin/.
# Not built: zlib (NDK sysroot libz.so) and ICU (platform libicu.so, API 31+).
#
# Every shared object is linked with -Wl,-z,max-page-size=16384 (16 KB LOAD alignment), has
# an unversioned lib*.so SONAME, and NEEDs only NDK system libraries, libc++_shared.so or
# other libraries of the prefix -- check-prefix.sh enforces it.
#
# Usage:
#   bash scripts/android/build-deps.sh [x86_64|arm64-v8a] [STEP...]
#     STEP: boost fmt spdlog json cli11 semver openssl sodium lgx lpm (default: all, in order)
#   Environment: see scripts/android/env.sh (ABI, ANDROID_API, ANDROID_NDK_HOME, JOBS,
#   FORCE=1 to rebuild steps that are up to date, LOGOS_SRC_MIRROR for local git mirrors).
#
# Re-runnable: each step records a stamp keyed on its versions, patch hashes and options,
# and is skipped while the stamp matches and its main output exists. Sources are shared by
# both ABIs (build/src); do not build two ABIs at the same time.
#
# Needs: cmake >= 3.16, make, perl (OpenSSL Configure), python3, curl, git, tar/bzip2/xz,
# a host C/C++ compiler (b2 bootstrap), NDK r27c. Network: GitHub, archives.boost.io,
# download.libsodium.org (first run only; later runs use build/dl and build/src).
set -euo pipefail

ALL_STEPS=(boost fmt spdlog json cli11 semver openssl sodium lgx lpm)
STEPS=()
for a in "$@"; do
  case "$a" in
    x86_64|arm64-v8a) ABI=$a ;;
    all) STEPS=("${ALL_STEPS[@]}") ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 0 ;;
    *) printf '%s\n' "${ALL_STEPS[@]}" | grep -qx -- "$a" || { echo "unknown step or ABI: $a" >&2; exit 2; }
       STEPS+=("$a") ;;
  esac
done
[ ${#STEPS[@]} -gt 0 ] || STEPS=("${ALL_STEPS[@]}")
export ABI="${ABI:-x86_64}"

# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
log_setup build-deps
trap 'on_error build-deps' ERR
check_host_tools
say "prefix: $PREFIX"
say "steps: ${STEPS[*]}   jobs: $JOBS   force: $FORCE"
echo "ndk: $ANDROID_NDK_HOME ($("$CXX" --version | head -1))"
echo "cmake: $(cmake --version | head -1)"

# ------------------------------------------------------------------------------------
step_boost() {
  local patches=("$PATCHES_DIR"/boost/*.diff)
  local key="boost $BOOST_VERSION $(patch_key "${patches[@]}") libs=[$BOOST_LIBS] link=static,shared"
  step_should_skip boost "$key" "$PREFIX/lib/libboost_process.so" && return 0
  step_begin boost
  fetch_url "$BOOST_URL" "$BOOST_TARBALL" "$BOOST_SHA256"
  local src="$SRC_ROOT/boost_${BOOST_VERSION//./_}"
  prepare_tarball_src "$(basename "$src")" "$BOOST_TARBALL" "${patches[@]}"
  # b2 itself runs on the host: bootstrap it once per source tree with the host gcc.
  if [ ! -x "$src/b2" ]; then
    ( cd "$src" && ./bootstrap.sh --with-toolset=gcc ) || { cat "$src/bootstrap.log" || true; die "b2 bootstrap failed"; }
  fi
  local b="$OBJ_DIR/boost"
  rm -rf "$b"; mkdir -p "$b"
  local ldflag lf=""
  for ldflag in $LDFLAGS_ANDROID; do lf+="    <linkflags>$ldflag"$'\n'; done
  cat > "$b/user-config.jam" <<EOF
using clang : android
  : $CXX
  : <archiver>$AR
    <ranlib>$RANLIB
    <compileflags>-fPIC
    <compileflags>-ffunction-sections
    <compileflags>-fdata-sections
$lf  ;
EOF
  cat "$b/user-config.jam"
  local withs=() l
  for l in $BOOST_LIBS; do withs+=("--with-$l"); done
  local args=(
    --user-config="$b/user-config.jam"
    --build-dir="$b/obj"
    --prefix="$PREFIX"
    --layout=system
    toolset=clang-android target-os=android "${B2_ARCH_ARGS[@]}"
    link=static,shared runtime-link=shared threading=multi variant=release
    cxxstd=17
    "${withs[@]}"
    -j"$JOBS" -d+1
    install
  )
  echo "-- b2 ${args[*]}"
  ( cd "$src" && ./b2 "${args[@]}" )
  step_done boost "$key"
}

step_fmt() {
  local key="fmt $FMT_VERSION shared"
  step_should_skip fmt "$key" "$PREFIX/lib/libfmt.so" && return 0
  step_begin fmt
  fetch_url "$FMT_URL" "fmt-$FMT_VERSION.tar.gz" "$FMT_SHA256"
  prepare_tarball_src "fmt-$FMT_VERSION" "fmt-$FMT_VERSION.tar.gz"
  ndk_cmake_build fmt "$SRC_ROOT/fmt-$FMT_VERSION" \
    -DBUILD_SHARED_LIBS=ON -DFMT_TEST=OFF -DFMT_DOC=OFF -DFMT_INSTALL=ON
  step_done fmt "$key"
}

step_spdlog() {
  local key="spdlog $SPDLOG_VERSION shared fmt-external $FMT_VERSION"
  step_should_skip spdlog "$key" "$PREFIX/lib/libspdlog.so" && return 0
  step_begin spdlog
  fetch_url "$SPDLOG_URL" "spdlog-$SPDLOG_VERSION.tar.gz" "$SPDLOG_SHA256"
  prepare_tarball_src "spdlog-$SPDLOG_VERSION" "spdlog-$SPDLOG_VERSION.tar.gz"
  ndk_cmake_build spdlog "$SRC_ROOT/spdlog-$SPDLOG_VERSION" \
    -DSPDLOG_BUILD_SHARED=ON -DSPDLOG_FMT_EXTERNAL=ON -DSPDLOG_INSTALL=ON \
    -DSPDLOG_BUILD_EXAMPLE=OFF -DSPDLOG_BUILD_TESTS=OFF -DSPDLOG_BUILD_BENCH=OFF
  step_done spdlog "$key"
}

step_json() {
  local key="nlohmann_json $NLOHMANN_JSON_VERSION"
  step_should_skip json "$key" "$PREFIX/include/nlohmann/json.hpp" && return 0
  step_begin json
  fetch_url "$NLOHMANN_JSON_URL" "json-$NLOHMANN_JSON_VERSION.tar.gz" "$NLOHMANN_JSON_SHA256"
  prepare_tarball_src "json-$NLOHMANN_JSON_VERSION" "json-$NLOHMANN_JSON_VERSION.tar.gz"
  ndk_cmake_build json "$SRC_ROOT/json-$NLOHMANN_JSON_VERSION" -DJSON_BuildTests=OFF -DJSON_Install=ON
  step_done json "$key"
}

step_cli11() {
  local key="CLI11 $CLI11_VERSION"
  step_should_skip cli11 "$key" "$PREFIX/include/CLI/CLI.hpp" && return 0
  step_begin cli11
  fetch_url "$CLI11_URL" "CLI11-$CLI11_VERSION.tar.gz" "$CLI11_SHA256"
  prepare_tarball_src "CLI11-$CLI11_VERSION" "CLI11-$CLI11_VERSION.tar.gz"
  ndk_cmake_build cli11 "$SRC_ROOT/CLI11-$CLI11_VERSION" \
    -DCLI11_BUILD_TESTS=OFF -DCLI11_BUILD_EXAMPLES=OFF -DCLI11_BUILD_DOCS=OFF \
    -DCLI11_PRECOMPILED=OFF -DCLI11_INSTALL=ON
  step_done cli11 "$key"
}

step_semver() {
  local key="cpp-semver $CPP_SEMVER_VERSION"
  step_should_skip semver "$key" "$PREFIX/include/semver/semver.hpp" && return 0
  step_begin semver
  fetch_url "$CPP_SEMVER_URL" "cpp-semver-$CPP_SEMVER_VERSION.tar.gz" "$CPP_SEMVER_SHA256"
  prepare_tarball_src "cpp-semver-$CPP_SEMVER_VERSION" "cpp-semver-$CPP_SEMVER_VERSION.tar.gz"
  ndk_cmake_build semver "$SRC_ROOT/cpp-semver-$CPP_SEMVER_VERSION" -DSEMVER_BUILD_TESTS=OFF -DSEMVER_INSTALL=ON
  step_done semver "$key"
}

step_openssl() {
  local sfx="$OPENSSL_SONAME_SUFFIX"
  local key="openssl $OPENSSL_VERSION target=$OPENSSL_TARGET shlib_variant=$sfx"
  step_should_skip openssl "$key" "$PREFIX/lib/libssl$sfx.so" && return 0
  step_begin openssl
  local tb="openssl-$OPENSSL_VERSION.tar.gz"
  fetch_url "$OPENSSL_URL" "$tb" "$OPENSSL_SHA256"
  if [ -z "$OPENSSL_SHA256" ] && [ -n "${OPENSSL_SHA256_URL:-}" ]; then
    # Not pinned yet: at least cross-check against the release's published checksum.
    local pub; pub=$(curl -fsSL --retry 3 "$OPENSSL_SHA256_URL" | grep -oE '[0-9a-f]{64}' | head -1)
    [ "$pub" = "$(sha256_of "$DL_DIR/$tb")" ] || die "OpenSSL tarball does not match $OPENSSL_SHA256_URL ($pub)"
    echo "-- $tb matches the published $OPENSSL_SHA256_URL"
  fi
  local src="$SRC_ROOT/openssl-$OPENSSL_VERSION"
  prepare_tarball_src "openssl-$OPENSSL_VERSION" "$tb"
  local b="$OBJ_DIR/openssl"
  rm -rf "$b"; mkdir -p "$b"
  # Out-of-tree build. Configure's android targets take clang from PATH and the NDK from
  # ANDROID_NDK_ROOT, and the API level from -D__ANDROID_API__.
  # OpenSSL 3's android-* targets already name the libraries libcrypto.so / libssl.so
  # (shared_extension ".so", no version). OpenSSL's own `shlib_variant` target attribute
  # inserts "_3" into the file name AND the SONAME: libcrypto_3.so / libssl_3.so, with
  # libssl_3.so NEEDing libcrypto_3.so, plus libcrypto.so / libssl.so link-time symlinks.
  # (Symbol versions become OPENSSL__3_3.0.0 etc.; Qt resolves by plain dlsym, and every
  # Logos library links this same copy.) The target is a one-entry config file that
  # inherits the stock android-<arch> target. Only the libraries are built.
  local target="logos-$OPENSSL_TARGET"
  cat > "$b/logos-android.conf" <<EOF
# Generated by scripts/android/build-deps.sh: stock $OPENSSL_TARGET + SONAME variant.
my %targets = (
    "$target" => {
        inherit_from  => [ "$OPENSSL_TARGET" ],
        shlib_variant => "$sfx",
    },
);
EOF
  (
    cd "$b"
    export PATH="$TC/bin:$PATH"
    # shellcheck disable=SC2086
    perl "$src/Configure" --config="$b/logos-android.conf" "$target" shared no-tests \
      -U__ANDROID_API__ -D__ANDROID_API__="$ANDROID_API" \
      $LDFLAGS_ANDROID \
      --prefix="$PREFIX" --libdir=lib
    make -j"$JOBS" build_libs
  )
  local lib
  for lib in crypto ssl; do
    [ -f "$b/lib$lib$sfx.so" ] || die "OpenSSL did not produce lib$lib$sfx.so"
    local soname; soname=$("$READELF" -d "$b/lib$lib$sfx.so" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
    [ "$soname" = "lib$lib$sfx.so" ] || die "lib$lib$sfx.so has SONAME '$soname'"
  done
  "$READELF" -d "$b/libssl$sfx.so" | grep -q "NEEDED.*\[libcrypto$sfx.so\]" \
    || die "libssl$sfx.so does not NEED libcrypto$sfx.so: $("$READELF" -d "$b/libssl$sfx.so" | grep NEEDED)"
  # Install by hand: libraries + public headers only (install_dev would also install the
  # static archives, which could give a consumer a second OpenSSL copy).
  rm -rf "$PREFIX/include/openssl"
  mkdir -p "$PREFIX/include/openssl" "$PREFIX/lib"
  cp "$src"/include/openssl/*.h "$PREFIX/include/openssl/"
  cp "$b"/include/openssl/*.h "$PREFIX/include/openssl/"       # generated: opensslv.h, configuration.h, ...
  rm -f "$PREFIX"/lib/libcrypto* "$PREFIX"/lib/libssl*
  cp "$b/libcrypto$sfx.so" "$b/libssl$sfx.so" "$PREFIX/lib/"
  ln -s "libcrypto$sfx.so" "$PREFIX/lib/libcrypto.so"
  ln -s "libssl$sfx.so" "$PREFIX/lib/libssl.so"
  step_done openssl "$key"
}

step_sodium() {
  local key="libsodium $LIBSODIUM_VERSION static pic"
  step_should_skip sodium "$key" "$PREFIX/lib/libsodium.a" && return 0
  step_begin sodium
  local tb="libsodium-$LIBSODIUM_VERSION.tar.gz"
  fetch_url "$LIBSODIUM_URL" "$tb" "$LIBSODIUM_SHA256" "$LIBSODIUM_URL_ALT"
  prepare_tarball_src "libsodium-$LIBSODIUM_VERSION" "$tb"
  local b="$OBJ_DIR/libsodium"
  rm -rf "$b"; mkdir -p "$b"
  (
    cd "$b"
    "$SRC_ROOT/libsodium-$LIBSODIUM_VERSION/configure" --host="$TRIPLE" --prefix="$PREFIX" \
      --disable-shared --enable-static --with-pic \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" CFLAGS="-O2"
    make -j"$JOBS"
    make install
  )
  rm -f "$PREFIX"/lib/libsodium.la
  step_done sodium "$key"
}

step_lgx() {
  local patches=("$PATCHES_DIR"/logos-package/0001-*.patch "$PATCHES_DIR"/logos-package/0002-*.patch)
  [ "$LGX_ANDROID_VARIANT_PATCH" = 1 ] && patches+=("$PATCHES_DIR"/logos-package/0003-*.patch)
  local key="logos-package $LOGOS_PACKAGE_REV $(patch_key "${patches[@]}") sodium $LIBSODIUM_VERSION json $NLOHMANN_JSON_VERSION semver $CPP_SEMVER_VERSION"
  step_should_skip lgx "$key" "$PREFIX/lib/liblgx.so" && return 0
  step_begin lgx
  fetch_git logos-package "$LOGOS_PACKAGE_REV" logos-co "${patches[@]}"
  # zlib: NDK sysroot (FindZLIB). ICU: the NDK libicu.so stub (patch 0002). nlohmann_json and
  # cpp-semver: the prefix (FetchContent is disconnected). libsodium: the static prefix copy.
  ndk_cmake_build lgx "$SRC_ROOT/logos-package" \
    -DLGX_BUILD_SHARED=ON -DLGX_BUILD_TESTS=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON \
    -DSODIUM_LIBRARIES="$PREFIX/lib/libsodium.a" -DSODIUM_INCLUDE_DIRS="$PREFIX/include"
  step_done lgx "$key"
}

step_lpm() {
  local key="logos-package-manager $LOGOS_PACKAGE_MANAGER_REV portable=$LGPM_PORTABLE_BUILD lgx=$LOGOS_PACKAGE_REV"
  step_should_skip lpm "$key" "$PREFIX/lib/libpackage_manager_lib.so" && return 0
  step_begin lpm
  fetch_git logos-package-manager "$LOGOS_PACKAGE_MANAGER_REV" logos-co
  ndk_cmake_build lpm "$SRC_ROOT/logos-package-manager" \
    -DLGX_ROOT="$PREFIX" -DLGPM_BUILD_TESTS=OFF -DLGPM_PORTABLE_BUILD="$LGPM_PORTABLE_BUILD"
  step_done lpm "$key"
}

# ------------------------------------------------------------------------------------
T_ALL=$(date +%s)
for s in "${STEPS[@]}"; do "step_$s"; done

# Provenance manifest: what the prefix was built from.
MANIFEST_DIR="$PREFIX/share/logos-android"
mkdir -p "$MANIFEST_DIR"
{
  echo "# build/android/$ABI/prefix -- written by scripts/android/build-deps.sh $(date -Is)"
  echo "abi=$ABI api=$ANDROID_API ndk=$NDK_VERSION ($(sed -n 's/^Pkg.Revision = //p' "$ANDROID_NDK_HOME/source.properties"))"
  echo "ldflags=$LDFLAGS_ANDROID"
  echo "boost=$BOOST_VERSION libs=[$BOOST_LIBS] sha256=$BOOST_SHA256 patches=[$(patch_key "$PATCHES_DIR"/boost/*.diff)]"
  echo "fmt=$FMT_VERSION sha256=$FMT_SHA256"
  echo "spdlog=$SPDLOG_VERSION sha256=$SPDLOG_SHA256"
  echo "nlohmann_json=$NLOHMANN_JSON_VERSION sha256=$NLOHMANN_JSON_SHA256"
  echo "cli11=$CLI11_VERSION sha256=${CLI11_SHA256:-unpinned}"
  echo "cpp-semver=$CPP_SEMVER_VERSION sha256=${CPP_SEMVER_SHA256:-unpinned}"
  echo "openssl=$OPENSSL_VERSION sha256=${OPENSSL_SHA256:-unpinned} soname=libcrypto$OPENSSL_SONAME_SUFFIX.so,libssl$OPENSSL_SONAME_SUFFIX.so"
  echo "libsodium=$LIBSODIUM_VERSION sha256=$LIBSODIUM_SHA256 (static)"
  echo "logos-package=$LOGOS_PACKAGE_REV patches=[$(patch_key "$PATCHES_DIR"/logos-package/0001-*.patch "$PATCHES_DIR"/logos-package/0002-*.patch)] android-variant-patch=$LGX_ANDROID_VARIANT_PATCH"
  echo "logos-package-manager=$LOGOS_PACKAGE_MANAGER_REV portable=$LGPM_PORTABLE_BUILD"
  echo "zlib=NDK sysroot libz.so; icu=platform libicu.so (API 31+)"
} > "$MANIFEST_DIR/deps-manifest.txt"

SUMMARY="$ANDROID_BUILD/summary.txt"
{
  echo "################ summary ($ABI) $(date -Is)"
  echo "-- this run: $(( $(date +%s) - T_ALL ))s; per-step wall times (latest run of each):"
  if [ -f "$TIMINGS" ]; then
    awk -F'\t' '{t[$1]=$2; d[$1]=$3} END {for (k in t) printf "   %-8s %5ss  (%s)\n", k, t[k], d[k]}' "$TIMINGS" | sort
  fi
  echo "-- shared libraries (bytes: as built / llvm-strip --strip-unneeded):"
  for f in "$PREFIX"/lib/*.so; do
    [ -e "$f" ] || continue
    if [ -L "$f" ]; then printf '   %-28s -> %s (symlink for CMake, not packaged)\n' "$(basename "$f")" "$(readlink "$f")"; continue; fi
    "$STRIP" --strip-unneeded -o "$TMPDIR/strip.$$" "$f"
    printf '   %-28s %10s %10s\n' "$(basename "$f")" "$(stat -c %s "$f")" "$(stat -c %s "$TMPDIR/strip.$$")"
    rm -f "$TMPDIR/strip.$$"
  done
  echo "-- static archives (bytes):"
  for f in "$PREFIX"/lib/*.a; do [ -e "$f" ] && printf '   %-28s %10s\n' "$(basename "$f")" "$(stat -c %s "$f")"; done
  echo "-- executables in bin/: $(ls "$PREFIX/bin" 2>/dev/null | tr '\n' ' ')"
  echo "-- CMake packages: $(ls "$PREFIX/lib/cmake" "$PREFIX/share/cmake" 2>/dev/null | grep -v ':$' | tr '\n' ' ')"
  echo "-- prefix size: $(du -sh "$PREFIX" | cut -f1) (include/: $(du -sh "$PREFIX/include" | cut -f1))"
} > "$SUMMARY"
cat "$SUMMARY"; [ "$_LOG_TEE" = 1 ] || cat "$SUMMARY" >&3

bash "$SCRIPTS_DIR/check-prefix.sh" "$ABI" 2>&1 | tee -a "$LOG_FILE" >&3
say "build-deps: OK ($ABI) $(date -Is)"
