#!/usr/bin/env bash
# scripts/android/build-release.sh -- build, verify and collect the demo app's RELEASE APK
# (the file a phone user installs) for one or more ABIs.
#
# Gradle does not build native code: the runtime and the modules must already be built for
# every ABI asked for (build-deps.sh, build-runtime.sh, build-blockchain.sh,
# build-libfyaml.sh, build-blockchain-module.sh, build-jni.sh). This script then
#   1. runs stage.sh <abi> $RELEASE_MODULES for each ABI (unless SKIP_STAGE=1);
#   2. runs gradlew :demo-app:assembleRelease -Plogos.abis=<abi,...>. The release build type
#      has minify off and is signed with the debug key (the POC convention of
#      logos-android-wrap-poc). The previous release APK is deleted first, so Gradle packages
#      it from scratch: an incremental update that replaces the 48 MB liblogos_blockchain.so
#      entry can leave the old copy behind as dead space;
#   3. verifies the APK. It fails unless all of these hold:
#      - aapt2 dump badging: package = the demo's applicationId, versionName = the demo's
#        versionName (android/demo-app/build.gradle.kts), native-code = exactly the ABIs asked
#        for, not debuggable
#      - apksigner verify passes (the certificate goes into the report)
#      - zipalign -c -P 16 -v 4 passes (4-byte alignment; 16 KB alignment of any stored .so)
#      - AndroidManifest.xml: extractNativeLibs is not false, and every lib/ entry is deflated
#        (useLegacyPackaging): liblogos_host_qt.so must be extracted to nativeLibraryDir to be
#        exec'able
#      - lib/<abi>/ holds every staged library, byte-identical, and there is no lib/ for any
#        other ABI
#      - assets/modules/<abi>/ is the staged module tree, byte-identical, with every module
#        asked for, and there are no module assets for any other ABI
#      - every ELF shipped (lib/<abi>/*.so, the module plugins and their private libraries),
#        as extracted from the APK, passes check-prefix.sh (ELF machine, every PT_LOAD p_align
#        >= 0x4000, no /nix/store, NEEDED and undefined symbols resolvable, SONAME, RUNPATH,
#        module manifests) and this script's own llvm-readelf pass (machine, p_align 0x4000,
#        no /nix/store string)
#      - the APK has no dead space: its size minus the stored bytes of its entries is < 4 MiB
#
# Outputs (build/release/; <name> = logoslib-android-poc-<versionName>-<abi>[-<abi>...])
#   <name>.apk          the verified APK (a copy of demo-app-release.apk)
#   <name>.apk.sha256   "<sha256>  <name>.apk", for sha256sum -c
#   <name>.report.txt   what was checked, with the evidence: badging, signer certificate,
#                       manifest flags, zipalign, per-entry sizes (unzip -v), ELF table,
#                       check-prefix output, provenance of the native parts
#   build/logs/build-release-<first abi>.log   full log (Gradle included)
# On a failed check, the report is still written (with [FAIL] lines) but no APK is copied.
#
# Usage
#   bash scripts/android/build-release.sh [abi ...]        default: arm64-v8a
#     abi: arm64-v8a | x86_64; several give one multi-ABI APK
#   Environment: RELEASE_MODULES (default "capability_module hello_module blockchain_module
#   bc_probe"), SKIP_STAGE=1 (package what is already staged), FORCE=1 (gradle clean first),
#   GRADLE_ARGS (extra Gradle arguments), plus everything env.sh reads (JAVA_HOME,
#   ANDROID_SDK_ROOT, ...). Tools: aapt2, apksigner and zipalign from the newest SDK
#   build-tools (35 or later for zipalign -P).
# Pinned versions: android/demo-app/build.gradle.kts (versionName, versionCode),
#   android/gradle/libs.versions.toml (AGP, SDK levels), scripts/android/versions*.env.
set -Eeuo pipefail

ABIS=()
while [ $# -gt 0 ]; do
  case "$1" in
    x86_64|arm64-v8a) printf '%s\n' "${ABIS[@]}" | grep -qx -- "$1" || ABIS+=("$1") ;;
    -h|--help) sed -n '2,/^set -Eeuo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 0 ;;
    *) echo "build-release.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done
[ ${#ABIS[@]} -gt 0 ] || ABIS=(arm64-v8a)
export ABI="${ABIS[0]}"
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
log_setup build-release
trap 'on_error build-release' ERR
export LC_ALL=C
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export PATH="$JAVA_HOME/bin:$PATH"   # apksigner runs `java`; /usr/bin/java is a JRE-only JDK 25 here

read -ra MODULES <<< "${RELEASE_MODULES:-capability_module hello_module blockchain_module bc_probe}"
ABIS_CSV=$(IFS=,; echo "${ABIS[*]}")
ABIS_TAG=$(IFS=-; echo "${ABIS[*]}")
A="$REPO_ROOT/android"
CORE_MAIN="$A/logos-core/src/main"
APK_DIR="$A/demo-app/build/outputs/apk/release"
APK="$APK_DIR/demo-app-release.apk"
OUT_DIR="$BUILD_ROOT/release"
VER_DIR="$OUT_DIR/.verify"

[ -x "$JAVA_HOME/bin/javac" ] || die "JAVA_HOME=$JAVA_HOME is not a JDK (no bin/javac)"
BT=$(find "$ANDROID_SDK_ROOT/build-tools" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -1)
[ -n "$BT" ] || die "no build-tools under $ANDROID_SDK_ROOT/build-tools"
AAPT2="$ANDROID_SDK_ROOT/build-tools/$BT/aapt2"
APKSIGNER="$ANDROID_SDK_ROOT/build-tools/$BT/apksigner"
ZIPALIGN="$ANDROID_SDK_ROOT/build-tools/$BT/zipalign"
for t in "$AAPT2" "$APKSIGNER" "$ZIPALIGN"; do [ -x "$t" ] || die "missing tool $t"; done

# What the APK must say: the demo's applicationId and versionName.
GRADLE_APP="$A/demo-app/build.gradle.kts"
EXPECT_PKG=$(sed -n 's/^ *applicationId *= *"\(.*\)".*/\1/p' "$GRADLE_APP" | head -1)
EXPECT_VERSION=$(sed -n 's/^ *versionName *= *"\(.*\)".*/\1/p' "$GRADLE_APP" | head -1)
EXPECT_VCODE=$(sed -n 's/^ *versionCode *= *\([0-9]*\).*/\1/p' "$GRADLE_APP" | head -1)
[ -n "$EXPECT_PKG" ] && [ -n "$EXPECT_VERSION" ] || die "cannot read applicationId / versionName from $GRADLE_APP"
NAME="logoslib-android-poc-$EXPECT_VERSION-$ABIS_TAG"
REPORT="$OUT_DIR/$NAME.report.txt"

say "abis: ${ABIS[*]}   modules: ${MODULES[*]}   version: $EXPECT_VERSION ($EXPECT_VCODE)   build-tools: $BT"

# ---- 1. stage ------------------------------------------------------------------------
if [ "${SKIP_STAGE:-0}" = 1 ]; then
  say "-- SKIP_STAGE=1: packaging what is already staged"
else
  for abi in "${ABIS[@]}"; do
    say "-- stage.sh $abi ${MODULES[*]}"
    bash "$SCRIPTS_DIR/stage.sh" "$abi" "${MODULES[@]}" >&3 2>&3
  done
fi
for abi in "${ABIS[@]}"; do
  [ -f "$CORE_MAIN/jniLibs/$abi/liblogos_jni.so" ] || die "nothing staged for $abi (run build-jni.sh and stage.sh $abi)"
  [ -f "$CORE_MAIN/modules-staged/$abi/modules/$abi/modules.stamp" ] || die "no staged modules for $abi"
done

# ---- 2. Gradle -----------------------------------------------------------------------
step_begin "gradle assembleRelease -Plogos.abis=$ABIS_CSV"
tasks=()
[ "$FORCE" = 1 ] && tasks+=(clean)
tasks+=(:demo-app:assembleRelease)
# shellcheck disable=SC2206
extra=(${GRADLE_ARGS:-})
# A missing output makes Gradle run the packaging task non-incrementally: the APK is written
# from scratch, with no dead space from replaced entries.
rm -rf "$APK_DIR"
say "-- gradlew ${tasks[*]} -Plogos.abis=$ABIS_CSV (JAVA_HOME=$JAVA_HOME)"
"$A/gradlew" -p "$A" --no-daemon --console=plain -Plogos.abis="$ABIS_CSV" "${extra[@]}" "${tasks[@]}"
[ -f "$APK" ] || die "Gradle finished but $APK is missing ($(ls "$APK_DIR" 2>/dev/null | tr '\n' ' '))"
APK_SIZE=$(stat -c %s "$APK")
APK_SHA=$(sha256_of "$APK")
say "-- $(basename "$APK"): $APK_SIZE bytes, sha256 $APK_SHA"

# ---- 3. verify -----------------------------------------------------------------------
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$NAME.apk" "$OUT_DIR/$NAME.apk.sha256" "$REPORT"
rm -rf "$VER_DIR"
FAILS=()
rep() { printf '%s\n' "$@" >> "$REPORT"; }
section() { rep "" "## $*" ""; }
check() {   # check ok|fail WHAT [DETAIL]
  local tag=FAIL
  if [ "$1" = ok ]; then tag=PASS; else FAILS+=("$2"); fi
  rep "[$tag] $2${3:+ -- $3}"
  say "[$tag] $2${3:+ -- $3}"
}
# grep that never fails (no match = empty output): keeps pipefail and the ERR trap quiet.
grepq() { grep "$@" || true; }
expected_machine() { case "$1" in arm64-v8a) echo AArch64 ;; x86_64) echo "Advanced Micro Devices X86-64" ;; esac; }

{
  echo "# Release APK report: $NAME"
  echo
  echo "Built $(date -Is) on $(uname -srm) by scripts/android/build-release.sh ${ABIS[*]}"
  echo "APK: $(basename "$APK") -> build/release/$NAME.apk"
  echo "size: $APK_SIZE bytes"
  echo "sha256: $APK_SHA"
  echo "ABIs: ${ABIS[*]}   modules: ${MODULES[*]}"
  echo "tools: build-tools $BT (aapt2, apksigner, zipalign), JDK $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"
} > "$REPORT"

section "Checks"
listing=$(unzip -v "$APK")

# -- badging
badging=$("$AAPT2" dump badging "$APK")
pkg=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<< "$badging")
vcode=$(sed -n "s/^package: .* versionCode='\([^']*\)'.*/\1/p" <<< "$badging")
vname=$(sed -n "s/^package: .* versionName='\([^']*\)'.*/\1/p" <<< "$badging")
minsdk=$(sed -n "s/^minSdkVersion:'\([^']*\)'.*/\1/p; s/^sdkVersion:'\([^']*\)'.*/\1/p" <<< "$badging" | head -1)
tsdk=$(sed -n "s/^targetSdkVersion:'\([^']*\)'.*/\1/p" <<< "$badging")
native=$(sed -n 's/^native-code: //p' <<< "$badging" | tr -d "'" | tr ' ' '\n' | sort | tr '\n' ' ')
want_native=$(printf '%s\n' "${ABIS[@]}" | sort | tr '\n' ' ')
if [ "$pkg" = "$EXPECT_PKG" ]; then check ok "package name" "$pkg"; else check fail "package name" "'$pkg', want $EXPECT_PKG"; fi
if [ "$vname" = "$EXPECT_VERSION" ]; then check ok "versionName" "$vname"; else check fail "versionName" "'$vname', want $EXPECT_VERSION"; fi
if [ "$vcode" = "$EXPECT_VCODE" ]; then check ok "versionCode" "$vcode"; else check fail "versionCode" "'$vcode', want $EXPECT_VCODE"; fi
TOML="$A/gradle/libs.versions.toml"
want_min=$(sed -n 's/^ *minSdk *= *"\([0-9]*\)".*/\1/p' "$TOML" | head -1)
want_target=$(sed -n 's/^ *targetSdk *= *"\([0-9]*\)".*/\1/p' "$TOML" | head -1)
if [ "$minsdk" = "$want_min" ] && [ "$tsdk" = "$want_target" ]; then check ok "SDK levels" "minSdk $minsdk, targetSdk $tsdk"
else check fail "SDK levels" "minSdk '$minsdk' targetSdk '$tsdk', want $want_min / $want_target (libs.versions.toml)"; fi
if [ "$native" = "$want_native" ]; then check ok "native-code" "${native% }"; else check fail "native-code" "'${native% }', want '${want_native% }'"; fi
if grep -q '^application-debuggable' <<< "$badging"; then check fail "not debuggable" "badging says application-debuggable"
else check ok "not debuggable" "no application-debuggable (release build type; run-as does not work on it)"; fi

# -- signature
if signout=$("$APKSIGNER" verify --verbose --print-certs "$APK" 2>&1); then
  check ok "apksigner verify" "schemes $(grepq -E '^Verified using v[0-9.]+ scheme.*: true' <<< "$signout" | sed 's/Verified using //; s/ scheme (APK Signature Scheme v[0-9.]*)//; s/: true//' | tr '\n' ' ')"
else
  check fail "apksigner verify" "$(tail -3 <<< "$signout" | tr '\n' ' ')"
fi

# -- zip alignment
if zaout=$("$ZIPALIGN" -c -P 16 -v 4 "$APK" 2>&1); then
  check ok "zipalign -c -P 16 -v 4" "$(tail -1 <<< "$zaout")"
else
  check fail "zipalign -c -P 16 -v 4" "$(grepq -v '(OK' <<< "$zaout" | head -5 | tr '\n' ' ')"
fi
printf '%s\n' "$zaout" > "$LOG_DIR/build-release-zipalign.txt"

# -- manifest: native library extraction (and the attributes a GrapheneOS/MTE reader asks about)
manifest=$("$AAPT2" dump xmltree --file AndroidManifest.xml "$APK")
extract=$(sed -n 's/.*android:extractNativeLibs([^)]*)=\([a-z]*\).*/\1/p' <<< "$manifest" | head -1)
if [ "$extract" = false ]; then
  check fail "extractNativeLibs" "false: liblogos_host_qt.so would not be extracted, so not exec'able"
else
  check ok "extractNativeLibs" "${extract:-absent (default true)}"
fi
stored_so=$(awk '$8 ~ /^lib\/.*\.so$/ && $2 == "Stored" {print $8}' <<< "$listing")
if [ -z "$stored_so" ]; then check ok "lib/ .so entries deflated (useLegacyPackaging = true)"
else check fail "lib/ .so entries deflated" "stored uncompressed: $(tr '\n' ' ' <<< "$stored_so")"; fi

# -- lib/<abi>: exactly the staged libraries (plus AndroidX's), byte-identical; no other ABI
lib_abis=$(awk '$8 ~ /^lib\// {split($8, p, "/"); print p[2]}' <<< "$listing" | sort -u | tr '\n' ' ')
if [ "$lib_abis" = "$want_native" ]; then check ok "lib/ ABIs" "${lib_abis% } only"
else check fail "lib/ ABIs" "'${lib_abis% }', want '${want_native% }'"; fi
mod_abis=$(awk '$8 ~ /^assets\/modules\// {split($8, p, "/"); print p[3]}' <<< "$listing" | sort -u | tr '\n' ' ')
if [ "$mod_abis" = "$want_native" ]; then check ok "assets/modules/ ABIs" "${mod_abis% } only"
else check fail "assets/modules/ ABIs" "'${mod_abis% }', want '${want_native% }'"; fi

mkdir -p "$VER_DIR"
unzip -q -o "$APK" 'lib/*' 'assets/modules/*' -d "$VER_DIR"
for abi in "${ABIS[@]}"; do
  staged=$(find "$CORE_MAIN/jniLibs/$abi" -maxdepth 1 -type f -name '*.so' -printf '%f\n' | sort)
  inapk=$(find "$VER_DIR/lib/$abi" -maxdepth 1 -type f -name '*.so' -printf '%f\n' | sort)
  missing=$(comm -23 <(printf '%s\n' "$staged") <(printf '%s\n' "$inapk") | tr '\n' ' ')
  extras=$(comm -13 <(printf '%s\n' "$staged") <(printf '%s\n' "$inapk") | tr '\n' ' ')
  differ=""
  for n in $staged; do
    if [ -f "$VER_DIR/lib/$abi/$n" ] && ! cmp -s "$CORE_MAIN/jniLibs/$abi/$n" "$VER_DIR/lib/$abi/$n"; then differ+="$n "; fi
  done
  nstaged=$(printf '%s\n' "$staged" | grepq -c .)
  if [ -z "$missing" ] && [ -z "$differ" ]; then
    check ok "lib/$abi has every staged library, byte-identical" "$nstaged staged${extras:+; also from dependencies: ${extras% }}"
  else
    check fail "lib/$abi has every staged library, byte-identical" "missing: ${missing:-none}; differ: ${differ:-none}"
  fi
  for n in liblogos_host_qt.so liblogos_jni.so liblogos_core.so; do
    if [ -f "$VER_DIR/lib/$abi/$n" ]; then check ok "lib/$abi/$n present" "$(stat -c %s "$VER_DIR/lib/$abi/$n") bytes"
    else check fail "lib/$abi/$n present"; fi
  done
  # module tree: every module asked for, identical to what stage.sh put there
  src_mods="$CORE_MAIN/modules-staged/$abi/modules/$abi"
  got=$(find "$VER_DIR/assets/modules/$abi" -mindepth 2 -maxdepth 2 -name manifest.json -printf '%h\n' | xargs -rn1 basename | sort | tr '\n' ' ')
  want=$(printf '%s\n' "${MODULES[@]}" | sort | tr '\n' ' ')
  if [ "$got" = "$want" ]; then check ok "assets/modules/$abi modules" "${got% }"
  else check fail "assets/modules/$abi modules" "'${got% }', want '${want% }'"; fi
  if dr=$(diff -r "$src_mods" "$VER_DIR/assets/modules/$abi" 2>&1); then
    check ok "assets/modules/$abi byte-identical to the staged tree" "$(find "$src_mods" -type f | wc -l) files, stamp $(cat "$src_mods/modules.stamp")"
  else
    check fail "assets/modules/$abi byte-identical to the staged tree" "$(head -3 <<< "$dr" | tr '\n' ' ')"
  fi
done

# -- ELF: check-prefix.sh on the extracted set, then an llvm-readelf table of every ELF
for abi in "${ABIS[@]}"; do
  if cpout=$(bash "$SCRIPTS_DIR/check-prefix.sh" "$abi" "$VER_DIR/lib/$abi" --modules "$VER_DIR/assets/modules/$abi" 2>&1); then
    check ok "check-prefix.sh $abi on the files extracted from the APK" "$(tail -1 <<< "$cpout")"
  else
    check fail "check-prefix.sh $abi on the files extracted from the APK" "$(tail -1 <<< "$cpout")"
  fi
  printf '%s\n' "$cpout" > "$OUT_DIR/.check-prefix-$abi.txt"
done
ELF_TABLE=$(
  printf '%-58s %10s  %-8s %-7s %-6s %-5s %s\n' FILE SIZE MACHINE P_ALIGN NEEDED NIX NOTES
  bad=0
  while IFS= read -r f; do
    rel=${f#"$VER_DIR"/}
    if [ "${rel%%/*}" = assets ]; then abi=$(cut -d/ -f3 <<< "$rel"); else abi=$(cut -d/ -f2 <<< "$rel"); fi
    hdr=$("$READELF" -h -l -d -n -W "$f" 2>&1)
    machine=$(sed -n 's/^ *Machine: *//p' <<< "$hdr" | head -1)
    aligns=$(awk '$1 == "LOAD" {print $NF}' <<< "$hdr" | sort -u | tr '\n' ',')
    nneeded=$(grepq -c '(NEEDED)' <<< "$hdr")
    nix=$(grepq -c -a -F '/nix/store' "$f")
    notes=""
    if grep -q 'INTERP' <<< "$hdr"; then notes+="executable "; fi
    if grep -q '(RUNPATH)' <<< "$hdr"; then notes+="runpath=$(sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p' <<< "$hdr") "; fi
    if grep -q 'NT_ANDROID_TYPE_MEMTAG' <<< "$hdr"; then notes+="memtag-note "; fi
    feat=$(sed -n 's/.*AArch64 feature: *//p' <<< "$hdr" | head -1)
    if [ -n "$feat" ]; then notes+="aarch64-feature=${feat// /} "; fi
    m=$machine
    if [ "$machine" = "Advanced Micro Devices X86-64" ]; then m=x86-64; fi
    flag=""
    if ! { [ "$machine" = "$(expected_machine "$abi")" ] && [ "$aligns" = "0x4000," ] && [ "$nix" = 0 ]; }; then
      flag=" <-- FAIL"; bad=$((bad + 1))
    fi
    printf '%-58s %10s  %-8s %-7s %-6s %-5s %s%s\n' "$rel" "$(stat -c %s "$f")" "$m" "${aligns%,}" "$nneeded" "$nix" "${notes% }" "$flag"
  done < <(find "$VER_DIR" -type f -name '*.so' | sort)
  echo "ELF files: $(find "$VER_DIR" -type f -name '*.so' | wc -l), failing: $bad"
)
nbad=$(tail -1 <<< "$ELF_TABLE" | sed 's/.*failing: //')
if [ "$nbad" = 0 ]; then check ok "llvm-readelf: every ELF has the ABI's e_machine, p_align 0x4000 on every PT_LOAD, no /nix/store" "$(tail -1 <<< "$ELF_TABLE" | sed 's/, failing: 0//')"
else check fail "llvm-readelf: machine / p_align / /nix/store" "$nbad files fail (see the ELF table)"; fi

# -- dead space
stored_total=$(awk 'NF >= 8 && $1 ~ /^[0-9]+$/ {s += $3} END {print s + 0}' <<< "$listing")
overhead=$((APK_SIZE - stored_total))
if [ "$overhead" -lt $((4 * 1024 * 1024)) ]; then check ok "no dead space in the zip" "APK $APK_SIZE bytes - entries $stored_total stored bytes = $overhead bytes of headers, alignment and signing block"
else check fail "no dead space in the zip" "$overhead bytes beyond the entries (rebuild with FORCE=1)"; fi

# ---- report body -----------------------------------------------------------------------
section "aapt2 dump badging (selected lines)"
rep "$(grepq -E "^(package|sdkVersion|minSdkVersion|targetSdkVersion|uses-permission|application:|application-debuggable|native-code|alt-native-code|launchable-activity)" <<< "$badging")"
section "AndroidManifest.xml attributes (aapt2 dump xmltree)"
rep "$(grepq -E 'android:(extractNativeLibs|memtagMode|debuggable|pageSizeCompat|allowNativeHeapPointerTagging|usesCleartextTraffic|minSdkVersion|targetSdkVersion|versionCode|versionName)|E: (uses-permission|application)|android:name\([^)]*\)="[^"]*permission' <<< "$manifest" | sed 's/^ *//; s|http://schemas.android.com/apk/res/android:|android:|')"
rep "" "(no android:memtagMode attribute means the platform default applies)"
section "apksigner verify --verbose --print-certs"
rep "$signout"
section "zipalign -c -P 16 -v 4 (native libraries and the verdict; full output in build/logs/build-release-zipalign.txt)"
rep "$(grepq -E '\.so|Verification' <<< "$zaout")"
section "Entries (unzip -v): uncompressed bytes, stored bytes, method"
rep "$(printf '%12s %12s  %-7s %s' length stored method entry)"
rep "$(awk '$8 ~ /^(lib\/|assets\/modules\/)/ {printf "%12d %12d  %-7s %s\n", $1, $3, $2, $8}' <<< "$listing" | sort -k4)"
rep "" "Totals:"
rep "$(awk 'NF >= 8 && $1 ~ /^[0-9]+$/ {
         if ($8 ~ /^lib\//) {l += $1; ls += $3; n++}
         else if ($8 ~ /^assets\/modules\//) {m += $1; ms += $3; k++}
         else if ($8 ~ /^classes[0-9]*\.dex$/) {d += $1; ds += $3; j++}
         else {o += $1; os += $3; p++}
       }
       END {
         printf "%-40s %12d %12d  (%d files)\n", "native libraries lib/", l, ls, n
         printf "%-40s %12d %12d  (%d files)\n", "module assets assets/modules/", m, ms, k
         printf "%-40s %12d %12d  (%d files)\n", "dex classes*.dex", d, ds, j
         printf "%-40s %12d %12d  (%d files)\n", "everything else", o, os, p
       }' <<< "$listing")"
section "ELF files as extracted from the APK (llvm-readelf)"
rep "$ELF_TABLE"
rep "" "NOTES: executable = has PT_INTERP (liblogos_host_qt.so, exec'd per module); memtag-note = carries an" \
    "NT_ANDROID_TYPE_MEMTAG note (the binary asks for a memory-tagging mode); aarch64-feature = GNU property" \
    "note with BTI/PAC. A file without them has none."
for abi in "${ABIS[@]}"; do
  section "check-prefix.sh $abi on the extracted lib/$abi and assets/modules/$abi"
  rep "$(sed -n '/^FILE /,$p' "$OUT_DIR/.check-prefix-$abi.txt")"
done
section "Provenance of the native parts"
for abi in "${ABIS[@]}"; do
  pf="$BUILD_ROOT/android/$abi/prefix/share/logos-android"
  for m in runtime-manifest.txt blockchain-manifest.txt; do
    if [ -f "$pf/$m" ]; then rep "-- $abi $m:" "$(sed 's/^/   /' "$pf/$m")"; fi
  done
  if [ -f "$BUILD_ROOT/android/$abi/staged.txt" ]; then
    rep "-- $abi staged.txt (stage.sh):" "$(sed 's/^/   /' "$BUILD_ROOT/android/$abi/staged.txt")"
  fi
done

# ---- result ------------------------------------------------------------------------------
rm -rf "$VER_DIR" "$OUT_DIR"/.check-prefix-*.txt
if [ ${#FAILS[@]} -gt 0 ]; then
  section "Result: FAILED (${#FAILS[@]} checks)"
  rep "${FAILS[@]}"
  die "${#FAILS[@]} check(s) failed: ${FAILS[*]} (report: ${REPORT#"$REPO_ROOT"/})"
fi
cp -f "$APK" "$OUT_DIR/$NAME.apk"
( cd "$OUT_DIR" && sha256sum "$NAME.apk" > "$NAME.apk.sha256" )
[ "$(cut -d' ' -f1 "$OUT_DIR/$NAME.apk.sha256")" = "$APK_SHA" ] || die "sha256 of the copy differs from the Gradle output"
section "Result: OK"
rep "build/release/$NAME.apk  $APK_SIZE bytes  sha256 $APK_SHA"
step_done build-release "abis=$ABIS_CSV modules=${MODULES[*]} sha256=$APK_SHA"
say "-- build/release/$NAME.apk: $APK_SIZE bytes"
say "-- sha256 $APK_SHA (build/release/$NAME.apk.sha256)"
say "-- report: build/release/$NAME.report.txt"
say "build-release: OK ($OUT_DIR/$NAME.apk)"
