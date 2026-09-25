# shellcheck shell=bash
# scripts/android/env.sh -- common environment for every Android build script.
#
# Sourced, never executed, by the scripts in scripts/android/. It
#   - reads the pinned versions (scripts/android/versions.env),
#   - picks the target (ABI, API level) and derives the clang triple and Qt names,
#   - locates the NDK, the SDK, the JDK and the Qt 6.11.1 prebuilts,
#   - lays out the build tree under build/ (gitignored),
#   - defines the cross toolchain (CC, CXX, AR, ...) and the link flags every non-Qt
#     artefact gets (16 KB pages: -Wl,-z,max-page-size=16384),
#   - defines NDK_CMAKE_ARGS / QT_CMAKE_ARGS, the common CMake arguments for NDK builds
#     (plain, and Qt consumers through Qt's toolchain file) into the prefix,
#   - names the host-tool tree (build/host: code generators built for the build machine),
#   - and provides small helpers: logging, step timing, stamps (skip work whose outputs
#     exist unless FORCE=1), sha256-checked downloads, pinned git checkouts (optionally
#     from local mirrors), patch application, ndk_cmake_build / qt_cmake_build.
#
# Inputs (environment, all optional):
#   ABI               x86_64 (default) | arm64-v8a
#   ANDROID_API       target API level = the app's minSdk (default from versions.env: 34)
#   ANDROID_NDK_HOME  NDK r27c root         (default $HOME/android-ndk/android-ndk-r27c)
#   ANDROID_SDK_ROOT  Android SDK root      (default $HOME/android-sdk)
#   JAVA_HOME         a full JDK 17+        (default /usr/lib/jvm/java-21-openjdk)
#   QT_ROOT           Qt install root with android_x86_64/, android_arm64_v8a/, gcc_64/
#                     (default <repo>/.work/probe/qt/6.11.1, where aqtinstall put it)
#   BUILD_ROOT        build tree root       (default <repo>/build)
#   JOBS              parallel jobs         (default: nproc)
#   FORCE             1 = redo every step even when its stamp and outputs exist
#   LOGOS_SRC_MIRROR  colon-separated directories holding local git checkouts named
#                     <repo> (e.g. ~/src/logos-co). A pinned revision found in one of them
#                     is fetched from there instead of GitHub; the mirror is only read.
#   CMAKE_GENERATOR   honoured by CMake itself (default "Unix Makefiles"; "Ninja" works)
#
# Build tree (per ABI unless noted):
#   build/dl/                       downloaded tarballs (shared)
#   build/src/<name>                pristine+patched sources, git checkouts (shared)
#   build/android/<abi>/prefix      install prefix: include/ lib/ lib/cmake/ share/
#   build/android/<abi>/obj/<step>  out-of-tree build directories
#   build/android/<abi>/stamps/     one stamp per finished step
#   build/android/<abi>/timings.tsv wall time of each step run
#   build/android/<abi>/modules/    staged module directories (M3: build-runtime.sh)
#   build/host/{prefix,obj,stamps}  host tools (Logos code generators), shared by all ABIs
#   build/logs/                     full logs of every script run
#   build/tmp/                      TMPDIR for all tools (never /tmp)

# ---- repo + pins -------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts/android"
PATCHES_DIR="$REPO_ROOT/patches"
# shellcheck source=versions.env
source "$SCRIPTS_DIR/versions.env"

# ---- target ------------------------------------------------------------------------
ABI="${ABI:-x86_64}"
ANDROID_API="${ANDROID_API:-$ANDROID_API_DEFAULT}"
case "$ABI" in
  x86_64)
    TRIPLE=x86_64-linux-android
    QT_ABI_DIR=android_x86_64
    QT_LIB_SUFFIX=_x86_64
    ELF_MACHINE="Advanced Micro Devices X86-64"
    B2_ARCH_ARGS=(architecture=x86 address-model=64 abi=sysv binary-format=elf)
    OPENSSL_TARGET=android-x86_64
    ;;
  arm64-v8a)
    TRIPLE=aarch64-linux-android
    QT_ABI_DIR=android_arm64_v8a
    QT_LIB_SUFFIX=_arm64-v8a
    ELF_MACHINE="AArch64"
    B2_ARCH_ARGS=(architecture=arm address-model=64 abi=aapcs binary-format=elf)
    OPENSSL_TARGET=android-arm64
    ;;
  *)
    echo "env.sh: unsupported ABI '$ABI' (x86_64 | arm64-v8a)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

# Module-manifest variant keys. liblgx's lgx_host_variant() has no __ANDROID__ branch, so
# under bionic it answers linux-<arch> (patches/logos-package/0003 would make it
# android-<arch>); the package manager appends -dev unless built LGPM_PORTABLE_BUILD, and
# accepts either spelling of the architecture. LGX_VARIANT is the first name it tries.
case "$ABI" in
  x86_64)    LGX_ARCH_NAMES="x86_64 amd64" ;;
  arm64-v8a) LGX_ARCH_NAMES="arm64 aarch64" ;;
esac
LGX_OS=linux; [ "${LGX_ANDROID_VARIANT_PATCH:-0}" = 1 ] && LGX_OS=android
LGX_DEV_SUFFIX=-dev; [ "${LGPM_PORTABLE_BUILD:-OFF}" = ON ] && LGX_DEV_SUFFIX=""
LGX_VARIANT="$LGX_OS-${LGX_ARCH_NAMES%% *}$LGX_DEV_SUFFIX"

# ---- host SDKs ---------------------------------------------------------------------
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/android-ndk/android-ndk-$NDK_VERSION}"
ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"          # the name OpenSSL's Configure reads
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/android-sdk}"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk}"
QT_ROOT="${QT_ROOT:-$REPO_ROOT/.work/probe/qt/$QT_VERSION}"
QT_ANDROID_PREFIX="$QT_ROOT/$QT_ABI_DIR"      # target Qt (libQt6Core_<abi>.so, ...)
QT_HOST_PREFIX="$QT_ROOT/gcc_64"              # host Qt: moc, repc, rcc in libexec/
QT_TOOLCHAIN_FILE="$QT_ANDROID_PREFIX/lib/cmake/Qt6/qt.toolchain.cmake"
export ANDROID_NDK_HOME ANDROID_NDK_ROOT ANDROID_SDK_ROOT JAVA_HOME

# ---- toolchain ---------------------------------------------------------------------
TC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
SYSROOT="$TC/sysroot"
NDK_SYSLIB_DIR="$SYSROOT/usr/lib/$TRIPLE/$ANDROID_API"   # NDK system-library stubs
LIBCXX_SHARED="$SYSROOT/usr/lib/$TRIPLE/libc++_shared.so"
CC="$TC/bin/$TRIPLE$ANDROID_API-clang"
CXX="$TC/bin/$TRIPLE$ANDROID_API-clang++"
AR="$TC/bin/llvm-ar"
RANLIB="$TC/bin/llvm-ranlib"
STRIP="$TC/bin/llvm-strip"
NM="$TC/bin/llvm-nm"
READELF="$TC/bin/llvm-readelf"
OBJCOPY="$TC/bin/llvm-objcopy"
# Every non-Qt artefact: 16 KB page-aligned LOAD segments (Android 15+ 16 KB devices;
# NDK r27c still defaults to 4 KB) and a build id for symbolication. Qt's own toolchain
# file adds the page-size flag for Qt consumers.
LDFLAGS_ANDROID="-Wl,-z,max-page-size=16384 -Wl,--build-id=sha1"

# ---- build tree --------------------------------------------------------------------
BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/build}"
DL_DIR="$BUILD_ROOT/dl"
SRC_ROOT="$BUILD_ROOT/src"
LOG_DIR="$BUILD_ROOT/logs"
ANDROID_BUILD="$BUILD_ROOT/android/$ABI"
PREFIX="$ANDROID_BUILD/prefix"
OBJ_DIR="$ANDROID_BUILD/obj"
STAMP_DIR="$ANDROID_BUILD/stamps"
TIMINGS="$ANDROID_BUILD/timings.tsv"
TMPDIR="$BUILD_ROOT/tmp"
export TMPDIR
JOBS="${JOBS:-$(nproc)}"
FORCE="${FORCE:-0}"
mkdir -p "$DL_DIR" "$SRC_ROOT" "$LOG_DIR" "$PREFIX" "$OBJ_DIR" "$STAMP_DIR" "$TMPDIR"

# Common CMake arguments for an NDK build installed into $PREFIX. Everything the prefix
# provides is found through CMAKE_PREFIX_PATH (packages) and CMAKE_FIND_ROOT_PATH
# (libraries/headers under the NDK toolchain's ONLY find mode). FetchContent is disconnected,
# so a missing dependency fails configure instead of silently cloning from the network.
_ANDROID_CMAKE_COMMON=(
  -DANDROID_ABI="$ABI"
  -DANDROID_PLATFORM="android-$ANDROID_API"
  -DANDROID_STL=c++_shared
  -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS_ANDROID"
  -DCMAKE_MODULE_LINKER_FLAGS="$LDFLAGS_ANDROID"
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS_ANDROID"
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_FIND_ROOT_PATH="$PREFIX"
  -DCMAKE_PREFIX_PATH="$PREFIX"
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON
)
NDK_CMAKE_ARGS=(
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
  "${_ANDROID_CMAKE_COMMON[@]}"
)
# The same for a Qt consumer (M3): Qt's own toolchain file chain-loads the NDK one (found
# through ANDROID_NDK_ROOT), puts the target Qt on the find paths and adds Qt6::Platform's
# 16 KB page flag; QT_HOST_PATH names the same-version desktop Qt whose moc/repc/rcc run
# on the build machine (Qt6CoreTools / Qt6RemoteObjectsTools).
QT_CMAKE_ARGS=(
  -DCMAKE_TOOLCHAIN_FILE="$QT_TOOLCHAIN_FILE"
  -DQT_HOST_PATH="$QT_HOST_PREFIX"
  -DANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
  -DANDROID_SDK_ROOT="$ANDROID_SDK_ROOT"
  "${_ANDROID_CMAKE_COMMON[@]}"
)

# Host (build-machine) tools, e.g. the Logos code generators: ABI-independent, built once
# with the host compiler against the desktop Qt ($QT_HOST_PREFIX), under build/host/.
HOST_BUILD="$BUILD_ROOT/host"
HOST_PREFIX="$HOST_BUILD/prefix"
HOST_OBJ_DIR="$HOST_BUILD/obj"

# ---- helpers -----------------------------------------------------------------------
die() { say "ERROR: $*"; exit 1; }

# log_setup NAME [tee]: append all further output of the calling script to
# $LOG_DIR/NAME-<abi>.log. Default: only `say` lines (progress, summaries) also reach the
# terminal, and a failure prints the log's tail; "tee" (or VERBOSE=1) mirrors everything.
LOG_FILE=/dev/null
exec 3>&1
say() { printf '%s\n' "$*"; [ "${_LOG_TEE:-1}" = 1 ] || printf '%s\n' "$*" >&3; }
log_setup() {
  LOG_FILE="$LOG_DIR/$1-$ABI.log"
  if [ "${2:-}" = tee ] || [ "${VERBOSE:-0}" = 1 ]; then
    _LOG_TEE=1
    exec > >(tee -a "$LOG_FILE") 2>&1
  else
    _LOG_TEE=0
    exec >>"$LOG_FILE" 2>&1
  fi
  echo "=================================================================="
  say "== $1 ABI=$ABI API=$ANDROID_API $(date -Is)  full log: $LOG_FILE"
  echo "=================================================================="
}
# on_error NAME: ERR-trap body -- report the failure and the log's last lines on the terminal.
on_error() {
  [ "${_LOG_TEE:-1}" = 1 ] && { echo "$1: FAILED (ABI=$ABI) -- full log: $LOG_FILE" >&2; return; }
  { echo "$1: FAILED (ABI=$ABI) -- last 40 lines of $LOG_FILE:"; tail -n 40 "$LOG_FILE"; } >&3
}

# check_host_tools: fail early with a clear message.
check_host_tools() {
  local t missing=()
  for t in cmake make perl python3 curl git tar bzip2 xz sha256sum; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [ ${#missing[@]} -eq 0 ] || die "missing host tools: ${missing[*]}"
  [ -x "$CXX" ] || die "NDK clang not found at $CXX (ANDROID_NDK_HOME=$ANDROID_NDK_HOME)"
  [ -d "$NDK_SYSLIB_DIR" ] || die "no NDK stubs for API $ANDROID_API at $NDK_SYSLIB_DIR"
}

# Step bookkeeping. A step is skipped when its stamp holds the same key (versions,
# patch hashes, options, plus the target and toolchain below) and its sentinel output
# exists, unless FORCE=1.
#   step_should_skip NAME KEY SENTINEL   -> 0 = skip
#   step_begin NAME / step_done NAME KEY
STAMP_COMMON="abi=$ABI api=$ANDROID_API ndk=$(sed -n 's/^Pkg.Revision = //p' "$ANDROID_NDK_HOME/source.properties" 2>/dev/null) ldflags=[$LDFLAGS_ANDROID]"
step_should_skip() {
  local name=$1 key="$2 | $STAMP_COMMON" sentinel=$3
  [ "$FORCE" = 1 ] && return 1
  [ -f "$STAMP_DIR/$name" ] || return 1
  [ "$(cat "$STAMP_DIR/$name")" = "$key" ] || return 1
  [ -e "$sentinel" ] || return 1
  say "-- $name: up to date (stamp $STAMP_DIR/$name; FORCE=1 to rebuild)"
  return 0
}
_STEP_T0=0
step_begin() {
  _STEP_T0=$(date +%s)
  echo
  say "################ $1 ($ABI) $(date -Is)"
}
step_done() {
  local name=$1 key="$2 | $STAMP_COMMON" secs=$(( $(date +%s) - _STEP_T0 ))
  printf '%s\n' "$key" > "$STAMP_DIR/$name"
  printf '%s\t%s\t%s\n' "$name" "$secs" "$(date -Is)" >> "$TIMINGS"
  say "-- $name: done in ${secs}s"
}

# sha256_of FILE
sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# patch_key FILE... : a stable fingerprint of a set of patch files (for stamps).
patch_key() {
  local f
  for f in "$@"; do printf '%s:%s ' "$(basename "$f")" "$(sha256_of "$f" | cut -c1-12)"; done
}

# fetch_url URL FILE SHA256 [ALT_URL]: download once into $DL_DIR/FILE and verify it.
# An empty SHA256 means "not pinned yet": the hash is printed so it can be pinned in
# versions.env (trust on first use); callers may cross-check it themselves.
fetch_url() {
  local url=$1 file=$2 want=$3 alt=${4:-} out="$DL_DIR/$2"
  if [ ! -s "$out" ]; then
    say "-- download $url"
    curl -fsSL --retry 3 --connect-timeout 30 -o "$out.part" "$url" \
      || { [ -n "$alt" ] && say "-- retry from $alt" && curl -fsSL --retry 3 --connect-timeout 30 -o "$out.part" "$alt"; } \
      || { rm -f "$out.part"; die "download failed: $url"; }
    mv "$out.part" "$out"
  fi
  local got; got=$(sha256_of "$out")
  if [ -n "$want" ]; then
    [ "$got" = "$want" ] || die "sha256 mismatch for $file: got $got, want $want (delete $out to re-download)"
    echo "-- $file sha256 ok ($got)"
  else
    say "-- $file sha256 $got (NOT PINNED: add it to scripts/android/versions.env)"
  fi
}

# extract_tarball FILE DIRNAME: unpack $DL_DIR/FILE into a fresh $SRC_ROOT/DIRNAME (the
# archive's single top-level directory is renamed to DIRNAME).
extract_tarball() {
  local file=$1 name=$2 dst="$SRC_ROOT/$2" tmp="$SRC_ROOT/.extract-$2"
  rm -rf "$dst" "$tmp"
  mkdir -p "$tmp"
  tar -xf "$DL_DIR/$file" -C "$tmp"
  local top; top=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d)
  [ "$(printf '%s\n' "$top" | wc -l)" = 1 ] || die "unexpected layout in $file"
  mv "$top" "$dst"
  rmdir "$tmp"
}

# apply_patches SRCDIR PATCH...: git-apply each patch (-p1) to SRCDIR. GIT_CEILING_DIRECTORIES
# stops git from treating an extracted tarball as part of this repository, so paths are
# resolved relative to SRCDIR in both cases (tarball or git checkout).
apply_patches() {
  local src=$1 p; shift
  for p in "$@"; do
    say "-- apply $(basename "$p") to $(basename "$src")"
    ( cd "$src" && GIT_CEILING_DIRECTORIES="$(dirname "$src")" git apply -p1 --whitespace=nowarn --verbose "$p" ) \
      || die "patch $p does not apply to $src"
  done
}

# prepare_tarball_src NAME FILE PATCH...: $SRC_ROOT/NAME = pristine FILE + patches, redone
# only when the tarball or a patch changed.
prepare_tarball_src() {
  local name=$1 file=$2; shift 2
  local key; key="$(sha256_of "$DL_DIR/$file") $(patch_key "$@")"
  local stamp="$SRC_ROOT/.stamps/$name"
  mkdir -p "$SRC_ROOT/.stamps"
  if [ "$FORCE" != 1 ] && [ -d "$SRC_ROOT/$name" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$key" ]; then
    echo "-- source $name ready"
    return 0
  fi
  echo "-- extract $file -> $SRC_ROOT/$name"
  extract_tarball "$file" "$name"
  [ $# -eq 0 ] || apply_patches "$SRC_ROOT/$name" "$@"
  printf '%s\n' "$key" > "$stamp"
}

# fetch_git REPO REV [ORG] [PATCH...]: $SRC_ROOT/REPO checked out at REV (clean), with the
# patches applied. Objects come from a LOGOS_SRC_MIRROR checkout when one has REV, else
# from https://github.com/ORG/REPO.git (shallow fetch of the exact commit).
# FETCH_AS=NAME (environment of the call) checks out into $SRC_ROOT/NAME instead, for a
# repo needed at two revisions (e.g. FETCH_AS=logos-module@9812dc8 fetch_git logos-module ...).
fetch_git() {
  local repo=$1 rev=$2 org=${3:-logos-co}; shift 3 || shift $#
  local dst="$SRC_ROOT/${FETCH_AS:-$repo}" url="https://github.com/$org/$repo.git"
  local key; key="$rev $(patch_key "$@")"
  local stamp="$dst/.git/logos-android-prepared"
  if [ "$FORCE" != 1 ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$key" ]; then
    echo "-- source $repo @ ${rev:0:7} ready"
    return 0
  fi
  if [ ! -d "$dst/.git" ]; then
    rm -rf "$dst"
    git init -q "$dst"
    git -C "$dst" remote add origin "$url"
  fi
  if ! git -C "$dst" cat-file -e "$rev^{commit}" 2>/dev/null; then
    local got=0 m mirrors=()
    IFS=: read -ra mirrors <<< "${LOGOS_SRC_MIRROR:-}"
    for m in "${mirrors[@]}"; do
      [ -n "$m" ] && [ -e "$m/$repo/.git" ] || continue
      if git -C "$m/$repo" cat-file -e "$rev^{commit}" 2>/dev/null \
         && git -C "$dst" fetch -q --no-tags "$m/$repo" "$rev"; then
        say "-- $repo @ ${rev:0:7} fetched from mirror $m/$repo"
        got=1; break
      fi
    done
    if [ $got = 0 ]; then
      say "-- $repo @ ${rev:0:7} fetching from $url"
      git -C "$dst" fetch -q --no-tags --depth 1 origin "$rev" || die "cannot fetch $rev from $url"
    fi
  fi
  git -C "$dst" -c advice.detachedHead=false checkout -q --force --detach "$rev"
  git -C "$dst" clean -qfdx
  [ $# -eq 0 ] || apply_patches "$dst" "$@"
  printf '%s\n' "$key" > "$stamp"
}

# ndk_cmake_build NAME SRCDIR [cmake args...]: fresh configure + build + install of a
# CMake project into $PREFIX with NDK_CMAKE_ARGS (later -D arguments override, e.g. a
# different -DCMAKE_INSTALL_PREFIX).
ndk_cmake_build() {
  local name=$1 src=$2; shift 2
  local b="$OBJ_DIR/$name"
  rm -rf "$b"
  echo "-- cmake configure $name: cmake -S $src -B $b ${NDK_CMAKE_ARGS[*]} $*"
  cmake -S "$src" -B "$b" "${NDK_CMAKE_ARGS[@]}" "$@"
  cmake --build "$b" -j "$JOBS"
  cmake --install "$b"
}

# qt_cmake_build NAME SRCDIR [cmake args...]: the same with QT_CMAKE_ARGS (a Qt consumer).
qt_cmake_build() {
  local name=$1 src=$2; shift 2
  local b="$OBJ_DIR/$name"
  rm -rf "$b"
  echo "-- cmake configure $name: cmake -S $src -B $b ${QT_CMAKE_ARGS[*]} $*"
  cmake -S "$src" -B "$b" "${QT_CMAKE_ARGS[@]}" "$@"
  cmake --build "$b" -j "$JOBS"
  cmake --install "$b"
}
