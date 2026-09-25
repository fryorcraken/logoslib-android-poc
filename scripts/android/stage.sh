#!/usr/bin/env bash
# scripts/android/stage.sh -- stage the native runtime and the module directories into the
# :logos-core Android library, then check the staged set.
#
# Gradle does not build native code; after this script the library's source sets hold
# everything the APK ships (both destinations are gitignored build artefacts):
#
#   android/logos-core/src/main/jniLibs/<abi>/   (packaged, extracted to nativeLibraryDir)
#     liblogos_jni.so            the JNI shim (build-jni.sh)
#     liblogos_host_qt.so        the module host EXECUTABLE liblogos posix_spawn()s per
#                                module (found through LOGOS_HOST_PATH; needs
#                                useLegacyPackaging so it is extracted and exec'able)
#     + the DT_NEEDED closure of those two and of every module plugin, resolved against the
#       prefix (liblogos_core, liblogos_protocol, liblogos_qt_host, package_manager_lib, lgx,
#       spdlog, fmt, libssl_3/libcrypto_3), the Qt prebuilt (libQt6Core/Network/
#       RemoteObjects_<abi>.so) and the NDK (libc++_shared.so); NDK system libraries
#       (libc, libm, libdl, liblog, libz, libicu, ...) come from the device and are skipped.
#       OpenSSL is always staged: QtNetwork also dlopen()s it by name (libssl_3.so).
#   android/logos-core/src/main/modules-staged/<abi>/modules/<abi>/<module>/
#     an extra asset root per ABI (logos-core/build.gradle.kts adds only the roots of the
#     ABIs in `logos.abis`: abiFilters does not filter assets), packaged as
#     assets/modules/<abi>/<module>/ and dlopen()ed by the module host after extraction:
#     manifest.json, <module>_plugin.so, variant, ... copied from build/android/<abi>/modules
#   .../modules/<abi>/modules.stamp
#     content hash of the staged modules: LogosCore re-extracts them to filesDir/modules on
#     the device whenever it changes. (Not a dot-file: aapt drops those from assets. For the
#     same reason a module directory must not start with "_" or ".".)
#
# Checks (non-zero exit on failure): every NEEDED resolves (NDK system library or staged
# file), then scripts/android/check-prefix.sh on the staged set (jniLibs as the prefix,
# assets as --modules): lib*.so names and SONAMEs, NEEDED, undefined symbols, RUNPATH,
# 16 KB LOAD alignment, ELF machine, no glibc / /nix/store, module manifests.
#
# Inputs
#   build/android/<abi>/jni/liblogos_jni.so        (scripts/android/build-jni.sh)
#   build/android/<abi>/prefix/{lib,bin}           (build-deps.sh + build-runtime.sh)
#   build/android/<abi>/modules/<module>/          (build-runtime.sh)
#   $QT_ROOT/android_<abi>/lib, NDK libc++_shared.so (env.sh)
# Outputs
#   the two directories above (replaced on every run: staging is cheap, stale libraries
#   are not), build/android/<abi>/staged.txt (file list + sizes), build/logs/stage-<abi>.log
# Pinned versions: scripts/android/versions.env via env.sh (NDK r27c, Qt 6.11.1, API 34).
#
# Usage
#   bash scripts/android/stage.sh [x86_64|arm64-v8a] [module ...]
#     module ...   stage only these module directories (default: all under build/.../modules)
#   Environment: ABI, STAGE_STRIP=0 to keep symbols (default 1: llvm-strip --strip-unneeded
#   on the staged copies; the build outputs are never modified), plus everything env.sh reads.
set -euo pipefail

STRIP_LIBS="${STAGE_STRIP:-1}"   # read before env.sh, which sets STRIP to the llvm-strip path
[ "$STRIP_LIBS" = 0 ] || STRIP_LIBS=1
WANT_MODULES=()
while [ $# -gt 0 ]; do
  case "$1" in
    x86_64|arm64-v8a) export ABI=$1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 0 ;;
    -*) echo "stage.sh: unknown option '$1' (see --help)" >&2; exit 2 ;;
    *) WANT_MODULES+=("$1") ;;
  esac
  shift
done
export ABI="${ABI:-x86_64}"
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
log_setup stage
trap 'on_error stage' ERR
export LC_ALL=C

CORE_MAIN="$REPO_ROOT/android/logos-core/src/main"
JNI_DST="$CORE_MAIN/jniLibs/$ABI"
ASSETS_DST="$CORE_MAIN/modules-staged/$ABI/modules/$ABI"
LEGACY_ASSETS="$CORE_MAIN/assets/modules/$ABI"   # pre-modules-staged location; removed
MODULES_SRC="$ANDROID_BUILD/modules"
JNI_SO="$ANDROID_BUILD/jni/liblogos_jni.so"
HOST_EXE="$PREFIX/bin/liblogos_host_qt.so"
[ -f "$HOST_EXE" ] || HOST_EXE=$(find "$PREFIX" -name liblogos_host_qt.so -type f | head -1)

[ -f "$JNI_SO" ] || die "$JNI_SO missing: run scripts/android/build-jni.sh $ABI first"
[ -n "$HOST_EXE" ] && [ -f "$HOST_EXE" ] || die "liblogos_host_qt.so not found under $PREFIX: run scripts/android/build-runtime.sh $ABI first"
[ -d "$MODULES_SRC" ] || die "$MODULES_SRC missing: run scripts/android/build-runtime.sh $ABI first"

step_begin stage

# ---- candidate providers of a NEEDED name (first wins: prefix, then Qt, then NDK c++)
declare -A PROVIDER=() NDK_SYS=()
for f in "$NDK_SYSLIB_DIR"/*.so; do NDK_SYS[$(basename "$f")]=1; done
while IFS= read -r f; do
  n=$(basename "$f")
  [ -n "${PROVIDER[$n]:-}" ] || PROVIDER[$n]=$f
done < <(find "$PREFIX/lib" "$PREFIX/bin" -maxdepth 1 -name 'lib*.so' -type f | sort; \
         find "$QT_ANDROID_PREFIX/lib" -maxdepth 1 -name 'lib*.so' -type f | sort)
PROVIDER[libc++_shared.so]=$LIBCXX_SHARED

needed_of() { "$READELF" -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'; }

# ---- module directories to stage
MODS=()
if [ ${#WANT_MODULES[@]} -gt 0 ]; then
  for m in "${WANT_MODULES[@]}"; do
    [ -d "$MODULES_SRC/$m" ] || die "module $m not built: no $MODULES_SRC/$m"
    MODS+=("$m")
  done
else
  for d in "$MODULES_SRC"/*/; do [ -d "$d" ] && MODS+=("$(basename "$d")"); done
fi
[ ${#MODS[@]} -gt 0 ] || die "no module directories in $MODULES_SRC"
for m in "${MODS[@]}"; do
  case "$m" in _*|.*) die "module directory '$m' starts with '_' or '.': aapt would leave it out of the APK" ;; esac
done
if ! grep -qx capability_module <<< "$(printf '%s\n' "${MODS[@]}")"; then
  say "WARNING: capability_module is not staged; logos_core_start() needs it"
fi

# ---- DT_NEEDED closure from the roots
declare -A STAGE=()        # file name -> source path (goes to jniLibs)
declare -A SEEN=()
queue=("$JNI_SO" "$HOST_EXE")
STAGE[liblogos_jni.so]=$JNI_SO
STAGE[liblogos_host_qt.so]=$HOST_EXE
# QtNetwork dlopen()s OpenSSL by name; stage it even if nothing links it.
for n in "libssl${OPENSSL_SONAME_SUFFIX}.so" "libcrypto${OPENSSL_SONAME_SUFFIX}.so"; do
  if [ -n "${PROVIDER[$n]:-}" ]; then STAGE[$n]=${PROVIDER[$n]}; queue+=("${PROVIDER[$n]}"); fi
done
for m in "${MODS[@]}"; do
  while IFS= read -r f; do queue+=("$f"); done < <(find "$MODULES_SRC/$m" -maxdepth 1 -name '*.so' -type f | sort)
done
missing=()
while [ ${#queue[@]} -gt 0 ]; do
  f=${queue[0]}; queue=("${queue[@]:1}")
  [ -n "${SEEN[$f]:-}" ] && continue
  SEEN[$f]=1
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ -n "${NDK_SYS[$n]:-}" ] && continue                        # provided by the device
    [ -f "$(dirname "$f")/$n" ] && [[ "$f" == "$MODULES_SRC"/* ]] && continue   # module-private dep
    if [ -n "${STAGE[$n]:-}" ]; then continue; fi
    if [ -n "${PROVIDER[$n]:-}" ]; then
      STAGE[$n]=${PROVIDER[$n]}
      queue+=("${PROVIDER[$n]}")
    else
      missing+=("$n (needed by ${f#"$BUILD_ROOT"/})")
    fi
  done < <(needed_of "$f")
done
[ ${#missing[@]} -eq 0 ] || die "unresolvable NEEDED: ${missing[*]}"

# ---- copy (+ strip) the libraries
rm -rf "$JNI_DST"
mkdir -p "$JNI_DST"
: > "$ANDROID_BUILD/staged.txt"
total=0
for n in $(printf '%s\n' "${!STAGE[@]}" | sort); do
  src=${STAGE[$n]}
  cp -f "$src" "$JNI_DST/$n"
  chmod 0755 "$JNI_DST/$n"
  if [ "$STRIP_LIBS" = 1 ]; then "$STRIP" --strip-unneeded "$JNI_DST/$n"; fi
  sz=$(stat -c %s "$JNI_DST/$n")
  total=$((total + sz))
  printf 'jniLibs/%s/%-36s %10d  <- %s\n' "$ABI" "$n" "$sz" "${src#"$REPO_ROOT"/}" | tee -a "$ANDROID_BUILD/staged.txt"
done
say "-- staged ${#STAGE[@]} libraries into ${JNI_DST#"$REPO_ROOT"/} ($total bytes, strip=$STRIP_LIBS)"

# ---- copy (+ strip) the module directories and stamp them
rm -rf "$ASSETS_DST" "$LEGACY_ASSETS"
rmdir "$CORE_MAIN/assets/modules" "$CORE_MAIN/assets" 2>/dev/null || true
mkdir -p "$ASSETS_DST"
for m in "${MODS[@]}"; do
  cp -a "$MODULES_SRC/$m" "$ASSETS_DST/$m"
  chmod -R u+w "$ASSETS_DST/$m"
  if [ "$STRIP_LIBS" = 1 ]; then
    while IFS= read -r f; do "$STRIP" --strip-unneeded "$f"; done < <(find "$ASSETS_DST/$m" -name '*.so' -type f)
  fi
  while IFS= read -r f; do
    printf 'assets/modules/%s/%-40s %10d\n' "$ABI" "${f#"$ASSETS_DST"/}" "$(stat -c %s "$f")" | tee -a "$ANDROID_BUILD/staged.txt"
  done < <(find "$ASSETS_DST/$m" -type f | sort)
done
stamp=$(cd "$ASSETS_DST" && find . -type f ! -name modules.stamp -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
printf '%s\n' "$stamp" > "$ASSETS_DST/modules.stamp"
say "-- staged modules ${MODS[*]} into ${ASSETS_DST#"$REPO_ROOT"/} (stamp $stamp)"

# ---- check the staged set exactly as the device will see it
say "-- check-prefix.sh on the staged set"
if bash "$SCRIPTS_DIR/check-prefix.sh" "$ABI" "$JNI_DST" --modules "$ASSETS_DST"; then
  say "-- check-prefix: OK"
else
  die "check-prefix.sh found violations in the staged set (see $LOG_FILE)"
fi
step_done stage "modules=${MODS[*]} strip=$STRIP_LIBS stamp=$stamp"
say "stage: OK -- ${#STAGE[@]} libraries ($total bytes) + ${#MODS[@]} modules; list in ${ANDROID_BUILD#"$REPO_ROOT"/}/staged.txt"
