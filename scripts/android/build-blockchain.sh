#!/usr/bin/env bash
# scripts/android/build-blockchain.sh -- M5: cross-build the Logos blockchain node library
# liblogos_blockchain.so (logos-blockchain `-p logos-blockchain-c`, the C API blockchain_module
# wraps) for one Android ABI, with the Bedrock circuits built for Android (not stubbed).
#
# Output:
#   build/android/<abi>/prefix/lib/liblogos_blockchain.so    SONAME liblogos_blockchain.so
#   build/android/<abi>/prefix/include/logos_blockchain.h     cbindgen header (54 functions)
#   build/android/<abi>/prefix/share/logos-android/blockchain-manifest.txt  (what, from what)
#   build/android/<abi>/lbc/          the Android LBC_ROOT_DIR (NDK witness libs, NDK GMP,
#                                     release zkeys/vkeys/.dat)
#   build/android/<abi>/timings.tsv, build/logs/build-blockchain-<abi>.log (full log)
#
# Steps (pins in scripts/android/versions-blockchain.env; the recipe and its evidence are in
# docs/research/exp-bc-android-build.md):
#   toolchain   rustup toolchain RUST_TOOLCHAIN (= the node's rust-toolchain.toml) + the target
#   src         logos-blockchain @ LOGOS_BLOCKCHAIN_REV (tag 0.3.0-rc.4) + patches/logos-blockchain/
#               (a [patch] pointing lbc-build at the patched circuits copy, and the matching
#               Cargo.lock line); logos-blockchain-circuits @ LBC_REV (v0.5.7) +
#               patches/logos-blockchain-circuits/ (witness Makefile android-lib target; lbc-build
#               links libc++ on Android) + submodules circomlib, rapidsnark, rapidsnark/depends/json.
#               Fails unless the node's Cargo.lock pins lbc v$LBC_VERSION at LBC_REV and its
#               rust-toolchain.toml says RUST_TOOLCHAIN.
#   circom      circom CIRCOM_VERSION (the circuits CI's CIRCOM_TAG) from its git tag,
#               cargo install --root build/tools                                (host, once)
#   bundle      the circuits release bundle, sha256-pinned and cross-checked against the SRI in
#               the circuits repo's circuits-nix-hashes.json; VERSION must be v$LBC_VERSION
#   gen         circom --c --r1cs --no_asm --O2 for poc pol poq signature, then the circuits CI's
#               main.cpp return-0 sed, fix_calcwit_leak.sh and source/Makefile copies (host,
#               once). Each generated <c>.dat must be byte-identical to the release's
#               witness_generator.dat (proves the generated C++ is the released circuit).
#   gmp         GMP 6.2.1 through rapidsnark's own build_gmp.sh android_x86_64 | android
#               (unmodified: NDK clang at API 21, --with-pic --disable-fft; static)
#   witness     lib{poc,pol,poq,signature}.a: NDK clang++ at ANDROID_API against libc++, via the
#               android-lib target (ld.lld -r, llvm-objcopy --keep-global-symbol, llvm-ar)
#   lbc         build/android/<abi>/lbc = VERSION, lib/libgmp.a, <c>/lib<c>.a and, unchanged
#               from the release bundle (checked sha256-identical), <c>/proving_key.zkey,
#               verification_key.json, witness_generator.dat, include/. Keys are never
#               regenerated (each release's zkeys carry a random setup contribution).
#   rapidsnark  iden3 rapidsnark v0.0.8 Android zip (sha256-pinned) -> RAPIDSNARK_LIB_DIR
#   cargo       cargo build -p logos-blockchain-c --release --locked --target <triple>
#               (release profile: fat LTO, codegen-units=1, strip; ~8-9 min), then the checks
#               below, then install into the prefix
#
# cargo environment (no build-time downloads: LBC_ROOT_DIR and RAPIDSNARK_LIB_DIR are set):
#   CC/CXX/AR/RANLIB_<triple>, CARGO_TARGET_<TRIPLE>_LINKER: NDK <triple><api>-clang(++), llvm-ar
#   CARGO_TARGET_<TRIPLE>_RUSTFLAGS:
#     -Wl,-z,max-page-size=16384 -Wl,--build-id=sha1   (as every other prefix artefact)
#     -Wl,-soname,liblogos_blockchain.so   rustc gives a cdylib no SONAME; without one a consumer
#                                          linked by path records that path as its NEEDED
#     -L native=<stdc++ shim>   librocksdb-sys emits -lstdc++ for every *linux* triple, Android
#                               included; the shim directory holds libstdc++.so =
#                               "INPUT(-lc++_shared)", so it resolves to libc++_shared instead of
#                               the NDK's minimal system libstdc++.so
#     --remap-path-prefix       node/circuits sources and CARGO_HOME -> /logos-blockchain,
#                               /logos-blockchain-circuits, /cargo in panic strings
#   BINDGEN_EXTRA_CLANG_ARGS_<triple>=--sysroot=<NDK sysroot>; LIBCLANG_PATH (default /usr/lib64)
#
# Checks (the build fails otherwise): NEEDED is exactly libc++_shared.so libc.so libdl.so
# libm.so; SONAME liblogos_blockchain.so; every PT_LOAD p_align 0x4000; no TEXTREL; every
# function of logos_blockchain.h is exported; the header's sha256 is
# LOGOS_BLOCKCHAIN_HEADER_SHA256 (the C API blockchain_module 4b07e58 was built against).
#
# Usage:
#   bash scripts/android/build-blockchain.sh [x86_64|arm64-v8a] [STEP...]
#     STEP: toolchain src circom bundle gen gmp witness lbc rapidsnark cargo
#     (default: all, in that order)
#   Environment: see scripts/android/env.sh (ABI, ANDROID_API, ANDROID_NDK_HOME, FORCE=1 to
#   redo up-to-date steps, LOGOS_SRC_MIRROR: local checkouts, e.g. ~/src/logos-blockchain,
#   holding the pinned commits). JOBS defaults to 8 here (cargo -j, make -j). LIBCLANG_PATH
#   (bindgen's libclang, default /usr/lib64).
#
# Re-runnable: each step records a stamp keyed on its pins, patch hashes and options, and is
# skipped while the stamp matches and its main output exists; ABI-independent steps (circom,
# bundle, gen) keep their stamps in build/host/stamps. Sources (build/src) are shared by both
# ABIs: do not build two ABIs at the same time. The cargo target dir is
# build/android/<abi>/obj/blockchain/target (1.8 GB for x86_64). Cold build: ~11 min with
# JOBS=8 (cargo ~9.5 min of it; circom/GMP/witness libs ~1 min); a no-op re-run: < 1 s.
#
# Needs: rustup + cargo, git, curl, unzip, python3, make, m4 (GMP), NDK r27c, a host libclang
# (bindgen for librocksdb-sys). Network on the first run: GitHub (sources, release assets,
# crates' git deps), crates.io, ftp.gnu.org or gmplib.org.
set -euo pipefail

ALL_STEPS=(toolchain src circom bundle gen gmp witness lbc rapidsnark cargo)
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
export JOBS="${JOBS:-8}"   # the machine is shared: cargo -j 8 / make -j8 unless told otherwise
export LC_ALL=C

# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
# shellcheck source=versions-blockchain.env
source "$SCRIPTS_DIR/versions-blockchain.env"
log_setup build-blockchain
# EXIT, not ERR: an ERR trap does not fire inside functions (no errtrace), EXIT fires once.
trap 'rc=$?; [ "$rc" = 0 ] || on_error build-blockchain' EXIT
check_host_tools
for t in rustup cargo unzip m4; do command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"; done

# ---- layout ----------------------------------------------------------------------------
BC_SRC="$SRC_ROOT/logos-blockchain"
LBC_SRC="$SRC_ROOT/logos-blockchain-circuits"
TOOLS="$BUILD_ROOT/tools"
CIRCOM="$TOOLS/bin/circom"
GEN_DIR="$HOST_OBJ_DIR/circuits-gen"          # circom C++ output (ABI-independent)
BUNDLE_DIR="$SRC_ROOT/$LBC_BUNDLE"             # extracted release bundle (data files)
LBC_ROOT="$ANDROID_BUILD/lbc"                  # the Android LBC_ROOT_DIR
WIT_DIR="$OBJ_DIR/circuits"                    # per-ABI witness-lib builds
BC_OBJ="$OBJ_DIR/blockchain"
CARGO_TARGET="$BC_OBJ/target"
SHIM_DIR="$BC_OBJ/stdcxx-shim"
HOST_STAMPS="$HOST_BUILD/stamps"
mkdir -p "$TOOLS" "$HOST_STAMPS" "$HOST_OBJ_DIR" "$BC_OBJ"
case "$ABI" in
  x86_64)    GMP_TARGET=android_x86_64; GMP_PKG=package_android_x86_64; RS_ARCH=x86_64 ;;
  arm64-v8a) GMP_TARGET=android;        GMP_PKG=package_android_arm64;  RS_ARCH=arm64 ;;
esac
GMP_DIR="$LBC_SRC/rapidsnark/depends/gmp/$GMP_PKG"
RS_NAME="rapidsnark-android-$RS_ARCH-v$RAPIDSNARK_VERSION"
RS_DIR="$ANDROID_BUILD/rapidsnark/$RS_NAME"
# name:path-in-the-circuits-repo, as the circuits CI matrix (ci.yml) builds them
CIRCUITS=(poc:mantle/poc.circom pol:mantle/pol.circom poq:blend/poq.circom signature:mantle/signature.circom)
BC_PATCHES=("$PATCHES_DIR"/logos-blockchain/*.diff)
LBC_PATCHES=("$PATCHES_DIR"/logos-blockchain-circuits/*.diff)

say "prefix: $PREFIX"
say "node: logos-blockchain $LOGOS_BLOCKCHAIN_VERSION ($LOGOS_BLOCKCHAIN_REV)  circuits: v$LBC_VERSION  steps: ${STEPS[*]}  jobs: $JOBS  force: $FORCE"

# ---- helpers ---------------------------------------------------------------------------
# Host (ABI-independent) steps: stamps under build/host/stamps, keyed without the ABI.
host_should_skip() {
  local name=$1 key=$2 sentinel=$3
  [ "$FORCE" = 1 ] && return 1
  [ -f "$HOST_STAMPS/$name" ] && [ "$(cat "$HOST_STAMPS/$name")" = "$key" ] && [ -e "$sentinel" ] || return 1
  say "-- $name: up to date (host stamp $HOST_STAMPS/$name; FORCE=1 to rebuild)"
  return 0
}
host_done() {
  local name=$1 key=$2 secs=$(( $(date +%s) - _STEP_T0 ))
  printf '%s\n' "$key" > "$HOST_STAMPS/$name"
  printf '%s\t%s\t%s\n' "$name" "$secs" "$(date -Is)" >> "$TIMINGS"
  say "-- $name: done in ${secs}s"
}
stamp_of() { cat "$1" 2>/dev/null || echo missing; }
elf_machine() { "$READELF" -h "$1" 2>/dev/null | sed -n 's/^ *Machine: *//p' | sort -u | tr '\n' ' '; }

# ------------------------------------------------------------------------------------
step_toolchain() {
  local have
  have=$(rustup toolchain list)
  if ! [[ $'\n'"$have" == *$'\n'"$RUST_TOOLCHAIN-"* ]]; then
    say "-- rustup toolchain install $RUST_TOOLCHAIN"
    rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
  fi
  have=$(rustup target list --toolchain "$RUST_TOOLCHAIN" --installed)
  if ! [[ $'\n'"$have"$'\n' == *$'\n'"$TRIPLE"$'\n'* ]]; then
    say "-- rustup target add $TRIPLE ($RUST_TOOLCHAIN)"
    rustup target add --toolchain "$RUST_TOOLCHAIN" "$TRIPLE"
  fi
  echo "-- $(rustup run "$RUST_TOOLCHAIN" rustc --version), target $TRIPLE installed"
}

step_src() {
  fetch_git logos-blockchain "$LOGOS_BLOCKCHAIN_REV" logos-blockchain "${BC_PATCHES[@]}"
  fetch_git logos-blockchain-circuits "$LBC_REV" logos-blockchain "${LBC_PATCHES[@]}"
  # Only the submodules the Android build reads: circomlib (circuit sources), rapidsnark
  # (build_gmp.sh) and its depends/json (nlohmann headers for the witness libs).
  if [ ! -f "$LBC_SRC/circomlib/circuits/poseidon.circom" ] || [ ! -f "$LBC_SRC/rapidsnark/build_gmp.sh" ]; then
    say "-- logos-blockchain-circuits: submodules circomlib rapidsnark"
    git -C "$LBC_SRC" submodule update --init --depth 1 circomlib rapidsnark \
      || git -C "$LBC_SRC" submodule update --init circomlib rapidsnark
  fi
  if [ ! -f "$LBC_SRC/rapidsnark/depends/json/single_include/nlohmann/json.hpp" ]; then
    say "-- logos-blockchain-circuits: submodule rapidsnark/depends/json"
    git -C "$LBC_SRC/rapidsnark" submodule update --init --depth 1 depends/json \
      || git -C "$LBC_SRC/rapidsnark" submodule update --init depends/json
  fi
  git -C "$LBC_SRC" submodule status | sed 's/^/   /'

  # Consistency of the pins with what the node revision itself locks.
  local ch; ch=$(sed -n 's/^channel *= *"\(.*\)".*/\1/p' "$BC_SRC/rust-toolchain.toml")
  [ "$ch" = "$RUST_TOOLCHAIN" ] || die "node rust-toolchain.toml says '$ch', versions-blockchain.env RUST_TOOLCHAIN=$RUST_TOOLCHAIN"
  local lbc_refs; lbc_refs=$(grep -o 'logos-blockchain-circuits\.git?tag=v[^#"]*#[0-9a-f]*' "$BC_SRC/Cargo.lock" | sort -u)
  [ "$(printf '%s\n' "$lbc_refs" | wc -l)" = 1 ] || die "node Cargo.lock locks several circuits revisions: $lbc_refs"
  local tag=${lbc_refs#*tag=v}; tag=${tag%%#*}
  local sha=${lbc_refs##*#}
  [ "$tag" = "$LBC_VERSION" ] && [ "$sha" = "$LBC_REV" ] \
    || die "node Cargo.lock locks circuits v$tag @ $sha, versions-blockchain.env says v$LBC_VERSION @ $LBC_REV"
  say "-- node $(sed -n 's/^version *= *"\(.*\)"/\1/p' "$BC_SRC/Cargo.toml" | head -1) locks circuits v$tag @ ${sha:0:8}; toolchain $ch"
}

step_circom() {
  local key="circom $CIRCOM_VERSION $CIRCOM_REV"
  host_should_skip circom "$key" "$CIRCOM" && return 0
  step_begin circom
  fetch_git circom "$CIRCOM_REV" iden3
  # As the circuits CI: RUSTFLAGS="-A dead_code" cargo install --path circom (here --locked).
  ( cd "$SRC_ROOT/circom" && RUSTFLAGS="-A dead_code" CARGO_TARGET_DIR="$HOST_OBJ_DIR/circom-target" \
      cargo install --locked --force -j "$JOBS" --path circom --root "$TOOLS" )
  local v; v=$("$CIRCOM" --version)
  [[ "$v" == *"$CIRCOM_VERSION"* ]] || die "$CIRCOM is not $CIRCOM_VERSION: $v"
  host_done circom "$key"
}

step_bundle() {
  local key="bundle $LBC_BUNDLE $LBC_BUNDLE_SHA256"
  host_should_skip bundle "$key" "$BUNDLE_DIR/VERSION" && return 0
  step_begin bundle
  fetch_url "$LBC_BUNDLE_URL" "$LBC_BUNDLE.tar.gz" "$LBC_BUNDLE_SHA256"
  # Independent cross-check: the hash the circuits repo publishes for this release (Nix SRI).
  local json="$LBC_SRC/circuits-nix-hashes.json" sri hex
  sri=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["x86_64-linux"])' "$json" "$LBC_VERSION")
  hex=$(python3 -c 'import base64,sys; print(base64.b64decode(sys.argv[1].split("-",1)[1]).hex())' "$sri")
  [ "$sri" = "$LBC_BUNDLE_SRI" ] && [ "$hex" = "$LBC_BUNDLE_SHA256" ] \
    || die "bundle hash mismatch: circuits-nix-hashes.json $sri (= $hex) vs pinned $LBC_BUNDLE_SRI / $LBC_BUNDLE_SHA256"
  say "-- $LBC_BUNDLE.tar.gz matches circuits-nix-hashes.json v$LBC_VERSION x86_64-linux ($sri)"
  extract_tarball "$LBC_BUNDLE.tar.gz" "$LBC_BUNDLE"
  [ "$(cat "$BUNDLE_DIR/VERSION")" = "v$LBC_VERSION" ] || die "bundle VERSION is '$(cat "$BUNDLE_DIR/VERSION")', want v$LBC_VERSION"
  find "$BUNDLE_DIR" -type f -printf '   %P %s\n' | sort
  host_done bundle "$key"
}

step_gen() {
  local key="gen circom=$CIRCOM_VERSION lbc=$LBC_REV patches=[$(patch_key "${LBC_PATCHES[@]}")] bundle=$LBC_BUNDLE_SHA256"
  host_should_skip gen "$key" "$GEN_DIR/signature/signature_cpp/Makefile" && return 0
  step_begin gen
  [ -x "$CIRCOM" ] || die "no circom at $CIRCOM (run the circom step)"
  local res="$LBC_SRC/.github/resources/witness-generator" spec name path file stem out cpp
  for spec in "${CIRCUITS[@]}"; do
    name=${spec%%:*}; path=${spec#*:}; file=$(basename "$path"); stem=${file%.circom}
    out="$GEN_DIR/$name"; cpp="$out/${stem}_cpp"
    rm -rf "$out"; mkdir -p "$out"
    ( cd "$LBC_SRC/$(dirname "$path")" && "$CIRCOM" --c --r1cs --no_asm --O2 "$file" --output "$out" )
    # The circuits CI (compile-witness-generator/action.yml): main() gets its missing
    # `return 0`, ~Circom_CalcWit frees its buffers, then the FFI sources and the Makefile.
    sed -i ':a;N;$!ba;s/\n}\n\n*$/\n  return 0;\n}/' "$cpp/main.cpp"
    [[ "$(tail -n 3 "$cpp/main.cpp")" == *"return 0;"* ]] || die "main.cpp return-0 patch did not apply ($name)"
    sh "$res/fix_calcwit_leak.sh" "$cpp"
    cp -r "$LBC_SRC/src/$name" "$cpp/$name"
    cp "$LBC_SRC/src/circom_adapter.cpp" "$LBC_SRC/src/circom_adapter.hpp" "$LBC_SRC/src/circom_fwd.hpp" \
       "$LBC_SRC/src/types.hpp" "$LBC_SRC/src/assert.h" "$cpp/"
    cp "$res/Makefile" "$cpp/Makefile"
    cmp -s "$cpp/$stem.dat" "$BUNDLE_DIR/$name/witness_generator.dat" \
      || die "$name: generated $stem.dat differs from the v$LBC_VERSION release witness_generator.dat"
    say "-- $name: C++ generated; $stem.dat byte-identical to the release"
  done
  host_done gen "$key"
}

step_gmp() {
  local dep="$LBC_SRC/rapidsnark/depends"
  local key="gmp $GMP_VERSION $GMP_SHA256 build_gmp.sh=$(sha256_of "$LBC_SRC/rapidsnark/build_gmp.sh" | cut -c1-12) target=$GMP_TARGET"
  step_should_skip bc-gmp "$key" "$GMP_DIR/lib/libgmp.a" && return 0
  step_begin bc-gmp
  fetch_url "$GMP_URL" "gmp-$GMP_VERSION.tar.xz" "$GMP_SHA256" "$GMP_URL_ALT"
  # build_gmp.sh downloads and unpacks the tarball into depends/ itself when absent; hand it
  # the verified copy. It refuses to run when the package directory already exists.
  cp "$DL_DIR/gmp-$GMP_VERSION.tar.xz" "$dep/"
  if [ ! -d "$dep/gmp" ]; then ( cd "$dep" && tar -xf "gmp-$GMP_VERSION.tar.xz" && mv "gmp-$GMP_VERSION" gmp ); fi
  rm -rf "$GMP_DIR"
  # GMP's configure reads $ABI (its own meaning: 64/32/x32), so env.sh's ABI must not leak in.
  ( cd "$LBC_SRC/rapidsnark" && env -u ABI ANDROID_NDK="$ANDROID_NDK_HOME" bash ./build_gmp.sh "$GMP_TARGET" )
  [ -f "$GMP_DIR/lib/libgmp.a" ] && [ -f "$GMP_DIR/include/gmp.h" ] || die "build_gmp.sh $GMP_TARGET produced no $GMP_DIR/lib/libgmp.a"
  echo "-- libgmp.a machine: $(elf_machine "$GMP_DIR/lib/libgmp.a")"
  grep -E 'define GMP_LIMB_BITS|define __GMP_CC ' "$GMP_DIR/include/gmp.h" | sed 's/^/   /'
  step_done bc-gmp "$key"
}

step_witness() {
  local json_inc="$LBC_SRC/rapidsnark/depends/json/single_include"
  local key="witness gen=[$(stamp_of "$HOST_STAMPS/gen")] gmp=[$(stamp_of "$STAMP_DIR/bc-gmp")] api=$ANDROID_API"
  step_should_skip bc-witness "$key" "$WIT_DIR/signature/libsignature.a" && return 0
  step_begin bc-witness
  [ -f "$GMP_DIR/include/gmp.h" ] || die "no Android GMP at $GMP_DIR (run the gmp step)"
  local spec name dst pids=() rc=0 per=$(( JOBS / 4 )); [ "$per" -ge 1 ] || per=1
  for spec in "${CIRCUITS[@]}"; do
    name=${spec%%:*}; dst="$WIT_DIR/$name"
    [ -f "$GEN_DIR/$name/${name}_cpp/Makefile" ] || die "no generated C++ for $name (run the gen step)"
    rm -rf "$dst"; mkdir -p "$dst"; cp -r "$GEN_DIR/$name/${name}_cpp/." "$dst/"
    make -C "$dst" -j "$per" PROJECT="$name" android-lib \
      CXX="$CXX" LD="$TC/bin/ld.lld" AR="$AR" OBJCOPY="$OBJCOPY" \
      PRIORITY_FLAGS="-I$GMP_DIR/include -I$json_inc" > "$dst.log" 2>&1 &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || rc=1; done
  for spec in "${CIRCUITS[@]}"; do
    name=${spec%%:*}; dst="$WIT_DIR/$name"
    echo "---- $dst.log (tail)"; tail -n 5 "$dst.log"
    [ -f "$dst/lib$name.a" ] || { cat "$dst.log"; die "witness lib $name failed (log $dst.log)"; }
    local globals ndk cxx11
    globals=$("$NM" --defined-only -g "$dst/lib$name.a" 2>/dev/null | awk 'NF==3 {print $3}' | sort | tr '\n' ' ')
    ndk=$("$NM" -u -C "$dst/lib$name.a" | grep -c '__ndk1' || true)
    cxx11=$("$NM" -u -C "$dst/lib$name.a" | grep -c '__cxx11' || true)
    say "-- lib$name.a: $(stat -c %s "$dst/lib$name.a") B, $(elf_machine "$dst/lib$name.a"), globals: $globals, std::__ndk1 refs $ndk, __cxx11 refs $cxx11"
    [ "$globals" = "${name}_generate_witness ${name}_generate_witness_from_files " ] || die "lib$name.a exports '$globals'"
    [ "$cxx11" = 0 ] && [ "$ndk" -gt 0 ] || die "lib$name.a is not a libc++ (std::__ndk1) build"
  done
  [ "$rc" = 0 ] || die "a witness lib build failed"
  step_done bc-witness "$key"
}

step_lbc() {
  local key="lbc bundle=$LBC_BUNDLE_SHA256 witness=[$(stamp_of "$STAMP_DIR/bc-witness")]"
  step_should_skip bc-lbc "$key" "$LBC_ROOT/signature/libsignature.a" && return 0
  step_begin bc-lbc
  local name
  rm -rf "$LBC_ROOT"; mkdir -p "$LBC_ROOT/lib"
  cp "$BUNDLE_DIR/VERSION" "$LBC_ROOT/VERSION"
  cp "$GMP_DIR/lib/libgmp.a" "$LBC_ROOT/lib/libgmp.a"
  for name in poc pol poq signature; do
    mkdir -p "$LBC_ROOT/$name/include"
    cp "$WIT_DIR/$name/lib$name.a" "$LBC_ROOT/$name/"
    cp "$BUNDLE_DIR/$name/proving_key.zkey" "$BUNDLE_DIR/$name/verification_key.json" \
       "$BUNDLE_DIR/$name/witness_generator.dat" "$LBC_ROOT/$name/"
    cp "$BUNDLE_DIR/$name/include/"* "$LBC_ROOT/$name/include/"
  done
  ( cd "$BUNDLE_DIR" && find poc pol poq signature -type f ! -name '*.a' -exec sha256sum {} + ) \
    | ( cd "$LBC_ROOT" && sha256sum -c --quiet - ) || die "LBC data files differ from the release bundle"
  say "-- $LBC_ROOT: NDK libs + release data files (sha256-identical to $LBC_BUNDLE)"
  find "$LBC_ROOT" -type f -printf '   %P %s\n' | sort
  step_done bc-lbc "$key"
}

step_rapidsnark() {
  local zip="$RS_NAME.zip" var="RAPIDSNARK_SHA256_$RS_ARCH"
  local key="rapidsnark $RAPIDSNARK_VERSION ${!var}"
  step_should_skip bc-rapidsnark "$key" "$RS_DIR/lib/librapidsnark.a" && return 0
  step_begin bc-rapidsnark
  fetch_url "$RAPIDSNARK_URL_BASE/$zip" "$zip" "${!var}"
  rm -rf "$ANDROID_BUILD/rapidsnark"; mkdir -p "$ANDROID_BUILD/rapidsnark"
  unzip -q -o "$DL_DIR/$zip" -d "$ANDROID_BUILD/rapidsnark"
  [ -f "$RS_DIR/lib/librapidsnark.a" ] || die "$zip has no $RS_NAME/lib/librapidsnark.a"
  echo "-- $RS_DIR/lib: $(ls "$RS_DIR/lib" | tr '\n' ' ')($(elf_machine "$RS_DIR/lib/librapidsnark.a"))"
  step_done bc-rapidsnark "$key"
}

step_cargo() {
  local tu tl rs_var="RAPIDSNARK_SHA256_$RS_ARCH"
  tu=$(printf '%s' "$TRIPLE" | tr 'a-z-' 'A-Z_'); tl=${TRIPLE//-/_}
  local rustflags="-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,--build-id=sha1"
  rustflags+=" -C link-arg=-Wl,-soname,liblogos_blockchain.so -L native=$SHIM_DIR"
  rustflags+=" --remap-path-prefix=$BC_SRC=/logos-blockchain --remap-path-prefix=$LBC_SRC=/logos-blockchain-circuits"
  rustflags+=" --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo"
  local key="logos-blockchain $LOGOS_BLOCKCHAIN_REV patches=[$(patch_key "${BC_PATCHES[@]}" "${LBC_PATCHES[@]}")] rust=$RUST_TOOLCHAIN lbc=[$(stamp_of "$STAMP_DIR/bc-lbc")] rapidsnark=${!rs_var} rustflags=[$rustflags] header=$LOGOS_BLOCKCHAIN_HEADER_SHA256"
  step_should_skip bc-cargo "$key" "$PREFIX/lib/liblogos_blockchain.so" && return 0
  step_begin bc-cargo
  [ -f "$LBC_ROOT/signature/libsignature.a" ] || die "no Android LBC_ROOT_DIR at $LBC_ROOT (run the lbc step)"
  [ -f "$RS_DIR/lib/librapidsnark.a" ] || die "no rapidsnark at $RS_DIR (run the rapidsnark step)"
  mkdir -p "$SHIM_DIR"
  printf 'INPUT(-lc++_shared)\n' > "$SHIM_DIR/libstdc++.so"

  export CARGO_TARGET_DIR="$CARGO_TARGET"
  export "CC_$tl=$CC" "CXX_$tl=$CXX" "AR_$tl=$AR" "RANLIB_$tl=$RANLIB"
  export "CARGO_TARGET_${tu}_LINKER=$CC" "CARGO_TARGET_${tu}_AR=$AR"
  export "CARGO_TARGET_${tu}_RUSTFLAGS=$rustflags"
  export "BINDGEN_EXTRA_CLANG_ARGS_$tl=--sysroot=$SYSROOT"
  export LIBCLANG_PATH="${LIBCLANG_PATH:-/usr/lib64}"
  export LBC_ROOT_DIR="$LBC_ROOT"
  export RAPIDSNARK_LIB_DIR="$RS_DIR/lib"
  env | grep -E '^(CC_|CXX_|AR_|RANLIB_|CARGO_TARGET_|BINDGEN|LIBCLANG|LBC_|RAPIDSNARK)' | sort | sed 's/^/   /'
  git -C "$BC_SRC" status --short | sed 's/^/   git: /'

  say "-- cargo build -p logos-blockchain-c --release --locked --target $TRIPLE -j $JOBS (fat LTO: ~8-9 min)"
  local t0; t0=$(date +%s)
  ( cd "$BC_SRC" && cargo build -p logos-blockchain-c --release --locked --target "$TRIPLE" -j "$JOBS" )
  local secs=$(( $(date +%s) - t0 ))
  say "-- cargo build: ${secs}s"

  local so="$CARGO_TARGET/$TRIPLE/release/liblogos_blockchain.so" hdr="$BC_SRC/c-bindings/logos_blockchain.h"
  [ -f "$so" ] && [ -f "$hdr" ] || die "cargo produced no $so / $hdr"
  check_node_lib "$so" "$hdr"

  mkdir -p "$PREFIX/lib" "$PREFIX/include" "$PREFIX/share/logos-android"
  install -m 755 "$so" "$PREFIX/lib/liblogos_blockchain.so"
  install -m 644 "$hdr" "$PREFIX/include/logos_blockchain.h"
  {
    echo "# liblogos_blockchain.so -- written by scripts/android/build-blockchain.sh $(date -Is)"
    echo "abi=$ABI triple=$TRIPLE api=$ANDROID_API ndk=$NDK_VERSION rust=$RUST_TOOLCHAIN cargo_seconds=$secs"
    echo "logos-blockchain=$LOGOS_BLOCKCHAIN_VERSION rev=$LOGOS_BLOCKCHAIN_REV (module pin $LOGOS_BLOCKCHAIN_MODULE_PIN + devnet genesis)"
    echo "patches=[$(patch_key "${BC_PATCHES[@]}" "${LBC_PATCHES[@]}")]"
    echo "circuits=v$LBC_VERSION rev=$LBC_REV bundle=$LBC_BUNDLE sha256=$LBC_BUNDLE_SHA256 circom=$CIRCOM_VERSION gmp=$GMP_VERSION"
    echo "rapidsnark=iden3 v$RAPIDSNARK_VERSION $RS_NAME.zip sha256=${!rs_var}"
    echo "rustflags=$rustflags"
    echo "liblogos_blockchain.so size=$(stat -c %s "$so") sha256=$(sha256_of "$so")"
    echo "logos_blockchain.h sha256=$(sha256_of "$hdr")"
  } > "$PREFIX/share/logos-android/blockchain-manifest.txt"
  step_done bc-cargo "$key"
}

# check_node_lib SO HEADER: the acceptance checks listed in the header comment.
check_node_lib() {
  local so=$1 hdr=$2 dyn needed soname aligns
  dyn=$("$READELF" -d "$so")
  needed=$(printf '%s\n' "$dyn" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort | tr '\n' ' ')
  soname=$(printf '%s\n' "$dyn" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
  aligns=$("$READELF" -lW "$so" | awk '$1 == "LOAD" {print $NF}' | sort -u | tr '\n' ' ')
  say "-- liblogos_blockchain.so: $(stat -c %s "$so") B, $(elf_machine "$so")"
  say "   SONAME $soname | NEEDED $needed| LOAD p_align $aligns"
  [ "$(elf_machine "$so")" = "$ELF_MACHINE " ] || die "machine is not $ELF_MACHINE"
  [ "$needed" = "libc++_shared.so libc.so libdl.so libm.so " ] || die "unexpected NEEDED: $needed"
  [ "$soname" = liblogos_blockchain.so ] || die "SONAME is '$soname'"
  [ "$aligns" = "0x4000 " ] || die "LOAD p_align is '$aligns', want 0x4000 everywhere"
  [[ "$dyn" != *TEXTREL* ]] || die "has text relocations"
  "$NM" -D --defined-only "$so" | awk '$2 ~ /^[TW]$/ {print $3}' | sort -u > "$BC_OBJ/exports.txt"
  python3 - "$hdr" "$BC_OBJ/exports.txt" > "$BC_OBJ/header-vs-exports.txt" <<'PY'
import re, sys
hdr = open(sys.argv[1]).read()
hdr = re.sub(r'/\*.*?\*/', '', hdr, flags=re.S)
hdr = re.sub(r'//[^\n]*', '', hdr)
# Drop typedefs (callback typedefs `typedef void (*cb)(...)` would read as a function "void").
hdr = re.sub(r'\btypedef\b[^;]*;', '', hdr)
funcs = set(re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*\([^;{]*\)\s*;', hdr))
funcs -= {"if", "while", "for", "return", "sizeof", "void"}
exp = set(open(sys.argv[2]).read().split())
print(f"header functions: {len(funcs)}")
print(f"exported: {len(funcs & exp)}")
print(f"missing: {' '.join(sorted(funcs - exp))}")
print(f"extra exports: {' '.join(sorted(exp - funcs))}")
PY
  sed 's/^/   /' "$BC_OBJ/header-vs-exports.txt"
  grep -q '^missing: $' "$BC_OBJ/header-vs-exports.txt" || die "header functions not exported (see $BC_OBJ/header-vs-exports.txt)"
  say "   $(head -2 "$BC_OBJ/header-vs-exports.txt" | tr '\n' ' ')"
  local hsha; hsha=$(sha256_of "$hdr")
  [ "$hsha" = "$LOGOS_BLOCKCHAIN_HEADER_SHA256" ] \
    || die "logos_blockchain.h sha256 $hsha differs from LOGOS_BLOCKCHAIN_HEADER_SHA256 (the C API blockchain_module expects); diff the header, then update the pin"
  say "   logos_blockchain.h identical to the header at the module's pin ($LOGOS_BLOCKCHAIN_MODULE_PIN)"
}

# ------------------------------------------------------------------------------------
T_ALL=$(date +%s)
for s in "${STEPS[@]}"; do "step_$s"; done
if [ -f "$PREFIX/lib/liblogos_blockchain.so" ]; then
  say "-- installed: $PREFIX/lib/liblogos_blockchain.so ($(stat -c %s "$PREFIX/lib/liblogos_blockchain.so") B), $PREFIX/include/logos_blockchain.h"
fi
say "build-blockchain: OK ($ABI) in $(( $(date +%s) - T_ALL ))s $(date -Is)"
