# shellcheck shell=bash
# scripts/android/module-build.sh -- build one `interface: "universal"` Logos module for
# Android and stage it as a module directory.
#
# Sourced (after env.sh), never executed, by scripts/android/build-runtime.sh
# (capability_module, hello_module) and scripts/android/build-blockchain-module.sh
# (blockchain_module, bc_probe). It defines:
#   MODULES_OUT   build/android/<abi>/modules      staged module directories
#   MODSRC_DIR    build/android/<abi>/modsrc       per-module source copies + generated_code/
#   LIDL_OUT      build/android/<abi>/lidl         published LIDL contracts, <name>.lidl
#   ROOTS         the Qt-consumer CMake arguments every runtime step and module shares
#                 (all roots are the prefix)
#   LOGOS_MODULE_BUILDER_ROOT (exported)  build/src/logos-module-builder (its LogosModule.cmake)
#   build_universal_module NAME SRCDIR [options]
#
# Modules are built the way logos-module-builder's Nix path builds an
# `interface: "universal"` module, with the steps spelled out (the builder's flake is
# desktop-only):
#   1. copy SRCDIR to MODSRC_DIR/NAME
#   2. logos-cpp-generator --metadata metadata.json --general-only --api-style lp
#        [--dep=<dep>=<dep>.lidl ...]
#      (logos-plugin-qt lib/buildPlugin.nix generationScript): the lp consumer umbrella
#      logos_sdk.{h,cpp}, plus one <dep>_api.{h,cpp} wrapper per concrete dependency,
#      generated from the dependency's published LIDL contract. mkLogosModule passes that
#      contract as `--dep` from the flake input named like the dependency; here it is the
#      dependency's LIDL_OUT/<dep>.lidl. Headers are then moved to generated_code/include.
#   3. stamp logos_protocol_version into metadata.json        (lib/modulePreConfigure.nix)
#   4. logos-cpp-generator --header-to-lidl <impl header>      -> generated_code/NAME.lidl
#      logos-qt-host-generator --lidl ... --backend cdylib      (Qt plugin glue)
#      logos-cpp-generator --lidl ... --backend cdylib          (C-ABI export wrapper)
#                                                              (universalCodegen)
#   5. configure logos-module-builder's cmake/LogosModule.cmake with the Qt/NDK toolchain
#      against the prefix; build NAME_plugin.so
#   6. stage MODULES_OUT/NAME: NAME_plugin.so, the private libraries (--private-lib),
#      manifest.json and variant; publish generated_code/NAME.lidl as LIDL_OUT/NAME.lidl
#      (the builder's `lidl` output, which dependents' step 2 reads).
# The staged manifest.json is the one logos-liblogos nix/modules.nix writes (name, version,
# type core, main keyed by variant) with the keys liblgx reports under bionic ($LGX_VARIANT,
# env.sh), plus metadata.json's `dependencies` when it has any (as lgpm-installed manifests
# carry them; liblogos itself reads the dependency edges from the plugin's embedded
# metadata). A `variant` file is written as lgpm installs write it.
#
# Options of build_universal_module:
#   --dep DEP=LIDL        a concrete dependency's LIDL contract (repeatable), see step 2
#   --private-lib PATH    a shared library the plugin links that ships INSIDE the module
#                         directory (the desktop .lgx layout; repeatable). It is copied next
#                         to the plugin, and the plugin is linked with DT_RUNPATH $ORIGIN so
#                         bionic resolves it there when the module host dlopen()s the plugin
#                         (CMake's Android platform emits no RPATH at all, INSTALL_RPATH
#                         included, so LogosModule.cmake's `$ORIGIN` never reaches the ELF).
#                         The flag goes through a clang response file: a literal `$` in
#                         CMAKE_SHARED_LINKER_FLAGS does not survive the Makefile link step.
#   --ldflags FLAGS       appended to the plugin's link flags (after LDFLAGS_ANDROID)
#   --cmake ARG           an extra CMake argument (repeatable)
# The caller exports anything LogosModule.cmake reads from the environment (e.g.
# LOGOS_EXT_ROOT_<LIB> for EXTERNAL_LIBS).

MODULES_OUT="$ANDROID_BUILD/modules"
MODSRC_DIR="$ANDROID_BUILD/modsrc"
LIDL_OUT="$ANDROID_BUILD/lidl"
mkdir -p "$MODULES_OUT" "$MODSRC_DIR" "$LIDL_OUT"
export LOGOS_MODULE_BUILDER_ROOT="$SRC_ROOT/logos-module-builder"

# Qt-consumer CMake arguments shared by every runtime step and module: all roots are the prefix.
ROOTS=(
  -DBoost_USE_STATIC_LIBS=ON
  -DOPENSSL_ROOT_DIR="$PREFIX"
  -DLOGOS_PROTOCOL_ROOT="$PREFIX"
  -DLOGOS_QT_HOST_ROOT="$PREFIX"
  -DLOGOS_QT_SDK_ROOT="$PREFIX"
  -DLOGOS_CPP_SDK_ROOT="$PREFIX"
  -DLOGOS_CONTAINER_ROOT="$PREFIX"
  -DLOGOS_MODULE_LOADER_ROOT="$PREFIX"
)

# build_universal_module NAME SRCDIR [--dep DEP=LIDL]... [--private-lib PATH]...
#                        [--ldflags FLAGS] [--cmake ARG]...
build_universal_module() {
  local name=$1 src=$2; shift 2
  local deps=() privlibs=() ldflags="" extra_cmake=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dep) deps+=("$2"); shift 2 ;;
      --private-lib) privlibs+=("$2"); shift 2 ;;
      --ldflags) ldflags="$ldflags $2"; shift 2 ;;
      --cmake) extra_cmake+=("$2"); shift 2 ;;
      *) die "build_universal_module: unknown option '$1'" ;;
    esac
  done
  local work="$MODSRC_DIR/$name" b="$OBJ_DIR/module-$name" dst="$MODULES_OUT/$name"
  local d p
  for d in "${deps[@]}"; do
    [ -f "${d#*=}" ] || die "$name: dependency contract ${d#*=} missing (build ${d%%=*} first)"
  done
  for p in "${privlibs[@]}"; do [ -f "$p" ] || die "$name: private library $p missing"; done
  rm -rf "$work" "$b"
  mkdir -p "$work"
  ( cd "$src" && tar --exclude=.git --exclude=./generated_code --exclude=./build --exclude=./result -cf - . ) \
    | ( cd "$work" && tar -xf - )
  local impl_class impl_header version protocol_version
  impl_class=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m.get("codegen",{}).get("impl_class") or "".join(p.capitalize() for p in m["name"].split("_") if p)+"Impl")' "$work/metadata.json")
  impl_header=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m.get("codegen",{}).get("impl_header") or m["name"]+"_impl.h")' "$work/metadata.json")
  version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$work/metadata.json")
  case "$impl_header" in */*) ;; *) impl_header="src/$impl_header" ;; esac
  protocol_version=$(sed -n 's/.*LOGOS_PROTOCOL_VERSION_STRING "\([^"]*\)".*/\1/p' "$PREFIX/include/logos_protocol.h" | head -1)
  [ -n "$protocol_version" ] || die "cannot read LOGOS_PROTOCOL_VERSION_STRING from $PREFIX/include/logos_protocol.h"
  echo "-- $name: impl $impl_class ($impl_header), version $version, protocol $protocol_version"
  [ ${#deps[@]} -eq 0 ] || echo "-- $name: dependency contracts: ${deps[*]}"
  local dep_args=()
  for d in "${deps[@]}"; do dep_args+=("--dep=$d"); done
  (
    cd "$work"
    export PATH="$HOST_PREFIX/bin:$PATH"
    mkdir -p generated_code
    # logos-plugin-qt lib/buildPlugin.nix generationScript (api-style lp: a core universal
    # module): the consumer umbrella + dependency wrappers, then headers moved into
    # generated_code/include.
    logos-cpp-generator --metadata metadata.json --general-only --api-style lp \
      --output-dir ./generated_code "${dep_args[@]}"
    if [ -f generated_code/logos_sdk.h ]; then
      mkdir -p generated_code/include
      mv generated_code/*.h generated_code/include/
      cp generated_code/*.cpp generated_code/include/
    fi
    # logos-module-builder lib/modulePreConfigure.nix: stamp the protocol version, then
    # universalCodegen.
    python3 -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); m["logos_protocol_version"]=sys.argv[2]; open(p,"w").write(json.dumps(m, indent=2)+"\n")' \
      metadata.json "$protocol_version"
    logos-cpp-generator --header-to-lidl "$impl_header" --impl-class "$impl_class" \
      --metadata metadata.json -o "./generated_code/$name.lidl"
    logos-qt-host-generator --lidl "./generated_code/$name.lidl" --backend cdylib --output-dir ./generated_code
    logos-cpp-generator --lidl "./generated_code/$name.lidl" --backend cdylib \
      --impl-class "$impl_class" --impl-header "$(basename "$impl_header")" --output-dir ./generated_code
    echo "-- generated for $name:"; find generated_code -type f | sort
    cat "generated_code/$name.lidl"
  )
  local link_flags="$LDFLAGS_ANDROID$ldflags"
  if [ ${#privlibs[@]} -gt 0 ]; then
    local rsp="$OBJ_DIR/module-$name.rpath.rsp"
    printf '%s\n' '-Wl,-rpath,$ORIGIN' > "$rsp"
    link_flags="$link_flags @$rsp"
  fi
  echo "-- cmake configure module $name (plugin link flags: $link_flags)"
  cmake -S "$work" -B "$b" "${QT_CMAKE_ARGS[@]}" "${ROOTS[@]}" -DLOGOS_MODULE_ROOT="$PREFIX" \
    -DCMAKE_SHARED_LINKER_FLAGS="$link_flags" "${extra_cmake[@]}"
  cmake --build "$b" -j "$JOBS"
  local plugin="$b/modules/${name}_plugin.so"
  [ -f "$plugin" ] || die "$name: no plugin at $plugin"
  rm -rf "$dst"; mkdir -p "$dst"
  cp "$plugin" "$dst/"
  for p in "${privlibs[@]}"; do cp "$p" "$dst/"; chmod 0755 "$dst/$(basename "$p")"; done
  local keys=() a
  for a in $LGX_ARCH_NAMES; do keys+=("$LGX_OS-$a$LGX_DEV_SUFFIX" "$LGX_OS-$a"); done
  python3 - "$dst/manifest.json" "$name" "$version" "${name}_plugin.so" "$work/metadata.json" "${keys[@]}" <<'PY'
import json, sys
path, name, version, plugin, meta, keys = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6:]
main = {}
for k in keys:
    main.setdefault(k, plugin)
doc = {"name": name, "version": version, "type": "core", "main": main}
deps = json.load(open(meta)).get("dependencies") or []
if deps:
    doc["dependencies"] = deps
open(path, "w").write(json.dumps(doc, indent=2) + "\n")
PY
  printf '%s\n' "$LGX_VARIANT" > "$dst/variant"
  cp "$work/generated_code/$name.lidl" "$LIDL_OUT/$name.lidl"
  echo "-- staged $dst:"; ls -la "$dst"; cat "$dst/manifest.json"
  echo "-- published $LIDL_OUT/$name.lidl"
}
