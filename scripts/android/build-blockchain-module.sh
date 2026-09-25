#!/usr/bin/env bash
# scripts/android/build-blockchain-module.sh -- M5/M6: build the blockchain_module Qt plugin
# (logos-blockchain-module 4b07e58) and bc_probe (modules/bc_probe, the module that calls it
# over liblogos' transport) for one Android ABI, and stage both as module directories.
#
# Inputs (build/android/<abi>/prefix unless noted):
#   the M3 runtime and SDK (scripts/android/build-runtime.sh): headers and CMake packages,
#     share/logos-android/runtime-manifest.txt (its runtime key goes into the stamps),
#     the host code generators in build/host/prefix/bin
#   lib/liblogos_blockchain.so, include/logos_blockchain.h   (scripts/android/build-blockchain.sh)
#   lib/libfyaml.so, include/libfyaml.h                      (scripts/android/build-libfyaml.sh)
#   include/boost, include/nlohmann                          (scripts/android/build-deps.sh)
#
# Output:
#   build/android/<abi>/modules/blockchain_module/
#     blockchain_module_plugin.so   NEEDED liblogos_blockchain.so libfyaml.so (+ Qt, OpenSSL,
#                                   libc++, NDK), DT_RUNPATH $ORIGIN
#     liblogos_blockchain.so        the node library, a copy of the prefix's (~87 MB)
#     libfyaml.so                   a copy of the prefix's
#     manifest.json, variant        as every staged module (scripts/android/module-build.sh)
#   build/android/<abi>/modules/bc_probe/
#     bc_probe_plugin.so, manifest.json (dependencies ["blockchain_module"]), variant
#   build/android/<abi>/lidl/{blockchain_module,bc_probe}.lidl  the modules' LIDL contracts
#   build/android/<abi>/blockchain-module-summary.txt  sizes (as built / stripped / deflated),
#                                                       NEEDED, RUNPATH, LIDL method counts
#   build/logs/build-blockchain-module-<abi>.log       full log
# and it finishes by running scripts/android/check-prefix.sh on the prefix and modules dir.
#
# Steps (pins: scripts/android/versions-blockchain.env and versions.env):
#   blockchain_module  github.com/logos-blockchain/logos-blockchain-module @
#                      LOGOS_BLOCKCHAIN_MODULE_REV (4b07e58) + patches/logos-blockchain-module/
#                      (module-quiet-newblock-log.diff), built by build_universal_module
#                      (scripts/android/module-build.sh: host code generation, then
#                      logos-module-builder LOGOS_MODULE_BUILDER_REV's LogosModule.cmake with
#                      the Qt/NDK toolchain). Its CMakeLists declares
#                        EXTERNAL_LIBS logos_blockchain  -> LOGOS_EXT_ROOT_LOGOS_BLOCKCHAIN=<prefix>
#                           (LogosModule.cmake's hook for a lib/ + include/ package root)
#                        LINK_LIBRARIES fyaml            -> -L<prefix>/lib on the plugin link
#                      Staging layout: the plugin's private libraries (liblogos_blockchain.so,
#                      libfyaml.so) live IN the module directory, as in the desktop .lgx, and
#                      the plugin carries DT_RUNPATH $ORIGIN, so bionic resolves them there
#                      when the module host (liblogos_host_qt.so, LD_LIBRARY_PATH =
#                      nativeLibraryDir) dlopen()s the plugin from filesDir/modules.
#                      stage.sh keeps module siblings out of jniLibs.
#   bc_probe           modules/bc_probe (this repo), dependencies ["blockchain_module"]. Its
#                      typed modules().blockchain_module client is generated from the LIDL
#                      contract the blockchain_module step published (lidl/blockchain_module.lidl):
#                      the desktop flake's input named `blockchain_module` becomes
#                      `logos-cpp-generator --dep=blockchain_module=<lidl>`, as mkLogosModule
#                      passes it.
# Checks (the build fails otherwise): the plugin NEEDs liblogos_blockchain.so and libfyaml.so
# by bare SONAME and has DT_RUNPATH exactly $ORIGIN; the staged private libraries are
# byte-identical to the prefix's; the LIDL contract has the 48 methods and 3 events the
# desktop module exposes; bc_probe got a generated blockchain_module wrapper, does not link
# the node library and its manifest names its dependency; then check-prefix.sh.
#
# Usage:
#   bash scripts/android/build-blockchain-module.sh [x86_64|arm64-v8a] [STEP...]
#     STEP: blockchain_module bc_probe (default: both, in that order)
#   Environment: see scripts/android/env.sh (ABI, JOBS, FORCE=1 rebuilds up-to-date steps,
#   LOGOS_SRC_MIRROR: local checkouts such as ~/src/logos-blockchain holding the pinned commit).
#   Then: bash scripts/android/stage.sh <abi> capability_module hello_module blockchain_module bc_probe
#
# Re-runnable: each step records a stamp keyed on its revision, patches, the builder, the
# module variant, the runtime key and (blockchain_module) the node/libfyaml/header hashes or
# (bc_probe) its sources and the blockchain_module contract; it is skipped while the stamp
# matches and the plugin exists. ~30 s cold for both steps (x86_64, 16 cores, source fetch
# included); a no-op re-run ~5 s (the summary strips and deflates the 87 MB library).
#
# Needs: the prefix and host tools above, python3, gzip, cmake, make, git. Network: GitHub
# (first run only, the module source; LOGOS_SRC_MIRROR can serve it).
set -Eeuo pipefail   # -E: the ERR trap (log tail on failure) also fires inside functions

ALL_STEPS=(blockchain_module bc_probe)
STEPS=()
for a in "$@"; do
  case "$a" in
    x86_64|arm64-v8a) ABI=$a ;;
    all) STEPS=("${ALL_STEPS[@]}") ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 0 ;;
    *) printf '%s\n' "${ALL_STEPS[@]}" | grep -qx -- "$a" || { echo "unknown step or ABI: $a" >&2; exit 2; }
       STEPS+=("$a") ;;
  esac
done
[ ${#STEPS[@]} -gt 0 ] || STEPS=("${ALL_STEPS[@]}")
export ABI="${ABI:-x86_64}"
export LC_ALL=C

# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
# shellcheck source=versions-blockchain.env
source "$SCRIPTS_DIR/versions-blockchain.env"
log_setup build-blockchain-module
trap 'on_error build-blockchain-module' ERR
check_host_tools
command -v gzip >/dev/null 2>&1 || die "missing host tool: gzip"
[ -f "$QT_TOOLCHAIN_FILE" ] || die "no target Qt at $QT_ANDROID_PREFIX (QT_ROOT=$QT_ROOT)"
for f in "$HOST_PREFIX/bin/logos-cpp-generator" "$HOST_PREFIX/bin/logos-qt-host-generator" \
         "$PREFIX/include/cpp/logos_module_context.h" "$PREFIX/lib/liblogos_qt_host.a" \
         "$PREFIX/share/logos-android/runtime-manifest.txt"; do
  [ -e "$f" ] || die "$f missing: run scripts/android/build-runtime.sh $ABI first"
done
[ -f "$PREFIX/lib/liblogos_blockchain.so" ] && [ -f "$PREFIX/include/logos_blockchain.h" ] \
  || die "no node library in $PREFIX: run scripts/android/build-blockchain.sh $ABI first"
[ -f "$PREFIX/lib/libfyaml.so" ] && [ -f "$PREFIX/include/libfyaml.h" ] \
  || die "no libfyaml in $PREFIX: run scripts/android/build-libfyaml.sh $ABI first"
for h in boost/algorithm/hex.hpp boost/algorithm/string/trim.hpp nlohmann/json.hpp; do
  [ -f "$PREFIX/include/$h" ] || die "$PREFIX/include/$h missing: run scripts/android/build-deps.sh $ABI first"
done

# shellcheck source=module-build.sh
source "$SCRIPTS_DIR/module-build.sh"   # MODULES_OUT, LIDL_OUT, ROOTS, build_universal_module

# The runtime these modules are compiled against (build-runtime.sh's closure key).
RT=$(sed -n 's/.* \(rt=[0-9a-f]*\).*/\1/p' "$PREFIX/share/logos-android/runtime-manifest.txt" | head -1)
[ -n "$RT" ] || die "no runtime key in $PREFIX/share/logos-android/runtime-manifest.txt"

say "prefix: $PREFIX"
say "steps: ${STEPS[*]}   jobs: $JOBS   force: $FORCE   runtime: $RT   variant: $LGX_VARIANT"

BC_PATCHES=("$PATCHES_DIR"/logos-blockchain-module/*.diff)
needed_of() { "$READELF" -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'; }
runpath_of() { "$READELF" -d "$1" 2>/dev/null | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p'; }
# lidl_counts FILE -> "<methods> <events>": the `method name(...)` and `event name(...)`
# declarations of a LIDL contract.
lidl_counts() {
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
print(len(re.findall(r'^\s*method\s+\w+\s*\(', text, re.M)), len(re.findall(r'^\s*event\s+\w+\s*\(', text, re.M)))
PY
}

# ------------------------------------------------------------------------------------
step_blockchain_module() {
  local node_sha fy_sha hdr_sha
  node_sha=$(sha256_of "$PREFIX/lib/liblogos_blockchain.so")
  fy_sha=$(sha256_of "$PREFIX/lib/libfyaml.so")
  hdr_sha=$(sha256_of "$PREFIX/include/logos_blockchain.h")
  local key="logos-blockchain-module $LOGOS_BLOCKCHAIN_MODULE_REV patches=[$(patch_key "${BC_PATCHES[@]}")] builder=$LOGOS_MODULE_BUILDER_REV variant=$LGX_VARIANT $RT node=${node_sha:0:16} fyaml=${fy_sha:0:16} header=${hdr_sha:0:16} layout=module-dir+runpath-origin"
  step_should_skip blockchain_module "$key" "$MODULES_OUT/blockchain_module/blockchain_module_plugin.so" && return 0
  step_begin blockchain_module
  fetch_git logos-blockchain-module "$LOGOS_BLOCKCHAIN_MODULE_REV" "$LOGOS_BLOCKCHAIN_MODULE_ORG" "${BC_PATCHES[@]}"
  fetch_git logos-module-builder "$LOGOS_MODULE_BUILDER_REV" logos-co
  # EXTERNAL_LIBS logos_blockchain: lib/liblogos_blockchain.so + include/logos_blockchain.h.
  local -x LOGOS_EXT_ROOT_LOGOS_BLOCKCHAIN="$PREFIX"
  build_universal_module blockchain_module "$SRC_ROOT/logos-blockchain-module" \
    --private-lib "$PREFIX/lib/liblogos_blockchain.so" \
    --private-lib "$PREFIX/lib/libfyaml.so" \
    --ldflags "-L$PREFIX/lib"

  local d="$MODULES_OUT/blockchain_module" p n needed rp
  p="$d/blockchain_module_plugin.so"
  needed=$(needed_of "$p" | tr '\n' ' ')
  rp=$(runpath_of "$p")
  say "-- blockchain_module_plugin.so NEEDED: $needed"
  say "-- blockchain_module_plugin.so RUNPATH: [$rp]"
  for n in liblogos_blockchain.so libfyaml.so; do
    [[ " $needed" == *" $n "* ]] || die "the plugin does not NEED $n (NEEDED: $needed)"
    cmp -s "$d/$n" "$PREFIX/lib/$n" || die "$d/$n differs from $PREFIX/lib/$n"
  done
  [[ "$needed" != */* ]] || die "the plugin NEEDs a path: $needed"
  [ "$rp" = '$ORIGIN' ] || die "the plugin's DT_RUNPATH is '$rp', want \$ORIGIN (its private libraries would not resolve)"
  [ "$(cd "$d" && find . -type f -printf '%P\n' | sort | tr '\n' ' ')" \
    = "blockchain_module_plugin.so libfyaml.so liblogos_blockchain.so manifest.json variant " ] \
    || die "unexpected files in $d: $(ls "$d" | tr '\n' ' ')"
  local counts; counts=$(lidl_counts "$LIDL_OUT/blockchain_module.lidl")
  say "-- blockchain_module.lidl: ${counts% *} methods, ${counts#* } events"
  [ "$counts" = "48 3" ] || die "blockchain_module.lidl has '$counts' (methods events); the desktop module exposes 48 methods and 3 events"
  step_done blockchain_module "$key"
}

step_bc_probe() {
  local src="$REPO_ROOT/modules/bc_probe" lidl="$LIDL_OUT/blockchain_module.lidl"
  [ -f "$lidl" ] || die "no $lidl: run the blockchain_module step first"
  local srchash; srchash=$(cd "$src" && find . -type f -not -path './generated_code/*' -not -path './result*' | sort | xargs sha256sum | sha256sum | cut -c1-16)
  local key="bc_probe src=$srchash dep=blockchain_module.lidl:$(sha256_of "$lidl" | cut -c1-16) builder=$LOGOS_MODULE_BUILDER_REV variant=$LGX_VARIANT $RT"
  step_should_skip bc_probe "$key" "$MODULES_OUT/bc_probe/bc_probe_plugin.so" && return 0
  step_begin bc_probe
  fetch_git logos-module-builder "$LOGOS_MODULE_BUILDER_REV" logos-co
  build_universal_module bc_probe "$src" --dep "blockchain_module=$lidl"

  local gen="$MODSRC_DIR/bc_probe/generated_code/include" needed deps
  [ -s "$gen/blockchain_module_api.h" ] && [ -s "$gen/logos_sdk.h" ] \
    || die "no generated blockchain_module wrapper in $gen"
  grep -q 'blockchain_module' "$gen/logos_sdk.h" || die "$gen/logos_sdk.h has no blockchain_module member"
  needed=$(needed_of "$MODULES_OUT/bc_probe/bc_probe_plugin.so" | tr '\n' ' ')
  say "-- bc_probe_plugin.so NEEDED: $needed"
  [[ " $needed" != *" liblogos_blockchain.so "* ]] || die "bc_probe links the node library; it must only call blockchain_module"
  deps=$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).get("dependencies", [])))' "$MODULES_OUT/bc_probe/manifest.json")
  [ "$deps" = blockchain_module ] || die "bc_probe manifest dependencies are '$deps'"
  say "-- bc_probe: modules().blockchain_module generated from $lidl ($(grep -c 'StdLogosResult' "$gen/blockchain_module_api.h") StdLogosResult lines in blockchain_module_api.h)"
  step_done bc_probe "$key"
}

# ------------------------------------------------------------------------------------
T_ALL=$(date +%s)
for s in "${STEPS[@]}"; do "step_$s"; done

# Summary: what the two module directories weigh, as built, stripped (what stage.sh copies)
# and deflated (gzip -6 of the stripped file: about what the APK stores for an asset).
stripped_size() { "$STRIP" --strip-unneeded -o "$TMPDIR/strip.$$" "$1"; stat -c %s "$TMPDIR/strip.$$"; }
deflated_size() { gzip -6 -c "$TMPDIR/strip.$$" | wc -c; }
SUMMARY="$ANDROID_BUILD/blockchain-module-summary.txt"
{
  echo "################ blockchain_module + bc_probe ($ABI) $(date -Is)"
  echo "-- this run: $(( $(date +%s) - T_ALL ))s; module $LOGOS_BLOCKCHAIN_MODULE_REV, node $(sed -n 's/^logos-blockchain=\([^ ]*\) .*/\1/p' "$PREFIX/share/logos-android/blockchain-manifest.txt" 2>/dev/null), builder $LOGOS_MODULE_BUILDER_REV, $RT"
  echo "-- module files: bytes as built / llvm-strip --strip-unneeded / gzip -6 of the stripped file"
  tot=0; tots=0; totz=0
  for m in blockchain_module bc_probe; do
    for f in "$MODULES_OUT/$m"/*; do
      [ -f "$f" ] || continue
      s=$(stat -c %s "$f")
      case "$f" in
        *.so) ss=$(stripped_size "$f"); sz=$(deflated_size); rm -f "$TMPDIR/strip.$$" ;;
        *) ss=$s; sz=$(gzip -6 -c "$f" | wc -c) ;;
      esac
      tot=$((tot + s)); tots=$((tots + ss)); totz=$((totz + sz))
      printf '   %-44s %10s %10s %10s\n' "$m/$(basename "$f")" "$s" "$ss" "$sz"
      case "$f" in
        *.so) printf '   %-44s NEEDED: %s\n' "" "$(needed_of "$f" | tr '\n' ' ')"
              printf '   %-44s SONAME: %s  RUNPATH: [%s]\n' "" \
                "$("$READELF" -d "$f" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')" "$(runpath_of "$f")" ;;
      esac
    done
  done
  printf '   %-44s %10s %10s %10s\n' "TOTAL" "$tot" "$tots" "$totz"
  for l in "$LIDL_OUT"/blockchain_module.lidl "$LIDL_OUT"/bc_probe.lidl; do
    [ -f "$l" ] || continue
    c=$(lidl_counts "$l")
    echo "-- ${l#"$BUILD_ROOT"/}: ${c% *} methods, ${c#* } events"
  done
} > "$SUMMARY"
cat "$SUMMARY"; [ "$_LOG_TEE" = 1 ] || cat "$SUMMARY" >&3

bash "$SCRIPTS_DIR/check-prefix.sh" "$ABI" "$PREFIX" --modules "$MODULES_OUT" 2>&1 | tee -a "$LOG_FILE" >&3
say "build-blockchain-module: OK ($ABI) in $(( $(date +%s) - T_ALL ))s $(date -Is)"
