#!/usr/bin/env bash
# scripts/android/build-libfyaml.sh -- M5: NDK build of libfyaml, the YAML library the
# blockchain_module plugin links (src/user_config_reader.cpp; CMakeLists LINK_LIBRARIES fyaml),
# for one Android ABI.
#
# Output (build/android/<abi>/prefix):
#   lib/libfyaml.so              shared, SONAME libfyaml.so, 16 KB-aligned, NEEDs only libc/libm/libdl
#   include/libfyaml.h
#   lib/pkgconfig/libfyaml.pc
# plus build/logs/build-libfyaml-<abi>.log (full log) and a line in build/android/<abi>/timings.tsv.
#
# Version and linkage follow the desktop module: its .lgx ships libfyaml.so.0 next to the
# plugin (metadata.json "include"; nix.runtime "libfyaml"), i.e. nixpkgs 25.11's libfyaml 0.9,
# built with autotools and --disable-network, linked SHARED. Android differences:
#   - the release tarball (configure pre-generated; no autoreconf needed) -- same 0.9 sources
#     as the git tag nixpkgs fetches; the git archive's CMakeLists.txt is stale (says 0.7.2)
#   - unversioned SONAME libfyaml.so (libtool -avoid-version, set on the library's link line
#     only): an APK only packages lib*.so, and a NEED on libfyaml.so.0 could not be satisfied
#   - bionic has pthreads in libc and no libpthread; configure forces -lpthread, so an empty
#     libpthread.a stub is put on the link path (nothing is linked from it), and -lpthread is
#     dropped from the installed libfyaml.pc
#   - bionic has no qsort_r; configure detects that and libfyaml uses its qsort() fallback
#   - host tools are kept out: pkg-config is pointed at an empty directory (no host libyaml /
#     check), --without-libclang (no host llvm-config); only the library is built, not fy-tool
# Headers the module also needs (nlohmann/json.hpp, boost/algorithm/hex.hpp,
# boost/algorithm/string/trim.hpp) come from build-deps.sh; this script checks they are there.
#
# Usage:
#   bash scripts/android/build-libfyaml.sh [x86_64|arm64-v8a]
#   Environment: see scripts/android/env.sh (ABI, ANDROID_API, ANDROID_NDK_HOME, JOBS (default
#   8 here), FORCE=1 to rebuild). Pins: scripts/android/versions-blockchain.env (LIBFYAML_*).
# Re-runnable: skipped while its stamp (version, tarball hash, options) matches and
# prefix/lib/libfyaml.so exists.
set -euo pipefail

for a in "$@"; do
  case "$a" in
    x86_64|arm64-v8a) ABI=$a ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 0 ;;
    *) echo "unknown argument: $a (x86_64 | arm64-v8a)" >&2; exit 2 ;;
  esac
done
export ABI="${ABI:-x86_64}"
export JOBS="${JOBS:-8}"
export LC_ALL=C

# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
# shellcheck source=versions-blockchain.env
source "$SCRIPTS_DIR/versions-blockchain.env"
log_setup build-libfyaml
trap 'rc=$?; [ "$rc" = 0 ] || on_error build-libfyaml' EXIT
check_host_tools
command -v m4 >/dev/null 2>&1 || die "missing host tool: m4 (libfyaml's configure needs it)"

TB="libfyaml-$LIBFYAML_VERSION.tar.gz"
SRC="$SRC_ROOT/libfyaml-$LIBFYAML_VERSION"
B="$OBJ_DIR/libfyaml"
LT_LDFLAGS="-no-undefined -avoid-version"   # replaces "-version $(LIBTOOL_VERSION)" (-> .so.0)
KEY="libfyaml $LIBFYAML_VERSION $LIBFYAML_SHA256 shared soname=libfyaml.so lt=[$LT_LDFLAGS] configure=[--disable-network --without-libclang --disable-static] pc=[no -lpthread]"

if ! step_should_skip libfyaml "$KEY" "$PREFIX/lib/libfyaml.so"; then
  step_begin libfyaml
  fetch_url "$LIBFYAML_URL" "$TB" "$LIBFYAML_SHA256"
  prepare_tarball_src "libfyaml-$LIBFYAML_VERSION" "$TB"
  rm -rf "$B"; mkdir -p "$B/stub" "$B/no-pkgconfig"
  printf '!<arch>\n' > "$B/stub/libpthread.a"          # an empty ar archive
  (
    cd "$B"
    export PKG_CONFIG_LIBDIR="$B/no-pkgconfig" PKG_CONFIG_PATH=""
    "$SRC/configure" --host="$TRIPLE" --prefix="$PREFIX" --libdir="$PREFIX/lib" \
      --enable-shared --disable-static --disable-network --without-libclang \
      CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" NM="$NM" \
      CFLAGS="-O2" LDFLAGS="$LDFLAGS_ANDROID -L$B/stub"
    grep -E '^#define (HAVE_QSORT_R|TARGET_HAS_[A-Z0-9]+|HAVE_LIBYAML|HAVE_LIBCLANG) ' config.h | sed 's/^/   /' || true
    make -C src -j"$JOBS" libfyaml.la libfyaml_la_LDFLAGS="$LT_LDFLAGS"
    make -C src install-libLTLIBRARIES install-includeHEADERS libfyaml_la_LDFLAGS="$LT_LDFLAGS"
    make install-pkgconfigDATA
  )
  rm -f "$PREFIX/lib/libfyaml.la"
  # configure put the forced -lpthread into the .pc's Libs; there is no libpthread on Android.
  sed -i 's/ -lpthread//' "$PREFIX/lib/pkgconfig/libfyaml.pc"

  so="$PREFIX/lib/libfyaml.so"
  [ -f "$so" ] && [ ! -L "$so" ] || die "no regular file $so after install"
  if compgen -G "$PREFIX/lib/libfyaml.so.*" >/dev/null; then die "versioned libfyaml.so.* installed: $(ls "$PREFIX"/lib/libfyaml.so.*)"; fi
  dyn=$("$READELF" -d "$so")
  soname=$(printf '%s\n' "$dyn" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
  needed=$(printf '%s\n' "$dyn" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort | tr '\n' ' ')
  aligns=$("$READELF" -lW "$so" | awk '$1 == "LOAD" {print $NF}' | sort -u | tr '\n' ' ')
  say "-- libfyaml.so: $(stat -c %s "$so") B | SONAME $soname | NEEDED $needed| LOAD p_align $aligns"
  [ "$soname" = libfyaml.so ] || die "SONAME is '$soname', want libfyaml.so"
  [ "$aligns" = "0x4000 " ] || die "LOAD p_align '$aligns', want 0x4000"
  for n in $needed; do
    [ -f "$NDK_SYSLIB_DIR/$n" ] || [ "$n" = libc++_shared.so ] || die "NEEDED $n is not an NDK system library"
  done
  # The libfyaml API blockchain_module's user_config_reader.cpp calls (fy_node_is_scalar and
  # fy_node_is_mapping are static inline wrappers of fy_node_get_type in libfyaml.h).
  exports=$("$NM" -D --defined-only "$so" | awk '$2 == "T" {print $3}')
  for f in fy_document_build_from_file fy_document_destroy fy_document_root fy_node_by_path \
           fy_node_get_type fy_node_get_scalar0 fy_node_mapping_iterate \
           fy_node_pair_key fy_node_pair_value; do
    [[ $'\n'"$exports"$'\n' == *$'\n'"$f"$'\n'* ]] || die "libfyaml.so does not export $f"
  done
  say "-- $(printf '%s\n' "$exports" | grep -c '^fy_' || true) fy_* functions exported (incl. the 9 blockchain_module uses)"
  [ -f "$PREFIX/include/libfyaml.h" ] || die "libfyaml.h not installed"
  step_done libfyaml "$KEY"
fi

# The other native dependencies of the blockchain_module plugin: header-only use of
# nlohmann_json and boost (algorithm/hex, algorithm/string/trim), all from build-deps.sh.
for h in nlohmann/json.hpp boost/algorithm/hex.hpp boost/algorithm/string/trim.hpp; do
  [ -f "$PREFIX/include/$h" ] || die "$PREFIX/include/$h missing (run scripts/android/build-deps.sh)"
done
say "-- module headers present in the prefix: nlohmann/json.hpp boost/algorithm/hex.hpp boost/algorithm/string/trim.hpp"
say "build-libfyaml: OK ($ABI) $(date -Is)"
