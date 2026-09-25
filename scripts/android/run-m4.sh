#!/usr/bin/env bash
# scripts/android/run-m4.sh -- plan milestone M4 acceptance on a booted emulator (or device).
#
# Runs the demo app and its instrumented test on the device and checks, with logcat, ps and
# the UI hierarchy as evidence:
#   1. liblogos_core starts in the app process and capability_module comes up in a
#      liblogos_host_qt.so child process (PPID = the app);
#   2. knownModules() lists hello_module;
#   3. loadModule("hello_module") is true and a second liblogos_host_qt.so child appears;
#   4. call("hello_module", "ping") returns "pong";
#   5. an event from hello_module (hello(tag), triggered by fire(tag)) reaches Kotlin;
#   6. the UI stays responsive (no ANR, a button tap is served while the runtime runs,
#      frame statistics from dumpsys gfxinfo);
#   7. stop() tears the runtime down (no child left, app alive) and no child survives
#      `am force-stop`.
#
# Phases (all by default, in this order; name some to run only those):
#   install  adb install -r -t the demo APK and the test APK
#   test     :demo-app:connectedDebugAndroidTest (Gradle, ANDROID_SERIAL=$SERIAL): the
#            LogosCoreAcceptanceTest class, 7 tests; the test itself lists its
#            liblogos_host_qt.so children from /proc (after start, after load, after stop)
#   demo     am start MainActivity --ez autorun true (start -> load hello_module -> ping ->
#            fire -> event), then ps, UI dump + screenshot, a "Methods" tap, a "Stop" tap
#   kill     autorun again, then am force-stop: no liblogos_host_qt.so may survive
#
# Inputs
#   android/demo-app/build/outputs/apk/debug/demo-app-debug.apk and
#   .../apk/androidTest/debug/demo-app-debug-androidTest.apk  (scripts/android/build-apk.sh)
#   a booted device: ANDROID_SERIAL (default emulator-5570, see scripts/android/emulator.sh)
# Outputs
#   build/android/<abi>/m4/            evidence: logcat-{test,demo,demo-stop,kill}.txt (full, threadtime)
#                                      and *-excerpt.txt (Logos tags), ps-*.txt, ui-*.xml,
#                                      instrument results (TEST-*.xml), gfxinfo.txt,
#                                      timings.txt, summary.txt (one PASS/FAIL line per check)
#   build/screenshots/m4.png           the demo after autorun (ping + event shown)
#   build/screenshots/m4-stopped.png   the demo after the Stop tap
#   build/logs/run-m4-<abi>.log        full log of this script
# Pinned versions: none of its own; APK contents are pinned by build-deps/build-runtime/
#   build-apk (versions.env, libs.versions.toml).
#
# Usage
#   bash scripts/android/run-m4.sh [x86_64|arm64-v8a] [install|test|demo|kill ...]
#   Environment: ANDROID_SERIAL, ADB, AUTORUN_TIMEOUT (s, default 120), plus env.sh's.
# Exit status: 0 only if every check of the phases run passed. Re-runnable: every phase
# starts from `am force-stop` + a cleared logcat.
set -Eeuo pipefail

PHASES=()
while [ $# -gt 0 ]; do
  case "$1" in
    x86_64|arm64-v8a) export ABI=$1 ;;
    install|test|demo|kill) PHASES+=("$1") ;;
    -h|--help) sed -n '2,/^set -Eeuo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 0 ;;
    *) echo "run-m4.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done
[ ${#PHASES[@]} -gt 0 ] || PHASES=(install test demo kill)
export ABI="${ABI:-x86_64}"
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
log_setup run-m4
trap 'on_error run-m4' ERR
export LC_ALL=C
export ANDROID_HOME="$ANDROID_SDK_ROOT"

SERIAL="${ANDROID_SERIAL:-emulator-5570}"
export ANDROID_SERIAL="$SERIAL"
ADB="${ADB:-$ANDROID_SDK_ROOT/platform-tools/adb}"
[ -x "$ADB" ] || ADB=$(command -v adb) || die "adb not found"
AUTORUN_TIMEOUT="${AUTORUN_TIMEOUT:-120}"
A="$REPO_ROOT/android"
APK="$A/demo-app/build/outputs/apk/debug/demo-app-debug.apk"
TEST_APK="$A/demo-app/build/outputs/apk/androidTest/debug/demo-app-debug-androidTest.apk"
PKG=com.fryorcraken.logoslib.demo
HOST=liblogos_host_qt.so
OUT="$ANDROID_BUILD/m4"
SHOTS="$BUILD_ROOT/screenshots"
LOGTAGS='LogosCore|logos-jni|logos-qtloop|logos-stdio|LogosM4Test|LogosDemo|QtCore|AndroidRuntime|DEBUG|libc|TestRunner|avc'
mkdir -p "$OUT" "$SHOTS"

adb_() { "$ADB" -s "$SERIAL" "$@"; }
sh_() { "$ADB" -s "$SERIAL" shell "$@"; }

# ---- results ------------------------------------------------------------------------
RESULTS=()
FAILED=0
record() {  # record PASS|FAIL "item" "detail"
  RESULTS+=("$1  $2 -- $3")
  [ "$1" = PASS ] || FAILED=1
  say "   [$1] $2 -- $3"
}
check() {  # check "item" "detail" command...
  local item=$1 detail=$2; shift 2
  if "$@"; then record PASS "$item" "$detail"; else record FAIL "$item" "$detail"; fi
}
timing() { printf '%s\n' "$*" >> "$OUT/timings.txt"; say "   timing: $*"; }

# ---- device helpers -----------------------------------------------------------------
app_pid() { sh_ pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}'; }
ps_snapshot() { sh_ ps -A -o PID,PPID,USER,LABEL,RSS,NAME,ARGS | tr -d '\r'; }
# children of PID that are module hosts (from a ps_snapshot on stdin)
host_children() { awk -v p="$1" -v h="$HOST" '$2 == p && index($0, h) {print}'; }
all_hosts() { awk -v h="$HOST" 'NR > 1 && index($0, h) {print}'; }
ui_dump() {
  local f="$1"
  sh_ uiautomator dump /sdcard/m4-ui.xml >/dev/null 2>&1 || true
  sh_ cat /sdcard/m4-ui.xml 2>/dev/null | tr -d '\r' > "$f" || true
  sh_ rm -f /sdcard/m4-ui.xml || true
}
ui_has() { grep -q "text=\"$2\"" "$1"; }
# tap_text UIXML TEXT: tap the centre of the first node whose text is TEXT.
tap_text() {
  local b
  b=$(grep -o "text=\"$2\"[^>]*bounds=\"\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]\"" "$1" | head -1 \
      | sed 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \2 \3 \4/')
  [ -n "$b" ] || return 1
  read -r x1 y1 x2 y2 <<< "$b"
  sh_ input tap $(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))
}
# wait_log SECONDS REGEX [TAGFILTER]: poll logcat until a line matches; prints it.
wait_log() {
  local secs=$1 re=$2 t0 line
  t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt "$secs" ]; do
    line=$(adb_ logcat -d -v threadtime 2>/dev/null | tr -d '\r' | grep -E "$re" | head -1 || true)
    if [ -n "$line" ]; then printf '%s\n' "$line"; return 0; fi
    sleep 1
  done
  return 1
}
# log_delta FILE RE1 RE2: milliseconds between the first logcat line matching RE1 and the
# first later line matching RE2 (threadtime timestamps, device clock).
log_delta() {
  awk -v a="$2" -v b="$3" '
    function ms(t,  p) { split(t, p, /[:.]/); return ((p[1] * 60 + p[2]) * 60 + p[3]) * 1000 + p[4] }
    ta == "" && $0 ~ a {ta = ms($2); next}
    ta != "" && $0 ~ b {print ms($2) - ta; found = 1; exit}
    END {if (!found) print "?"}' "$1"
}
save_logcat() {  # save_logcat NAME
  adb_ logcat -d -v threadtime | tr -d '\r' > "$OUT/logcat-$1.txt" || true
  grep -E " ($LOGTAGS)[ :]" "$OUT/logcat-$1.txt" > "$OUT/logcat-$1-excerpt.txt" || true
  adb_ logcat -d -b crash | tr -d '\r' > "$OUT/crash-$1.txt" || true
  say "   logcat: ${OUT#"$REPO_ROOT"/}/logcat-$1.txt ($(wc -l < "$OUT/logcat-$1.txt") lines, excerpt $(wc -l < "$OUT/logcat-$1-excerpt.txt"))"
}
ensure_installed() {  # the demo/kill phases need the app; install it if a phase removed it
  if [ -z "$(sh_ pm path "$PKG" 2>/dev/null | tr -d '\r')" ]; then
    say "   $PKG not installed: installing $(basename "$APK")"
    adb_ install -r -t "$APK"
  fi
}
fresh() {  # force-stop the app and clear logcat
  sh_ am force-stop "$PKG" || true
  adb_ logcat -c || true
  adb_ logcat -b crash -c 2>/dev/null || true
}

# ---- preflight ----------------------------------------------------------------------
adb_ get-state >/dev/null 2>&1 || die "$SERIAL is not connected (bash scripts/android/emulator.sh start)"
[ "$(sh_ getprop sys.boot_completed | tr -d '\r')" = 1 ] || die "$SERIAL has not finished booting"
abilist=$(sh_ getprop ro.product.cpu.abilist | tr -d '\r')
grep -q "$ABI" <<< "$abilist" || die "$SERIAL does not run $ABI (abilist $abilist)"
[ -f "$APK" ] && [ -f "$TEST_APK" ] || die "APKs missing: run scripts/android/build-apk.sh $ABI first"
say "-- device $SERIAL: API $(sh_ getprop ro.build.version.sdk | tr -d '\r'), $abilist; phases: ${PHASES[*]}"
adb_ logcat -G 16M >/dev/null 2>&1 || true   # room for a whole run
: > "$OUT/timings.txt"

has_phase() { printf '%s\n' "${PHASES[@]}" | grep -qx "$1"; }

# ======================================================================== install
phase_install() {
  step_begin "M4 install"
  local t0
  t0=$(date +%s%N)
  adb_ install -r -t "$APK"
  adb_ install -r -t "$TEST_APK"
  timing "install (both APKs): $(( ($(date +%s%N) - t0) / 1000000 )) ms"
  local nld
  nld=$(sh_ dumpsys package "$PKG" | tr -d '\r' | sed -n 's/^ *legacyNativeLibraryDir=//p' | head -1)
  say "   legacyNativeLibraryDir=$nld"
  sh_ run-as "$PKG" ls -la "$nld/x86_64" > "$OUT/nativelibdir.txt" 2>&1 || true
  step_done m4-install "apk=$(sha256_of "$APK")"
}

# ======================================================================== test
phase_test() {
  step_begin "M4 instrumented test (connectedDebugAndroidTest)"
  fresh
  # The whole class runs in well under a second, too fast to sample with `adb shell ps`: the
  # test itself lists its liblogos_host_qt.so children from /proc and logs them (checked below).
  local rc=0 t0
  t0=$(date +%s)
  rm -rf "$A/demo-app/build/outputs/androidTest-results"
  rm -f "$OUT"/TEST-*.xml "$OUT/ps-during-test.txt"   # results of an earlier run must not be counted
  # leaveApksInstalledAfterRun: AGP would otherwise uninstall the app after the run.
  "$A/gradlew" -p "$A" --no-daemon --console=plain -Plogos.abis="$ABI" \
    -Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true :demo-app:connectedDebugAndroidTest || rc=$?
  timing "connectedDebugAndroidTest wall time: $(( $(date +%s) - t0 )) s (Gradle rc=$rc)"
  save_logcat test
  find "$A/demo-app/build/outputs/androidTest-results" -name 'TEST-*.xml' -exec cp -f {} "$OUT/" \; 2>/dev/null || true
  local xml tests=0 failures=0 errors=0
  for xml in "$OUT"/TEST-*.xml; do
    [ -f "$xml" ] || continue
    tests=$((tests + $(grep -o 'tests="[0-9]*"' "$xml" | head -1 | tr -dc 0-9)))
    failures=$((failures + $(grep -o 'failures="[0-9]*"' "$xml" | head -1 | tr -dc 0-9)))
    errors=$((errors + $(grep -o 'errors="[0-9]*"' "$xml" | head -1 | tr -dc 0-9)))
    grep -o '<testcase [^>]*>' "$xml" | sed 's/ classname="[^"]*"//' | sed 's/^/   /' | while read -r l; do say "   $l"; done
  done
  check "instrumented test" "LogosCoreAcceptanceTest: $tests tests, $failures failures, $errors errors (Gradle rc=$rc)" \
    test "$rc" = 0 -a "$tests" -ge 7 -a "$failures" = 0 -a "$errors" = 0
  grep -F 'LogosM4Test' "$OUT/logcat-test.txt" | grep -E 'TIMING|known modules|getPluginMethods|qt=' | sed 's/^/   /' >> "$OUT/timings.txt" || true
  grep -F 'TIMING' "$OUT/logcat-test.txt" | sed 's/.*LogosM4Test: /   test: /' | while read -r l; do say "$l"; done || true
  local l1 l2 l3
  l1=$(grep -m1 -o 'LogosM4Test: module host children after start.*' "$OUT/logcat-test.txt" || true)
  l2=$(grep -m1 -o 'LogosM4Test: module host children after load: .*' "$OUT/logcat-test.txt" || true)
  l3=$(grep -m1 -o 'LogosM4Test: module host children after stop: .*' "$OUT/logcat-test.txt" || true)
  printf '%s\n' "$l1" "$l2" "$l3" | sed 's/ --instance-persistence-path [^ ]*//g; s/^/   /' | while IFS= read -r l; do say "$l"; done
  check "test: capability_module host after start" "${l1:0:120}..." grep -q -- '--name capability_module' <<< "$l1"
  check "test: hello_module host after load" "2 children expected" \
    eval 'grep -q -- "after load: 2 " <<< "$l2" && grep -q -- "--name hello_module" <<< "$l2"'
  check "test: no host after stop()" "${l3#LogosM4Test: }" grep -q 'after stop: 0 ' <<< "$l3"
  step_done m4-test "rc=$rc tests=$tests failures=$failures"
}

# ======================================================================== demo
phase_demo() {
  step_begin "M4 demo autorun"
  ensure_installed
  fresh
  sh_ input keyevent KEYCODE_WAKEUP || true
  sh_ wm dismiss-keyguard || true
  local t0 start_out line pid ps_file ui
  t0=$(date +%s%N)
  start_out=$(sh_ am start -W -n "$PKG/.MainActivity" --ez autorun true | tr -d '\r')
  printf '%s\n' "$start_out" > "$OUT/am-start-demo.txt"
  timing "am start -W (activity launch): $(sed -n 's/^TotalTime: //p' <<< "$start_out") ms"
  if line=$(wait_log "$AUTORUN_TIMEOUT" 'LogosDemo: AUTORUN (OK|FAILED)'); then :; else line="(no AUTORUN line within ${AUTORUN_TIMEOUT}s)"; fi
  timing "autorun (start -> load -> ping -> fire -> event) finished after $(( ($(date +%s%N) - t0) / 1000000 )) ms: ${line##*LogosDemo: }"
  sleep 1
  pid=$(app_pid || true)
  ps_file="$OUT/ps-demo-running.txt"
  ps_snapshot > "$ps_file"
  ui="$OUT/ui-demo-running.xml"
  ui_dump "$ui"
  adb_ exec-out screencap -p > "$SHOTS/m4.png" || true
  save_logcat demo
  local ex="$OUT/logcat-demo.txt"

  check "1a liblogos_core in the app process" "logcat: 'logos_core_start() returned' from pid $pid" \
    grep -qE " $pid +[0-9]+ I logos-qtloop: logos_core_start\(\) returned" "$ex"
  local cap_line
  cap_line=$(grep -E 'logos-stdio.*capability_module' "$ex" | grep -iE 'loaded|started|ready' | head -1 || true)
  check "1b capability_module loaded (host output)" "${cap_line:-no 'capability_module' load line from logos-stdio}" test -n "$cap_line"
  local kids nkids
  kids=$(host_children "$pid" < "$ps_file")
  nkids=$(printf '%s' "$kids" | grep -c . || true)
  printf '%s\n' "$kids" | sed 's/^/   child: /' | while read -r l; do say "   $l"; done
  check "1c capability_module in a $HOST child" "a $HOST child of app pid $pid hosts capability_module" \
    grep -q capability_module <<< "$kids"
  check "2 knownModules lists hello_module" "$(grep -m1 -o 'LogosDemo: known modules: .*' "$ex" || echo 'no known-modules line')" \
    grep -qE 'LogosDemo: known modules: \[.*hello_module' "$ex"
  check "3a loadModule(hello_module) true" "$(grep -m1 -o 'LogosDemo: loadModule(hello_module) -> .*' "$ex" || echo 'no load line')" \
    grep -q 'LogosDemo: loadModule(hello_module) -> true' "$ex"
  check "3b second child for hello_module" "$nkids $HOST children of pid $pid; one hosts hello_module" \
    grep -q hello_module <<< "$kids"
  check "4 ping returns pong" "$(grep -m1 -o 'LogosDemo: ping -> .*' "$ex" || echo 'no ping line')" \
    grep -q 'LogosDemo: ping -> "pong"' "$ex"
  check "5 event reaches Kotlin" "$(grep -m1 -o 'LogosDemo: event hello_module.hello .*' "$ex" || echo 'no event line')" \
    grep -q 'LogosDemo: event hello_module.hello .*tag-1' "$ex"
  check "autorun" "${line##*LogosDemo: }" grep -q 'AUTORUN OK' <<< "$line"
  check "UI shows the results" "ui dump: 'Runtime: RUNNING', 'Ping: pong', 'Last event: tag-1'" \
    eval 'ui_has "$ui" "Runtime: RUNNING" && ui_has "$ui" "Ping: pong" && ui_has "$ui" "Last event: tag-1"'

  # ---- 6: responsiveness
  local ta tap_line anr
  ta=$(date +%s%N)
  if tap_text "$ui" "Methods" && tap_line=$(wait_log 10 'LogosDemo: hello_module methods: '); then
    timing "tap 'Methods' -> getPluginMethods result logged: $(( ($(date +%s%N) - ta) / 1000000 )) ms (host side, 1 s logcat polling)"
    record PASS "6a UI serves a tap while the runtime runs" "Methods tap answered: ${tap_line##*LogosDemo: }"
  else
    record FAIL "6a UI serves a tap while the runtime runs" "no 'hello_module methods:' line within 10 s of the tap"
  fi
  sh_ dumpsys gfxinfo "$PKG" | tr -d '\r' > "$OUT/gfxinfo.txt" || true
  local frames janky skipped
  frames=$(sed -n 's/^Total frames rendered: //p' "$OUT/gfxinfo.txt" | head -1)
  janky=$(sed -n 's/^Janky frames: //p' "$OUT/gfxinfo.txt" | head -1)
  skipped=$(grep -E " $pid +$pid .*Choreographer.*Skipped [0-9]+ frames" "$OUT/logcat-demo.txt" | sed 's/.*Skipped \([0-9]*\) frames.*/\1/' | sort -n | tail -1 || true)
  anr=$(adb_ logcat -d -b events | tr -d '\r' | grep -E "am_anr.*$PKG" || true)
  anr+=$(grep -E "ANR in $PKG" "$OUT/logcat-demo.txt" || true)
  check "6b no ANR" "frames rendered ${frames:-?}, janky ${janky:-?}; worst Choreographer skip on the main thread: ${skipped:-none} frames" \
    test -z "$anr"

  # ---- 7a: stop() through the UI
  local stop_line pid_after kids_after
  ui_dump "$ui.2"
  ta=$(date +%s%N)
  if tap_text "$ui.2" "Stop" && stop_line=$(wait_log 30 'LogosDemo: stopped: '); then
    timing "tap 'Stop' -> 'stopped' logged: $(( ($(date +%s%N) - ta) / 1000000 )) ms (host side, 1 s logcat polling)"
  else
    stop_line="(no 'stopped:' line within 30 s of the Stop tap)"
  fi
  sleep 2
  ps_snapshot > "$OUT/ps-demo-stopped.txt"
  pid_after=$(app_pid || true)
  kids_after=$(host_children "$pid" < "$OUT/ps-demo-stopped.txt")
  ui_dump "$OUT/ui-demo-stopped.xml"
  adb_ exec-out screencap -p > "$SHOTS/m4-stopped.png" || true
  save_logcat demo-stop
  check "7a stop() tears down cleanly" "${stop_line##*LogosDemo: }; app pid $pid_after (was $pid); $HOST children left: $(printf '%s' "$kids_after" | grep -c . || true)" \
    eval 'grep -q "stopped: true" <<< "$stop_line" && [ "$pid_after" = "$pid" ] && [ -z "$kids_after" ] && ui_has "$OUT/ui-demo-stopped.xml" "Runtime: STOPPED"'
  # app-side timings (device clock)
  local f="$OUT/logcat-demo-stop.txt"
  grep -oE 'LogosCore: liblogos running after [0-9]+ ms|LogosDemo: [a-z_ ]+ took [0-9]+ ms' "$f" \
    | sed 's/^/demo /' | while IFS= read -r l; do timing "$l"; done || true
  timing "demo logos_core_load_module(hello_module): $(log_delta "$f" 'logos-jni: load_module[(]hello_module, deps' 'logos-jni: load_module[(]hello_module[)] -> ') ms"
  timing "demo fire(tag-1) -> event in Kotlin: $(log_delta "$f" 'LogosDemo: ping -> ' 'LogosDemo: event hello_module') ms (upper bound: from the ping result)"
  grep -E 'logos-qtloop|teardown|cleanup' "$f" | sed 's/^/   /' | head -20 || true
  step_done m4-demo "pid=$pid"
}

# ======================================================================== kill
phase_kill() {
  step_begin "M4 am force-stop"
  ensure_installed
  fresh
  local line pid kids left t0
  sh_ am start -W -n "$PKG/.MainActivity" --ez autorun true >/dev/null
  line=$(wait_log "$AUTORUN_TIMEOUT" 'LogosDemo: AUTORUN (OK|FAILED)' || echo "(no AUTORUN line)")
  sleep 1
  pid=$(app_pid || true)
  [ -n "$pid" ] || say "   WARNING: $PKG is not running after am start (${line##*LogosDemo: })"
  ps_snapshot > "$OUT/ps-kill-before.txt"
  kids=$(host_children "$pid" < "$OUT/ps-kill-before.txt")
  say "   before force-stop: app pid $pid, $(printf '%s' "$kids" | grep -c . || true) $HOST children (${line##*LogosDemo: })"
  t0=$(date +%s%N)
  sh_ am force-stop "$PKG"
  for _ in $(seq 1 10); do
    ps_snapshot > "$OUT/ps-kill-after.txt"
    left=$( { all_hosts < "$OUT/ps-kill-after.txt"; grep -F "$PKG" "$OUT/ps-kill-after.txt" || true; } )
    [ -z "$left" ] && break
    sleep 0.5
  done
  timing "am force-stop -> app and module hosts gone: $(( ($(date +%s%N) - t0) / 1000000 )) ms"
  save_logcat kill
  check "7b no child survives am force-stop" "before: $(printf '%s' "$kids" | grep -c . || true) children of pid $pid; after: ${left:-no $HOST and no $PKG process}" \
    eval '[ -n "$kids" ] && [ -z "$left" ]'
  step_done m4-kill "pid=$pid"
}

for p in install test demo kill; do
  if has_phase "$p"; then "phase_$p"; fi
done

{
  echo "# M4 acceptance on $SERIAL ($ABI), $(date -Is)"
  printf '%s\n' "${RESULTS[@]}"
  echo
  echo "# timings"
  cat "$OUT/timings.txt"
} > "$OUT/summary.txt"
say "-- summary: ${OUT#"$REPO_ROOT"/}/summary.txt; screenshots in ${SHOTS#"$REPO_ROOT"/}"
if [ "$FAILED" = 0 ]; then
  say "run-m4: OK (${#RESULTS[@]} checks passed)"
else
  say "run-m4: FAILED ($(printf '%s\n' "${RESULTS[@]}" | grep -c '^FAIL') of ${#RESULTS[@]} checks failed)"
  exit 1
fi
