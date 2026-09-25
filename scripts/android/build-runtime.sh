#!/usr/bin/env bash
# scripts/android/build-runtime.sh -- M3: cross-build the Logos runtime (liblogos_core, the
# libraries it links, and the logos_host_qt module host it spawns) for one Android ABI,
# plus the host-side code generators, and stage the capability_module and hello_module
# module directories.
#
# Inputs: the M2 prefix build/android/<abi>/prefix (scripts/android/build-deps.sh) and the
# Qt 6.11.1 prebuilts: android_<abi> (target) and gcc_64 (host moc/repc; see env.sh QT_ROOT).
#
# Output:
#   build/android/<abi>/prefix            the SAME prefix, extended with every component
#                                         below: lib/liblogos_{protocol,qt_host,core}.so,
#                                         bin/liblogos_host_qt.so (the host executable), the
#                                         static libraries, headers and CMake packages
#   build/android/<abi>/extra/logos-module-<rev>  the logos_module static library the host
#                                         links (a second logos-module revision; see below)
#   build/android/<abi>/modules/<name>/   one module directory per module: manifest.json,
#                                         <name>_plugin.so, variant (what liblogos discovers)
#   build/android/<abi>/runtime-summary.txt  sizes (as built / stripped), NEEDED lists and
#                                         the .so files an app ships
#   build/host/prefix/bin/                logos-cpp-generator, logos-qt-host-generator (host)
#   build/logs/build-runtime-<abi>.log    full log
# and it finishes by running scripts/android/check-prefix.sh on the prefix and modules dir.
#
# Built, in dependency order (github.com/logos-co/<repo> at the revisions pinned in
# scripts/android/versions.env: the logos-liblogos db45024 closure; short revs below):
#   gen          HOST, once for all ABIs: logos-lidl 9df8e00 (LIDL frontend),
#                logos-cpp-generator (logos-cpp-sdk/cpp-generator) and logos-qt-host-generator
#                (logos-plugin-qt/qt-host-generator), with the host compiler against the
#                gcc_64 Qt and a host nlohmann_json 3.11.3. These are the two generators a
#                universal core module without dependencies needs.
#   cppsdk       logos-cpp-sdk 3f34c0b: header-only SDK + CMake package (+ include/cpp/
#                copies, the layout its nix include output ships and LogosModule.cmake probes)
#   protocol     logos-protocol 8bbc027 (0.9.0): liblogos_protocol.so (the one in-process
#                copy of the transport/token runtime) + liblogos_protocol.a (plugins, host);
#                headers also in include/cpp/ (the nix source-export layout)
#   qthost       logos-plugin-qt 3a471be: liblogos_qt_host.so + .a (LogosAPI, provider glue)
#   qtsdk        logos-qt-sdk 03e489b: CMake package (INTERFACE targets) + its three headers
#   module       logos-module f71d16d (static; links liblgx): what liblogos_core links
#   modulehost   logos-module 9812dc8 (static, pre-lgx) into extra/: what
#                logos-module-loader-qt's own lock builds logos_host_qt against
#   procstats    process-stats 6e0aade (static)
#   container    logos-container 641d211 (headers)   + patches/logos-container/*test-gate*
#   subprocess   logos-container-subprocess 697c180 (static) + patches/logos-container-subprocess/*
#   loader       logos-module-loader 3628b97 (headers) + patches/logos-module-loader/*
#   loaderqt     logos-module-loader-qt 888da92: the parent-side loader library (static,
#                linked into liblogos_core) and logos_host_qt, installed as
#                bin/liblogos_host_qt.so. patches/logos-module-loader-qt: test-gate,
#                android-nojvm-shim, A (backtrace guard; inert at API >= 33), B (lib*.so name
#                + $ORIGIN runpath), C (find the host next to the loader library, i.e. in
#                nativeLibraryDir).
#   liblogos     logos-liblogos db45024: liblogos_core.so (LOGOS_BUILD_TESTS=OFF, every
#                -D*_ROOT is the prefix; the container/loader implementations via find_package)
#   capability   logos-capability-module 1a1b8b5 (1.0.0), built with logos-module-builder
#                de169fd -> modules/capability_module
#   hello        modules/hello_module (this repo), same builder -> modules/hello_module
# Boost is linked statically everywhere (Boost_USE_STATIC_LIBS=ON), so no libboost_*.so
# ships. OpenSSL, spdlog/fmt, liblgx and package_manager_lib are the M2 shared libraries.
#
# Modules are built the way logos-module-builder's Nix path builds an
# `interface: "universal"` module (code generators on the host, then LogosModule.cmake with
# the Qt/NDK toolchain against the prefix); the steps and the staged layout are
# build_universal_module in scripts/android/module-build.sh, which
# scripts/android/build-blockchain-module.sh (blockchain_module, bc_probe) shares.
#
# Usage:
#   bash scripts/android/build-runtime.sh [x86_64|arm64-v8a] [STEP...]
#     STEP: gen cppsdk protocol qthost qtsdk module modulehost procstats container
#           subprocess loader loaderqt liblogos capability hello (default: all, in order)
#   Environment: see scripts/android/env.sh (ABI, JOBS, FORCE=1 rebuilds steps that are up
#   to date, LOGOS_SRC_MIRROR for local git mirrors, QT_ROOT).
#
# Re-runnable: each step records a stamp keyed on its revision and patches plus the whole
# runtime closure (every Logos pin, runtime patch, Qt and M2 version), and is skipped while
# the stamp matches and its main output exists. Sources are shared by both ABIs (build/src).
#
# Needs: the M2 prefix, Qt 6.11.1 android_<abi> + gcc_64, a host C++17 compiler, cmake,
# make, python3, git. Network: GitHub (first run only; LOGOS_SRC_MIRROR can serve the repos).
set -Eeuo pipefail   # -E: the ERR trap (log tail on failure) also fires inside functions

ALL_STEPS=(gen cppsdk protocol qthost qtsdk module modulehost procstats container subprocess
           loader loaderqt liblogos capability hello)
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

# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
log_setup build-runtime
trap 'on_error build-runtime' ERR
check_host_tools
for t in c++ python3; do command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"; done
[ -f "$QT_TOOLCHAIN_FILE" ] || die "no target Qt at $QT_ANDROID_PREFIX (QT_ROOT=$QT_ROOT)"
[ -x "$QT_HOST_PREFIX/libexec/moc" ] || die "no host Qt at $QT_HOST_PREFIX (QT_ROOT=$QT_ROOT)"
[ -f "$PREFIX/lib/liblgx.so" ] && [ -f "$PREFIX/lib/libpackage_manager_lib.so" ] \
  || die "the M2 prefix is incomplete: run scripts/android/build-deps.sh $ABI first"

# shellcheck source=module-build.sh
source "$SCRIPTS_DIR/module-build.sh"   # MODULES_OUT, MODSRC_DIR, ROOTS, build_universal_module
EXTRA_MODULE_PREFIX="$ANDROID_BUILD/extra/logos-module-${LOGOS_MODULE_REV_LOADER_QT:0:7}"
HOST_STAMP_DIR="$HOST_BUILD/stamps"
mkdir -p "$HOST_PREFIX" "$HOST_OBJ_DIR" "$HOST_STAMP_DIR"

say "prefix: $PREFIX"
say "steps: ${STEPS[*]}   jobs: $JOBS   force: $FORCE"
echo "qt: target $QT_ANDROID_PREFIX, host $QT_HOST_PREFIX"
echo "host c++: $(c++ --version | head -1)"

# ---- patches and the runtime key ---------------------------------------------------------
P_CONTAINER=("$PATCHES_DIR"/logos-container/logos-container-test-gate.diff)
P_SUBPROCESS=("$PATCHES_DIR"/logos-container-subprocess/logos-container-subprocess-test-gate.diff)
P_LOADER=("$PATCHES_DIR"/logos-module-loader/logos-module-loader-test-gate.diff)
P_LOADERQT=(
  "$PATCHES_DIR"/logos-module-loader-qt/logos-module-loader-qt-test-gate.diff
  "$PATCHES_DIR"/logos-module-loader-qt/logos-module-loader-qt-android-nojvm-shim.patch
  "$PATCHES_DIR"/logos-module-loader-qt/logos-module-loader-qt-A-host-backtrace-api33.diff
  "$PATCHES_DIR"/logos-module-loader-qt/logos-module-loader-qt-B-host-android-name-rpath.diff
  "$PATCHES_DIR"/logos-module-loader-qt/logos-module-loader-qt-C-loader-android-host-discovery.diff
)
# Any change to a pin, a runtime patch, Qt or an M2 library rebuilds every runtime step:
# they are all compiled against each other's headers and linked into the same processes.
RT_KEY_TEXT="qt=$QT_VERSION boost=$BOOST_VERSION openssl=$OPENSSL_VERSION fmt=$FMT_VERSION
spdlog=$SPDLOG_VERSION json=$NLOHMANN_JSON_VERSION cli11=$CLI11_VERSION lgx=$LOGOS_PACKAGE_REV
lpm=$LOGOS_PACKAGE_MANAGER_REV lgxpatch=$LGX_ANDROID_VARIANT_PATCH portable=$LGPM_PORTABLE_BUILD
protocol=$LOGOS_PROTOCOL_REV plugin-qt=$LOGOS_PLUGIN_QT_REV qt-sdk=$LOGOS_QT_SDK_REV
cpp-sdk=$LOGOS_CPP_SDK_REV module=$LOGOS_MODULE_REV module-host=$LOGOS_MODULE_REV_LOADER_QT
process-stats=$PROCESS_STATS_REV container=$LOGOS_CONTAINER_REV
subprocess=$LOGOS_CONTAINER_SUBPROCESS_REV loader=$LOGOS_MODULE_LOADER_REV
loader-qt=$LOGOS_MODULE_LOADER_QT_REV liblogos=$LOGOS_LIBLOGOS_REV
patches=$(patch_key "${P_CONTAINER[@]}" "${P_SUBPROCESS[@]}" "${P_LOADER[@]}" "${P_LOADERQT[@]}")"
RT_KEY="rt=$(printf '%s' "$RT_KEY_TEXT" | sha256sum | cut -c1-16)"
echo "runtime key $RT_KEY:"; printf '%s\n' "$RT_KEY_TEXT"

# host_step: step bookkeeping for the ABI-independent host tools (own stamp dir, a key
# without the target ABI, so building the other ABI reuses them).
host_step_should_skip() {
  local STAMP_DIR="$HOST_STAMP_DIR" STAMP_COMMON="host $(c++ --version | head -1)"
  step_should_skip "$@"
}
host_step_done() {
  local STAMP_DIR="$HOST_STAMP_DIR" STAMP_COMMON="host $(c++ --version | head -1)" TIMINGS="$HOST_BUILD/timings.tsv"
  step_done "$@"
}

# ------------------------------------------------------------------------------------
step_gen() {
  local key="lidl=$LOGOS_LIDL_REV cpp-sdk=$LOGOS_CPP_SDK_REV plugin-qt=$LOGOS_PLUGIN_QT_REV protocol=$LOGOS_PROTOCOL_REV json=$NLOHMANN_JSON_VERSION qt=$QT_VERSION"
  host_step_should_skip gen "$key" "$HOST_PREFIX/bin/logos-qt-host-generator" && return 0
  step_begin gen
  fetch_git logos-lidl "$LOGOS_LIDL_REV" logos-co
  fetch_git logos-cpp-sdk "$LOGOS_CPP_SDK_REV" logos-co
  fetch_git logos-plugin-qt "$LOGOS_PLUGIN_QT_REV" logos-co
  fetch_git logos-protocol "$LOGOS_PROTOCOL_REV" logos-co
  fetch_url "$NLOHMANN_JSON_URL" "json-$NLOHMANN_JSON_VERSION.tar.gz" "$NLOHMANN_JSON_SHA256"
  prepare_tarball_src "json-$NLOHMANN_JSON_VERSION" "json-$NLOHMANN_JSON_VERSION.tar.gz"
  # Plain host CMake: the host compiler (the NDK toolchain variables of env.sh are not
  # exported), the desktop Qt, and an RPATH to it so the generators run in place.
  local host_args=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER="$(command -v cc)" -DCMAKE_CXX_COMPILER="$(command -v c++)"
    -DCMAKE_INSTALL_PREFIX="$HOST_PREFIX"
    -DCMAKE_PREFIX_PATH="$QT_HOST_PREFIX;$HOST_PREFIX"
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON
  )
  local b
  b="$HOST_OBJ_DIR/json"; rm -rf "$b"
  cmake -S "$SRC_ROOT/json-$NLOHMANN_JSON_VERSION" -B "$b" "${host_args[@]}" -DJSON_BuildTests=OFF -DJSON_Install=ON
  cmake --build "$b" -j "$JOBS"; cmake --install "$b"
  b="$HOST_OBJ_DIR/lidl"; rm -rf "$b"
  cmake -S "$SRC_ROOT/logos-lidl" -B "$b" "${host_args[@]}" -DLOGOS_LIDL_BUILD_TESTS=OFF
  cmake --build "$b" -j "$JOBS"; cmake --install "$b"
  # cpp-generator has no install rule (its nix bin.nix copies the binary): copy it.
  b="$HOST_OBJ_DIR/cpp-generator"; rm -rf "$b"
  cmake -S "$SRC_ROOT/logos-cpp-sdk/cpp-generator" -B "$b" "${host_args[@]}" \
    -DLOGOS_PROTOCOL_ROOT="$SRC_ROOT/logos-protocol"
  cmake --build "$b" -j "$JOBS" --target logos-cpp-generator
  mkdir -p "$HOST_PREFIX/bin"
  cp "$b/bin/logos-cpp-generator" "$HOST_PREFIX/bin/"
  b="$HOST_OBJ_DIR/qt-host-generator"; rm -rf "$b"
  cmake -S "$SRC_ROOT/logos-plugin-qt/qt-host-generator" -B "$b" "${host_args[@]}"
  cmake --build "$b" -j "$JOBS"; cmake --install "$b"
  # Smoke: both generators run on this host (a missing Qt/ICU library shows up here).
  local t="$HOST_OBJ_DIR/smoke"; rm -rf "$t"; mkdir -p "$t"
  printf '%s\n' '{"name":"gen_smoke","version":"0.0.1","type":"core","interface":"universal","dependencies":[]}' > "$t/metadata.json"
  printf '%s\n' '#pragma once' '#include <string>' '#include <logos_module_context.h>' \
    'class GenSmokeImpl : public LogosModuleContext {' 'public:' '    std::string ping();' '};' > "$t/gen_smoke_impl.h"
  "$HOST_PREFIX/bin/logos-cpp-generator" --header-to-lidl "$t/gen_smoke_impl.h" --impl-class GenSmokeImpl \
    --metadata "$t/metadata.json" -o "$t/gen_smoke.lidl"
  "$HOST_PREFIX/bin/logos-qt-host-generator" --lidl "$t/gen_smoke.lidl" --backend cdylib --output-dir "$t/out"
  cat "$t/gen_smoke.lidl"; ls -la "$t/out"
  host_step_done gen "$key"
}

step_cppsdk() {
  local key="cpp-sdk $LOGOS_CPP_SDK_REV $RT_KEY"
  step_should_skip cppsdk "$key" "$PREFIX/include/cpp/logos_module_context.h" && return 0
  step_begin cppsdk
  fetch_git logos-cpp-sdk "$LOGOS_CPP_SDK_REV" logos-co
  local src="$SRC_ROOT/logos-cpp-sdk"
  ndk_cmake_build cppsdk "$src/cpp"
  # nix/include.nix: every std header also under include/cpp/ (logos_lp_client.h must sit
  # beside what it includes; LogosModule.cmake probes include/cpp/logos_module_context.h).
  mkdir -p "$PREFIX/include/cpp"
  local h
  for h in logos_module_context.h logos_json.h logos_result.h logos_caller.h logos_lp_client.h \
           logos_async_result.h logos_host_services.h logos_host_core.h; do
    cp "$src/cpp/$h" "$PREFIX/include/cpp/"
  done
  step_done cppsdk "$key"
}

step_protocol() {
  local key="protocol $LOGOS_PROTOCOL_REV $RT_KEY"
  step_should_skip protocol "$key" "$PREFIX/lib/liblogos_protocol.so" && return 0
  step_begin protocol
  fetch_git logos-protocol "$LOGOS_PROTOCOL_REV" logos-co
  local src="$SRC_ROOT/logos-protocol"
  qt_cmake_build protocol "$src/cpp" "${ROOTS[@]}"
  # nix/include.nix source-export layout (headers only): include/cpp/**.h.
  local d f
  for d in "" implementations/qt_local implementations/qt_remote implementations/mock implementations/plain; do
    mkdir -p "$PREFIX/include/cpp/$d"
    for f in "$src/cpp/$d"/*.h; do cp "$f" "$PREFIX/include/cpp/$d/"; done
  done
  step_done protocol "$key"
}

step_qthost() {
  local key="plugin-qt $LOGOS_PLUGIN_QT_REV $RT_KEY"
  step_should_skip qthost "$key" "$PREFIX/lib/liblogos_qt_host.so" && return 0
  step_begin qthost
  fetch_git logos-plugin-qt "$LOGOS_PLUGIN_QT_REV" logos-co
  qt_cmake_build qthost "$SRC_ROOT/logos-plugin-qt/cpp" "${ROOTS[@]}"
  step_done qthost "$key"
}

step_qtsdk() {
  local key="qt-sdk $LOGOS_QT_SDK_REV $RT_KEY"
  step_should_skip qtsdk "$key" "$PREFIX/include/cpp/logos_qt_wire.h" && return 0
  step_begin qtsdk
  fetch_git logos-qt-sdk "$LOGOS_QT_SDK_REV" logos-co
  local src="$SRC_ROOT/logos-qt-sdk"
  qt_cmake_build qtsdk "$src/cpp" "${ROOTS[@]}"
  mkdir -p "$PREFIX/include/cpp"
  cp "$src"/cpp/*.h "$PREFIX/include/cpp/"      # nix/include.nix: its own three headers
  step_done qtsdk "$key"
}

step_module() {
  local key="logos-module $LOGOS_MODULE_REV $RT_KEY"
  step_should_skip module "$key" "$PREFIX/lib/liblogos_module.a" && return 0
  step_begin module
  fetch_git logos-module "$LOGOS_MODULE_REV" logos-co
  qt_cmake_build module "$SRC_ROOT/logos-module" "${ROOTS[@]}" \
    -DLOGOS_PACKAGE_ROOT="$PREFIX" -DLOGOS_MODULE_BUILD_TESTS=OFF
  step_done module "$key"
}

step_modulehost() {
  local rev=$LOGOS_MODULE_REV_LOADER_QT
  local key="logos-module $rev $RT_KEY"
  step_should_skip modulehost "$key" "$EXTRA_MODULE_PREFIX/lib/liblogos_module.a" && return 0
  step_begin modulehost
  FETCH_AS="logos-module@${rev:0:7}" fetch_git logos-module "$rev" logos-co
  rm -rf "$EXTRA_MODULE_PREFIX"
  qt_cmake_build modulehost "$SRC_ROOT/logos-module@${rev:0:7}" "${ROOTS[@]}" \
    -DLOGOS_MODULE_BUILD_TESTS=OFF -DCMAKE_INSTALL_PREFIX="$EXTRA_MODULE_PREFIX"
  step_done modulehost "$key"
}

step_procstats() {
  local key="process-stats $PROCESS_STATS_REV $RT_KEY"
  step_should_skip procstats "$key" "$PREFIX/lib/libprocess_stats.a" && return 0
  step_begin procstats
  fetch_git process-stats "$PROCESS_STATS_REV" logos-co
  ndk_cmake_build procstats "$SRC_ROOT/process-stats" -DPROCESS_STATS_BUILD_TESTS=OFF
  step_done procstats "$key"
}

step_container() {
  local key="logos-container $LOGOS_CONTAINER_REV $RT_KEY"
  step_should_skip container "$key" "$PREFIX/include/logos_container/module_container.h" && return 0
  step_begin container
  fetch_git logos-container "$LOGOS_CONTAINER_REV" logos-co "${P_CONTAINER[@]}"
  ndk_cmake_build container "$SRC_ROOT/logos-container" -DLOGOS_CONTAINER_BUILD_TESTS=OFF
  step_done container "$key"
}

step_subprocess() {
  local key="logos-container-subprocess $LOGOS_CONTAINER_SUBPROCESS_REV $RT_KEY"
  step_should_skip subprocess "$key" "$PREFIX/lib/liblogos_container_subprocess.a" && return 0
  step_begin subprocess
  fetch_git logos-container-subprocess "$LOGOS_CONTAINER_SUBPROCESS_REV" logos-co "${P_SUBPROCESS[@]}"
  ndk_cmake_build subprocess "$SRC_ROOT/logos-container-subprocess" \
    -DLOGOS_CONTAINER_SUBPROCESS_BUILD_TESTS=OFF -DLOGOS_CONTAINER_ROOT="$PREFIX" -DBoost_USE_STATIC_LIBS=ON
  step_done subprocess "$key"
}

step_loader() {
  local key="logos-module-loader $LOGOS_MODULE_LOADER_REV $RT_KEY"
  step_should_skip loader "$key" "$PREFIX/include/logos_module_loader/module_format_loader.h" && return 0
  step_begin loader
  fetch_git logos-module-loader "$LOGOS_MODULE_LOADER_REV" logos-co "${P_LOADER[@]}"
  ndk_cmake_build loader "$SRC_ROOT/logos-module-loader" \
    -DLOGOS_MODULE_LOADER_BUILD_TESTS=OFF -DLOGOS_CONTAINER_ROOT="$PREFIX"
  step_done loader "$key"
}

step_loaderqt() {
  local key="logos-module-loader-qt $LOGOS_MODULE_LOADER_QT_REV $RT_KEY"
  step_should_skip loaderqt "$key" "$PREFIX/bin/liblogos_host_qt.so" && return 0
  step_begin loaderqt
  fetch_git logos-module-loader-qt "$LOGOS_MODULE_LOADER_QT_REV" logos-co "${P_LOADERQT[@]}"
  # The host's logos_module lives outside $PREFIX: add it to the find root, or the NDK
  # toolchain's ONLY find mode re-roots its find_library() path under $PREFIX.
  qt_cmake_build loaderqt "$SRC_ROOT/logos-module-loader-qt" "${ROOTS[@]}" \
    -DCMAKE_FIND_ROOT_PATH="$PREFIX;$EXTRA_MODULE_PREFIX" \
    -DLOGOS_MODULE_ROOT="$EXTRA_MODULE_PREFIX" -DLOGOS_MODULE_LOADER_QT_BUILD_TESTS=OFF
  # Upstream installs a logos_host -> logos_host_qt compatibility symlink, which dangles
  # once the host is named liblogos_host_qt.so (patch B); nothing on Android uses it.
  rm -f "$PREFIX/bin/logos_host"
  step_done loaderqt "$key"
}

step_liblogos() {
  local key="logos-liblogos $LOGOS_LIBLOGOS_REV $RT_KEY"
  step_should_skip liblogos "$key" "$PREFIX/lib/liblogos_core.so" && return 0
  step_begin liblogos
  fetch_git logos-liblogos "$LOGOS_LIBLOGOS_REV" logos-co
  qt_cmake_build liblogos "$SRC_ROOT/logos-liblogos" "${ROOTS[@]}" \
    -DLOGOS_BUILD_TESTS=OFF \
    -DLOGOS_MODULE_ROOT="$PREFIX" -DPROCESS_STATS_ROOT="$PREFIX" \
    -DLOGOS_PACKAGE_MANAGER_ROOT="$PREFIX"
  step_done liblogos "$key"
}

step_capability() {
  local key="logos-capability-module $LOGOS_CAPABILITY_MODULE_REV builder=$LOGOS_MODULE_BUILDER_REV variant=$LGX_VARIANT $RT_KEY"
  step_should_skip capability "$key" "$MODULES_OUT/capability_module/capability_module_plugin.so" && return 0
  step_begin capability
  fetch_git logos-capability-module "$LOGOS_CAPABILITY_MODULE_REV" logos-co
  fetch_git logos-module-builder "$LOGOS_MODULE_BUILDER_REV" logos-co
  build_universal_module capability_module "$SRC_ROOT/logos-capability-module"
  step_done capability "$key"
}

step_hello() {
  local src="$REPO_ROOT/modules/hello_module"
  local srchash; srchash=$(cd "$src" && find . -type f -not -path './generated_code/*' | sort | xargs sha256sum | sha256sum | cut -c1-16)
  local key="hello_module src=$srchash builder=$LOGOS_MODULE_BUILDER_REV variant=$LGX_VARIANT $RT_KEY"
  step_should_skip hello "$key" "$MODULES_OUT/hello_module/hello_module_plugin.so" && return 0
  step_begin hello
  fetch_git logos-module-builder "$LOGOS_MODULE_BUILDER_REV" logos-co
  build_universal_module hello_module "$src"
  step_done hello "$key"
}

# ------------------------------------------------------------------------------------
T_ALL=$(date +%s)
for s in "${STEPS[@]}"; do "step_$s"; done

# Provenance manifest: what the runtime was built from.
MANIFEST_DIR="$PREFIX/share/logos-android"
mkdir -p "$MANIFEST_DIR"
{
  echo "# runtime in build/android/$ABI -- written by scripts/android/build-runtime.sh $(date -Is)"
  echo "abi=$ABI api=$ANDROID_API ndk=$NDK_VERSION qt=$QT_VERSION module-variant=$LGX_VARIANT $RT_KEY"
  printf '%s\n' "$RT_KEY_TEXT"
  echo "capability-module=$LOGOS_CAPABILITY_MODULE_REV module-builder=$LOGOS_MODULE_BUILDER_REV lidl=$LOGOS_LIDL_REV"
} > "$MANIFEST_DIR/runtime-manifest.txt"

# The .so files an app ships: the NEEDED closure of liblogos_core, the host and every
# module .so, over the prefix, Qt and libc++_shared (NDK system libraries excluded). A
# module's NEEDED that is a file of the same module directory (a module-private library,
# e.g. blockchain_module's liblogos_blockchain.so) ships there, not in jniLibs, as stage.sh does.
declare -A SHIP=() SHIPPATH=()
ship_lookup() { # NEEDED name -> path of the file an APK would carry, or empty (NDK lib)
  local n=$1
  if [ -f "$PREFIX/lib/$n" ] && [ ! -L "$PREFIX/lib/$n" ]; then echo "$PREFIX/lib/$n"
  elif [ -f "$QT_ANDROID_PREFIX/lib/$n" ]; then echo "$QT_ANDROID_PREFIX/lib/$n"
  elif [ "$n" = libc++_shared.so ]; then echo "$LIBCXX_SHARED"
  fi
}
ship_walk() {
  local f=$1 n p
  while IFS= read -r n; do
    [ -n "${SHIP[$n]:-}" ] && continue
    [[ "$f" == "$MODULES_OUT"/* ]] && [ -f "$(dirname "$f")/$n" ] && continue
    p=$(ship_lookup "$n")
    [ -n "$p" ] || continue
    SHIP[$n]=1; SHIPPATH[$n]=$p
    ship_walk "$p"
  done < <("$READELF" -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
}
ROOT_FILES=()
[ -f "$PREFIX/lib/liblogos_core.so" ] && ROOT_FILES+=("$PREFIX/lib/liblogos_core.so")
[ -f "$PREFIX/bin/liblogos_host_qt.so" ] && ROOT_FILES+=("$PREFIX/bin/liblogos_host_qt.so")
for f in "$MODULES_OUT"/*/*.so; do [ -f "$f" ] && ROOT_FILES+=("$f"); done
for f in "${ROOT_FILES[@]}"; do
  n=$(basename "$f")
  case "$f" in "$MODULES_OUT"/*) ;; *) SHIP[$n]=1; SHIPPATH[$n]=$f ;; esac
  ship_walk "$f"
done

stripped_size() { "$STRIP" --strip-unneeded -o "$TMPDIR/strip.$$" "$1"; stat -c %s "$TMPDIR/strip.$$"; rm -f "$TMPDIR/strip.$$"; }
needed_list() { "$READELF" -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' '; }
SUMMARY="$ANDROID_BUILD/runtime-summary.txt"
{
  echo "################ runtime summary ($ABI) $(date -Is)"
  echo "-- this run: $(( $(date +%s) - T_ALL ))s; per-step wall times (latest run of each; gen is host-wide):"
  { for t in "$TIMINGS" "$HOST_BUILD/timings.tsv"; do [ ! -f "$t" ] || cat "$t"; done; } \
    | awk -F'\t' '{t[$1]=$2; d[$1]=$3} END {for (k in t) printf "   %-11s %5ss  (%s)\n", k, t[k], d[k]}' | sort
  echo "-- jniLibs/$ABI: the .so files an app ships (bytes as built / llvm-strip --strip-unneeded) and NEEDED:"
  tot=0; tots=0
  for n in $(printf '%s\n' "${!SHIP[@]}" | sort); do
    p=${SHIPPATH[$n]}; s=$(stat -c %s "$p"); ss=$(stripped_size "$p"); tot=$((tot + s)); tots=$((tots + ss))
    printf '   %-36s %10s %10s  %s\n' "$n" "$s" "$ss" "${p#"$BUILD_ROOT"/}"
    printf '   %-36s NEEDED: %s\n' "" "$(needed_list "$p")"
  done
  printf '   %-36s %10s %10s  (%d files)\n' "TOTAL" "$tot" "$tots" "${#SHIP[@]}"
  echo "-- modules (assets/modules/<name>/, dlopen()ed by path in the host process):"
  for f in "$MODULES_OUT"/*/*.so; do
    [ -f "$f" ] || continue
    printf '   %-36s %10s %10s  NEEDED: %s\n' "${f#"$MODULES_OUT"/}" "$(stat -c %s "$f")" "$(stripped_size "$f")" "$(needed_list "$f")"
  done
  echo "-- prefix: $(du -sh "$PREFIX" | cut -f1); modules: $(du -sh "$MODULES_OUT" | cut -f1)"
} > "$SUMMARY"
cat "$SUMMARY"; [ "$_LOG_TEE" = 1 ] || cat "$SUMMARY" >&3

bash "$SCRIPTS_DIR/check-prefix.sh" "$ABI" "$PREFIX" --modules "$MODULES_OUT" 2>&1 | tee -a "$LOG_FILE" >&3
say "build-runtime: OK ($ABI) $(date -Is)"
