#!/usr/bin/env bash
# scripts/android/build-apk.sh -- assemble the demo APK and the M4 instrumented-test APK with
# Gradle, check that the native runtime and the modules are inside, and report the sizes.
#
# Gradle builds only Kotlin/Java and packaging; the native code must already be staged into
# :logos-core by scripts/android/build-jni.sh + scripts/android/stage.sh. This script
# refuses to report success for an APK without the runtime (Gradle alone would happily
# build one: LogosCore.start() then fails at run time with "native runtime not packaged").
#
# Inputs
#   android/                                         the Gradle project (:logos-core, :demo-app)
#   android/logos-core/src/main/jniLibs/<abi>/       stage.sh (15 libraries for x86_64)
#   android/logos-core/src/main/modules-staged/<abi>/  stage.sh (module directories)
#   JDK 17+ (env.sh JAVA_HOME, default /usr/lib/jvm/java-21-openjdk: /usr/bin/java on this
#   host is a JRE-only JDK 25), Android SDK (env.sh ANDROID_SDK_ROOT). Gradle 9.7.1 comes
#   from the wrapper (downloaded to ~/.gradle on first use), AGP 9.4.0 and the AndroidX
#   dependencies from Google Maven / Maven Central.
# Outputs
#   android/demo-app/build/outputs/apk/debug/demo-app-debug.apk
#   android/demo-app/build/outputs/apk/androidTest/debug/demo-app-debug-androidTest.apk
#   build/android/<abi>/apk-sizes.txt   total APK size + every lib/ and assets/modules/ entry
#                                       (uncompressed and stored sizes, from unzip -v)
#   build/logs/build-apk-<abi>.log      full Gradle log
# Pinned versions: android/gradle/libs.versions.toml (AGP 9.4.0, Kotlin 2.4.20, Compose BOM
#   2026.09.00, minSdk 34 / targetSdk 36 / compileSdk 37) and
#   android/gradle/wrapper/gradle-wrapper.properties (Gradle 9.7.1).
#
# Usage
#   bash scripts/android/build-apk.sh [x86_64|arm64-v8a] [--unit-tests]
#     --unit-tests   also run :logos-core:testDebugUnitTest (JVM tests, no device)
#   Environment: ABI (packaged ABIs = -Plogos.abis=$ABI), GRADLE_ARGS (extra arguments),
#   plus everything env.sh reads.
# Re-runnable: Gradle is incremental; a second run with nothing changed takes ~20 s
# (--no-daemon start-up), and FORCE=1 adds `clean`.
set -Eeuo pipefail

UNIT_TESTS=0
while [ $# -gt 0 ]; do
  case "$1" in
    x86_64|arm64-v8a) export ABI=$1 ;;
    --unit-tests) UNIT_TESTS=1 ;;
    -h|--help) sed -n '2,/^set -Eeuo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 0 ;;
    *) echo "build-apk.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done
export ABI="${ABI:-x86_64}"
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
log_setup build-apk
trap 'on_error build-apk' ERR
export LC_ALL=C
export ANDROID_HOME="$ANDROID_SDK_ROOT"

A="$REPO_ROOT/android"
CORE_MAIN="$A/logos-core/src/main"
APK="$A/demo-app/build/outputs/apk/debug/demo-app-debug.apk"
TEST_APK="$A/demo-app/build/outputs/apk/androidTest/debug/demo-app-debug-androidTest.apk"
SIZES="$ANDROID_BUILD/apk-sizes.txt"

[ -x "$JAVA_HOME/bin/javac" ] || die "JAVA_HOME=$JAVA_HOME is not a JDK (no bin/javac)"
[ -f "$CORE_MAIN/jniLibs/$ABI/liblogos_jni.so" ] || die "nothing staged for $ABI: run scripts/android/build-jni.sh $ABI and scripts/android/stage.sh $ABI first"
[ -f "$CORE_MAIN/modules-staged/$ABI/modules/$ABI/modules.stamp" ] || die "no staged modules for $ABI: run scripts/android/stage.sh $ABI first"

step_begin "gradle assemble"
tasks=()
[ "${FORCE:-0}" = 1 ] && tasks+=(clean)
tasks+=(:demo-app:assembleDebug :demo-app:assembleDebugAndroidTest)
[ "$UNIT_TESTS" = 1 ] && tasks+=(:logos-core:testDebugUnitTest)
# shellcheck disable=SC2206
extra=(${GRADLE_ARGS:-})
say "-- gradlew ${tasks[*]} -Plogos.abis=$ABI (JAVA_HOME=$JAVA_HOME)"
"$A/gradlew" -p "$A" --no-daemon --console=plain -Plogos.abis="$ABI" "${extra[@]}" "${tasks[@]}"
[ -f "$APK" ] && [ -f "$TEST_APK" ] || die "Gradle finished but $APK / $TEST_APK is missing"
if [ "$UNIT_TESTS" = 1 ]; then
  for r in "$A"/logos-core/build/test-results/testDebugUnitTest/*.xml; do
    [ -f "$r" ] && say "-- $(grep -o '<testsuite [^>]*>' "$r" | sed 's/ timestamp=.*//; s/<testsuite //')"
  done
fi

# ---- what the APK carries: the runtime and the modules must be inside
listing=$(unzip -v "$APK")
for need in "lib/$ABI/liblogos_jni.so" "lib/$ABI/liblogos_host_qt.so" "lib/$ABI/liblogos_core.so" \
            "lib/$ABI/libQt6Core_$ABI.so" "assets/modules/$ABI/modules.stamp" \
            "assets/modules/$ABI/capability_module/manifest.json"; do
  grep -q " $need\$" <<< "$listing" || die "$APK lacks $need"
done
other_abis=$(awk '$8 ~ /^lib\// {split($8, p, "/"); print p[2]}' <<< "$listing" | sort -u | grep -vx "$ABI" || true)
[ -z "$other_abis" ] || say "-- note: the APK also carries lib/ for: $other_abis"
aapt2=$(ls -d "$ANDROID_SDK_ROOT"/build-tools/*/aapt2 | sort -V | tail -1)
manifest=$("$aapt2" dump xmltree --file AndroidManifest.xml "$APK")
grep -q 'extractNativeLibs.*=false' <<< "$manifest" && die "extractNativeLibs=false: liblogos_host_qt.so would not be exec'able (useLegacyPackaging must be true)"

# ---- size report
{
  echo "# APK size report ($ABI), $(date -Is)"
  printf '%-58s %12s\n' "$(basename "$APK")" "$(stat -c %s "$APK")"
  printf '%-58s %12s\n' "$(basename "$TEST_APK")" "$(stat -c %s "$TEST_APK")"
  echo
  echo "# unzip -v: uncompressed bytes, stored bytes, method, entry"
  printf '%12s %12s  %-6s %s\n' length stored method entry
  awk '$8 ~ /^(lib\/|assets\/modules\/)/ {printf "%12d %12d  %-6s %s\n", $1, $3, $2, $8}' <<< "$listing" | sort -k4
  echo
  echo "# totals: uncompressed bytes, stored bytes"
  awk 'NF >= 8 && $1 ~ /^[0-9]+$/ {
         if ($8 ~ /^lib\//) {l += $1; ls += $3; n++}
         else if ($8 ~ /^assets\/modules\//) {m += $1; ms += $3; k++}
         else if ($8 ~ /^classes[0-9]*\.dex$/) {d += $1; ds += $3; j++}
         else {o += $1; os += $3}
       }
       END {
         printf "%-40s %12d %12d  (%d files)\n", "native libraries lib/", l, ls, n
         printf "%-40s %12d %12d  (%d files)\n", "module assets assets/modules/", m, ms, k
         printf "%-40s %12d %12d  (%d files; debug build)\n", "dex classes*.dex", d, ds, j
         printf "%-40s %12d %12d\n", "everything else (resources, manifest)", o, os
       }' <<< "$listing"
} > "$SIZES"
cat "$SIZES"
sed -n '/^# totals/,$p' "$SIZES" | tail -n +2 | while IFS= read -r l; do say "   $l"; done
say "-- $(basename "$APK"): $(stat -c %s "$APK") bytes; test APK $(stat -c %s "$TEST_APK") bytes; details in ${SIZES#"$REPO_ROOT"/}"
step_done build-apk "abi=$ABI tasks=${tasks[*]}"
say "build-apk: OK ($APK)"
