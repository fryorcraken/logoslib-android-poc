#!/usr/bin/env bash
# scripts/android/run-m5.sh -- plan milestones M5/M6 on a booted emulator (or device): the
# Logos blockchain node (blockchain_module) run from the Kotlin demo app, joining devnet
# 0.3.0-rc.4 in follower mode, and the bc_probe -> blockchain_module inter-module call.
#
# Checks (logcat, ps, top and the UI hierarchy as evidence):
#   1. blockchain_module and bc_probe load, each in its own liblogos_host_qt.so child of the app;
#   2. the node starts from the app (generate_user_config + merge_user_config follower mode,
#      then start(config, ""));
#   3. get_network_info reports n_peers > 0;
#   4. the height climbs to the devnet tip (tip slot within 180 slots of get_time_info's
#      current slot);
#   5. newBlock events reach Kotlin;
#   6. bc_probe.chain_info_via_bc (bc_probe's host calling blockchain_module over liblogos'
#      QtRO transport, with a capability_module token) returns the live height;
#   7. the UI stays responsive during the sync (a tap is served, no ANR, frame stats);
#   8. the node's stop() and then the runtime's stop() leave no child; `am force-stop` of a
#      running node leaves none either.
# Measured: sync time, first peer, start() time (fresh and restart with replay), CPU/RSS of
# the blockchain host over time (top) and at the end (/proc/<pid>/status), app meminfo, disk
# under filesDir, APK size per .so (build/android/<abi>/apk-sizes.txt), first-launch asset
# extraction time.
#
# Phases (all by default, in this order; name some to run only those):
#   install  adb install -r -t the demo APK and the test APK (first launch then extracts assets)
#   demo     am start --ez bc_autorun true --ez bc_fresh true (fresh node dir: sync from
#            genesis); wait for "BC AUTORUN OK"; during the sync tap "Load hello" (loads
#            hello_module while the node syncs); screenshots; then the node's stop through
#            `--es bc_action stop`, then the runtime's Stop tap
#   kill     bc_autorun again on the synced state (start() replays the chain), then am force-stop
#   test     am instrument -e blockchain 1 -e class ...BlockchainAcceptanceTest (10 tests, its
#            own node dir, fresh sync; kills the blockchain host at the end to check that
#            LogosCore reports the death)
#
# Inputs
#   android/demo-app/build/outputs/apk/{debug,androidTest/debug}/*.apk (scripts/android/build-apk.sh
#   after stage.sh x86_64 capability_module hello_module blockchain_module bc_probe)
#   a booted device: ANDROID_SERIAL (default emulator-5570, scripts/android/emulator.sh start)
#   network: UDP to 65.108.203.235:3000-3002,50001 (devnet), NTP (pool.ntp.org)
# Outputs
#   build/android/<abi>/m5/          logcat-*.txt (+ -excerpt), ps-*.txt, top-bc.txt (samples),
#                                    status-bc.txt, meminfo-*.txt, du.txt, ui-*.xml, gfxinfo.txt,
#                                    instrument.txt, timings.txt, summary.txt (PASS/FAIL lines)
#   build/screenshots/m5-blockchain.png  node synced (height, peers, bc_probe row)
#   build/screenshots/m5-node-stopped.png, m5-stopped.png
#   build/logs/run-m5-<abi>.log      full log of this script
#
# Usage
#   bash scripts/android/run-m5.sh [x86_64|arm64-v8a] [install|demo|kill|test ...]
#   Environment: ANDROID_SERIAL, ADB, BC_TIMEOUT (s, default 1200: autorun deadline),
#   BC_EXTERNAL (multiaddr for external_address; default none = NAT traversal), plus env.sh's.
# Exit status: 0 only if every check of the phases run passed.
set -Eeuo pipefail

PHASES=()
while [ $# -gt 0 ]; do
  case "$1" in
    x86_64|arm64-v8a) export ABI=$1 ;;
    install|demo|kill|test) PHASES+=("$1") ;;
    -h|--help) sed -n '2,/^set -Eeuo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 0 ;;
    *) echo "run-m5.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done
[ ${#PHASES[@]} -gt 0 ] || PHASES=(install demo kill test)
export ABI="${ABI:-x86_64}"
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
log_setup run-m5
trap 'on_error run-m5' ERR
export LC_ALL=C
export ANDROID_HOME="$ANDROID_SDK_ROOT"

SERIAL="${ANDROID_SERIAL:-emulator-5570}"
export ANDROID_SERIAL="$SERIAL"
ADB="${ADB:-$ANDROID_SDK_ROOT/platform-tools/adb}"
[ -x "$ADB" ] || ADB=$(command -v adb) || die "adb not found"
BC_TIMEOUT="${BC_TIMEOUT:-1200}"
BC_EXTERNAL="${BC_EXTERNAL:-}"
A="$REPO_ROOT/android"
APK="$A/demo-app/build/outputs/apk/debug/demo-app-debug.apk"
TEST_APK="$A/demo-app/build/outputs/apk/androidTest/debug/demo-app-debug-androidTest.apk"
PKG=com.fryorcraken.logoslib.demo
HOST=liblogos_host_qt.so
OUT="$ANDROID_BUILD/m5"
SHOTS="$BUILD_ROOT/screenshots"
LOGTAGS='LogosCore|logos-jni|logos-qtloop|logos-stdio|LogosM5Test|LogosDemo|AndroidRuntime|DEBUG|libc|TestRunner|avc'
mkdir -p "$OUT" "$SHOTS"

adb_() { "$ADB" -s "$SERIAL" "$@"; }
sh_() { "$ADB" -s "$SERIAL" shell "$@"; }

RESULTS=()
FAILED=0
record() { RESULTS+=("$1  $2 -- $3"); [ "$1" = PASS ] || FAILED=1; say "   [$1] $2 -- $3"; }
check() { local item=$1 detail=$2; shift 2; if "$@"; then record PASS "$item" "$detail"; else record FAIL "$item" "$detail"; fi; }
timing() { printf '%s\n' "$*" >> "$OUT/timings.txt"; say "   timing: $*"; }

app_pid() { sh_ pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}'; }
ps_snapshot() { sh_ ps -A -o PID,PPID,USER,LABEL,RSS,NAME,ARGS | tr -d '\r'; }
host_children() { awk -v p="$1" -v h="$HOST" '$2 == p && index($0, h) {print}'; }
all_hosts() { awk -v h="$HOST" 'NR > 1 && index($0, h) {print}'; }
host_pid() { awk -v p="$1" -v h="$HOST" -v m="--name $2" '$2 == p && index($0, h) && index($0, m) {print $1; exit}'; }
ui_dump() {
  sh_ uiautomator dump /sdcard/m5-ui.xml >/dev/null 2>&1 || true
  sh_ cat /sdcard/m5-ui.xml 2>/dev/null | tr -d '\r' > "$1" || true
  sh_ rm -f /sdcard/m5-ui.xml || true
}
ui_has() { grep -q "text=\"$2" "$1"; }
tap_text() {
  local b
  b=$(grep -o "text=\"$2\"[^>]*bounds=\"\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]\"" "$1" | head -1 \
      | sed 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \2 \3 \4/')
  [ -n "$b" ] || return 1
  read -r x1 y1 x2 y2 <<< "$b"
  sh_ input tap $(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))
}
# wait_log SECONDS REGEX: poll logcat until a line matches; prints it.
wait_log() {
  local secs=$1 re=$2 t0 line
  t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt "$secs" ]; do
    line=$(adb_ logcat -d -v threadtime 2>/dev/null | tr -d '\r' | grep -E "$re" | head -1 || true)
    if [ -n "$line" ]; then printf '%s\n' "$line"; return 0; fi
    sleep 2
  done
  return 1
}
save_logcat() {
  adb_ logcat -d -v threadtime | tr -d '\r' > "$OUT/logcat-$1.txt" || true
  grep -E " ($LOGTAGS)[ :]" "$OUT/logcat-$1.txt" > "$OUT/logcat-$1-excerpt.txt" || true
  adb_ logcat -d -b crash | tr -d '\r' > "$OUT/crash-$1.txt" || true
  say "   logcat: ${OUT#"$REPO_ROOT"/}/logcat-$1.txt ($(wc -l < "$OUT/logcat-$1.txt") lines, excerpt $(wc -l < "$OUT/logcat-$1-excerpt.txt"))"
}
fresh() {
  sh_ am force-stop "$PKG" || true
  adb_ logcat -c || true
  adb_ logcat -b crash -c 2>/dev/null || true
}
ensure_installed() {
  if [ -z "$(sh_ pm path "$PKG" 2>/dev/null | tr -d '\r')" ]; then adb_ install -r -t "$APK"; fi
}
# host_status PID: VmRSS/VmHWM/Threads of a child, read as the app's uid.
host_status() { sh_ run-as "$PKG" cat "/proc/$1/status" 2>/dev/null | tr -d '\r' | grep -E '^(Name|VmRSS|VmHWM|VmSize|Threads):' | tr '\n' ' ' || true; }
# top_sample PID: one "%CPU RES" sample over 2 s.
top_sample() { sh_ top -b -d 2 -n 2 -p "$1" -o PID,%CPU,RES,S,TIME+,ARGS 2>/dev/null | tr -d '\r' | grep -E "^ *$1 " | tail -1 || true; }

# ---- preflight
adb_ get-state >/dev/null 2>&1 || die "$SERIAL is not connected (bash scripts/android/emulator.sh start)"
[ "$(sh_ getprop sys.boot_completed | tr -d '\r')" = 1 ] || die "$SERIAL has not finished booting"
[ -f "$APK" ] && [ -f "$TEST_APK" ] || die "APKs missing: run scripts/android/build-apk.sh $ABI first"
say "-- device $SERIAL: API $(sh_ getprop ro.build.version.sdk | tr -d '\r' || true), $(sh_ getprop ro.product.cpu.abilist | tr -d '\r' || true), $(sh_ nproc | tr -d '\r' || true) CPUs; phases: ${PHASES[*]}"
say "-- /etc/resolv.conf on the device: $(sh_ ls -l /etc/resolv.conf 2>&1 | tr -d '\r' || true)"
adb_ logcat -G 64M >/dev/null 2>&1 || true
: > "$OUT/timings.txt"
has_phase() { printf '%s\n' "${PHASES[@]}" | grep -qx "$1"; }

# ======================================================================== install
phase_install() {
  step_begin "M5 install"
  local t0; t0=$(date +%s%N)
  adb_ install -r -t "$APK"
  adb_ install -r -t "$TEST_APK"
  timing "install (both APKs): $(( ($(date +%s%N) - t0) / 1000000 )) ms; demo APK $(stat -c %s "$APK") bytes"
  step_done m5-install "apk=$(sha256_of "$APK")"
}

# ======================================================================== demo
phase_demo() {
  step_begin "M5 demo: node from the app, devnet follower"
  ensure_installed
  fresh
  sh_ input keyevent KEYCODE_WAKEUP || true
  sh_ wm dismiss-keyguard || true
  # log_level debug: LOGOS_LOG_LEVEL=debug lets the hosts' Qt debug lines through, which show
  # bc_probe asking capability_module for a blockchain_module token (check 6b).
  local extra=(--ez bc_autorun true --ez bc_fresh true --ei bc_sync_timeout "$BC_TIMEOUT" --es log_level debug)
  [ -z "$BC_EXTERNAL" ] || extra+=(--es bc_external "$BC_EXTERNAL")
  local t0 line pid bcpid probepid ui ex
  t0=$(date +%s)
  sh_ am start -W -n "$PKG/.MainActivity" "${extra[@]}" | tr -d '\r' > "$OUT/am-start-demo.txt"
  # Start sampling the blockchain host once it exists.
  line=$(wait_log 120 'LogosDemo: BC load blockchain_module' || echo "(no load line)")
  say "   ${line##*LogosDemo: }"
  pid=$(app_pid || true)
  ps_snapshot > "$OUT/ps-demo-loaded.txt"
  bcpid=$(host_pid "$pid" blockchain_module < "$OUT/ps-demo-loaded.txt" || true)
  probepid=$(host_pid "$pid" bc_probe < "$OUT/ps-demo-loaded.txt" || true)
  say "   app pid $pid; blockchain_module host $bcpid; bc_probe host $probepid"
  : > "$OUT/top-bc.txt"
  local tapped=0 tap_line="" started="" done_line=""
  while [ $(( $(date +%s) - t0 )) -lt $(( BC_TIMEOUT + 180 )) ]; do
    [ -z "$bcpid" ] || printf '%s +%ss %s | %s\n' "$(date +%T)" $(( $(date +%s) - t0 )) "$(top_sample "$bcpid")" "$(host_status "$bcpid")" >> "$OUT/top-bc.txt"
    adb_ logcat -d -v threadtime | tr -d '\r' > "$OUT/.lc"
    started=$(grep -m1 -o 'LogosDemo: BC start() returned.*' "$OUT/.lc" || true)
    # 7: during the sync (start() returned, not yet synced), tap "Load hello".
    if [ "$tapped" = 0 ] && [ -n "$started" ] && ! grep -q 'LogosDemo: BC SYNCED' "$OUT/.lc"; then
      ui="$OUT/ui-demo-syncing.xml"; ui_dump "$ui"
      adb_ exec-out screencap -p > "$SHOTS/m5-syncing.png" || true
      local ta; ta=$(date +%s%N)
      if tap_text "$ui" "Load hello" && tap_line=$(wait_log 20 'LogosDemo: loadModule\(hello_module\) -> '); then
        timing "tap 'Load hello' during the sync -> hello_module loaded: $(( ($(date +%s%N) - ta) / 1000000 )) ms (host side, 2 s logcat polling)"
        tapped=1
      else
        tapped=2
      fi
    fi
    done_line=$(grep -m1 -oE 'LogosDemo: BC AUTORUN (OK|FAILED).*' "$OUT/.lc" || true)
    [ -z "$done_line" ] || break
    sleep 3
  done
  rm -f "$OUT/.lc"
  timing "autorun finished after $(( $(date +%s) - t0 )) s: ${done_line:-no BC AUTORUN line}"
  sleep 3
  ps_snapshot > "$OUT/ps-demo-synced.txt"
  pid=$(app_pid || true)
  local kids; kids=$(host_children "$pid" < "$OUT/ps-demo-synced.txt")
  printf '%s\n' "$kids" | sed 's/ --instance-persistence-path [^ ]*//' | while read -r l; do say "   child: $l"; done
  bcpid=$(host_pid "$pid" blockchain_module < "$OUT/ps-demo-synced.txt" || true)
  ui="$OUT/ui-demo-synced.xml"; ui_dump "$ui"
  adb_ exec-out screencap -p > "$SHOTS/m5-blockchain.png" || true
  # following the head: a few more CPU samples, then resource snapshots
  for _ in 1 2 3; do printf '%s following %s | %s\n' "$(date +%T)" "$(top_sample "$bcpid")" "$(host_status "$bcpid")" >> "$OUT/top-bc.txt"; sleep 5; done
  host_status "$bcpid" > "$OUT/status-bc.txt"
  sh_ top -b -n 1 -o PID,PPID,%CPU,RES,S,ARGS | tr -d '\r' | grep -E "PID|$PKG|$HOST" > "$OUT/top-snapshot.txt" || true
  sh_ dumpsys meminfo "$PKG" | tr -d '\r' > "$OUT/meminfo-app.txt" || true
  sh_ run-as "$PKG" du -sk files/blockchain files/blockchain/db files/blockchain/state files/blockchain/logs files/modules files/work files/persist cache 2>&1 | tr -d '\r' > "$OUT/du.txt" || true
  sh_ run-as "$PKG" ls -la files/work 2>&1 | tr -d '\r' >> "$OUT/du.txt" || true
  sh_ run-as "$PKG" ls -l "/proc/$bcpid/cwd" 2>&1 | tr -d '\r' >> "$OUT/du.txt" || true
  sh_ run-as "$PKG" cat files/blockchain/user_config.yaml 2>/dev/null | tr -d '\r' > "$OUT/user_config.yaml" || true
  save_logcat demo
  ex="$OUT/logcat-demo.txt"

  local l
  check "1a blockchain_module in its own $HOST child" "$(grep -c . <<< "$kids" || true) children of app pid $pid; blockchain_module pid ${bcpid:-none}" \
    eval '[ -n "$bcpid" ] && grep -q -- "--name blockchain_module" <<< "$kids"'
  check "1b bc_probe in its own $HOST child" "$(grep -o -- '--name bc_probe' <<< "$kids" | head -1 || echo none)" \
    grep -q -- '--name bc_probe' <<< "$kids"
  l=$(grep -m1 -o 'LogosDemo: BC config: .*' "$ex" || echo 'no config line')
  check "2a config generated + follower mode merged" "${l:0:400}" grep -q "31536000" <<< "$l"
  l=$(grep -m1 -o 'LogosDemo: BC start() returned after [0-9]* ms' "$ex" || echo 'no start() line')
  check "2b node started from the app" "${l#LogosDemo: }" grep -q 'returned' <<< "$l"
  l=$(grep -m1 -o 'LogosDemo: BC first peer after .*' "$ex" || echo 'no first-peer line')
  check "3 n_peers > 0" "${l#LogosDemo: }" grep -q 'nPeers=[1-9]' <<< "$l"
  l=$(grep -m1 -o 'LogosDemo: BC SYNCED .*' "$ex" || echo 'no SYNCED line')
  check "4 height reaches the devnet tip" "${l#LogosDemo: }" grep -q 'SYNCED height=[1-9]' <<< "$l"
  l=$(grep -m1 -o 'LogosDemo: BC first newBlock event .*' "$ex" || echo 'no newBlock line')
  check "5 newBlock events reach Kotlin" "${l:0:300}" grep -q 'first newBlock' <<< "$l"
  check "6a bc_probe -> blockchain_module returns the live height" "${done_line#LogosDemo: }" \
    grep -qE 'probe_height=[1-9]' <<< "$done_line"
  l=$(grep -E 'logos-stdio.*bc_probe.*(<-|->) blockchain_module' "$ex" | tail -1 | sed 's/.*logos-stdio: //' || true)
  local tok; tok=$(grep -E 'logos-stdio.*\[(bc_probe|blockchain_module|capability_module)\].*(requestModule|informModuleToken|Informing module token)' "$ex" \
    | head -4 | sed 's/.*logos-stdio: //' | cut -c1-220 | tr '\n' ' ' || true)
  printf '%s\n' "$tok" > "$OUT/token-evidence.txt"
  check "6b cross-module call + capability token in the logs" "call: ${l:0:260} | token: ${tok:0:700}" \
    eval '[ -n "$l" ] && grep -q "requestModule" <<< "$tok"'
  # 7: responsiveness
  local anr frames janky skipped
  sh_ dumpsys gfxinfo "$PKG" | tr -d '\r' > "$OUT/gfxinfo.txt" || true
  frames=$(sed -n 's/^Total frames rendered: //p' "$OUT/gfxinfo.txt" | head -1)
  janky=$(sed -n 's/^Janky frames: //p' "$OUT/gfxinfo.txt" | head -1)
  skipped=$(grep -E "Choreographer.*Skipped [0-9]+ frames" "$ex" | sed 's/.*Skipped \([0-9]*\) frames.*/\1/' | sort -n | tail -1 || true)
  anr=$(adb_ logcat -d -b events | tr -d '\r' | grep -E "am_anr.*$PKG" || true)
  anr+=$(grep -E "ANR in $PKG" "$ex" || true)
  check "7a UI serves a tap during the sync" "${tap_line##*LogosDemo: }" test "$tapped" = 1
  check "7b no ANR" "frames ${frames:-?}, janky ${janky:-?}; worst Choreographer skip ${skipped:-none} frames" test -z "$anr"
  check "UI shows the synced node" "ui dump: $(grep -oE 'text="(height|peers|via bc_probe)[^"]*"' "$ui" | tr '\n' ' ' || true)" \
    grep -qE 'text="via bc_probe: height [1-9]' "$ui"

  # timings from the app log
  grep -oE 'LogosDemo: (started: .*|modules dir .*|BC load .*|BC start\(\) returned.*|BC first peer after [0-9]+ ms|BC SYNCED .*|BC first newBlock event after [0-9]+ ms|BC STATUS .*)' "$ex" \
    | sed 's/^LogosDemo: //' | grep -vE '^BC STATUS' | while IFS= read -r t; do timing "demo: ${t:0:300}"; done || true
  grep -oE 'LogosDemo: BC STATUS .*' "$ex" | sed 's/^LogosDemo: //' > "$OUT/status-lines.txt" || true
  timing "demo: $(wc -l < "$OUT/status-lines.txt") STATUS lines; last: $(tail -1 "$OUT/status-lines.txt")"
  timing "blockchain host at the end: $(cat "$OUT/status-bc.txt")"
  timing "disk: $(head -8 "$OUT/du.txt" | tr '\n' ' ')"

  # ---- 8a: the node's stop(), then the runtime's Stop
  adb_ logcat -c || true
  local ts; ts=$(date +%s%N)
  sh_ am start -n "$PKG/.MainActivity" --es bc_action stop >/dev/null
  l=$(wait_log 90 'LogosDemo: BC stop\(\) returned' || echo '(no stop line within 90 s)')
  timing "node stop via intent -> 'stop() returned' logged: $(( ($(date +%s%N) - ts) / 1000000 )) ms: ${l##*LogosDemo: }"
  sleep 2
  ps_snapshot > "$OUT/ps-node-stopped.txt"
  local kids_node; kids_node=$(host_children "$pid" < "$OUT/ps-node-stopped.txt")
  ui_dump "$OUT/ui-node-stopped.xml"
  adb_ exec-out screencap -p > "$SHOTS/m5-node-stopped.png" || true
  check "8a node stop() returns; blockchain host stays loaded" "${l##*LogosDemo: }; hosts: $(grep -c . <<< "$kids_node" || true)" \
    eval 'grep -q "stop() returned" <<< "$l" && grep -q -- "--name blockchain_module" <<< "$kids_node"'
  ts=$(date +%s%N)
  if tap_text "$OUT/ui-node-stopped.xml" "Stop" && l=$(wait_log 60 'LogosDemo: stopped: '); then
    timing "runtime Stop tap -> 'stopped' logged: $(( ($(date +%s%N) - ts) / 1000000 )) ms"
  else
    l="(no 'stopped:' line within 60 s of the Stop tap)"
  fi
  sleep 2
  ps_snapshot > "$OUT/ps-demo-stopped.txt"
  local kids_after pid_after; kids_after=$(host_children "$pid" < "$OUT/ps-demo-stopped.txt"); pid_after=$(app_pid || true)
  adb_ exec-out screencap -p > "$SHOTS/m5-stopped.png" || true
  save_logcat demo-stop
  check "8b runtime stop() leaves no child" "${l##*LogosDemo: }; app pid $pid_after (was $pid); children left: $(grep -c . <<< "$kids_after" || true)" \
    eval 'grep -q "stopped: true" <<< "$l" && [ "$pid_after" = "$pid" ] && [ -z "$kids_after" ]'
  step_done m5-demo "pid=$pid"
}

# ======================================================================== kill
phase_kill() {
  step_begin "M5 restart on synced state, then am force-stop"
  ensure_installed
  fresh
  local extra=(--ez bc_autorun true --ei bc_sync_timeout 300)
  [ -z "$BC_EXTERNAL" ] || extra+=(--es bc_external "$BC_EXTERNAL")
  sh_ am start -W -n "$PKG/.MainActivity" "${extra[@]}" >/dev/null
  local l pid kids left t0
  l=$(wait_log 600 'LogosDemo: BC (start\(\) returned|start FAILED|AUTORUN FAILED)' || echo '(no start line)')
  timing "restart on the synced node dir: ${l##*LogosDemo: }"
  wait_log 120 'LogosDemo: BC first peer' >/dev/null || true
  sleep 5
  pid=$(app_pid || true)
  ps_snapshot > "$OUT/ps-kill-before.txt"
  kids=$(host_children "$pid" < "$OUT/ps-kill-before.txt")
  t0=$(date +%s%N)
  sh_ am force-stop "$PKG"
  for _ in $(seq 1 20); do
    ps_snapshot > "$OUT/ps-kill-after.txt"
    left=$( { all_hosts < "$OUT/ps-kill-after.txt"; grep -F "$PKG" "$OUT/ps-kill-after.txt" || true; } )
    [ -z "$left" ] && break
    sleep 0.5
  done
  timing "am force-stop -> app and module hosts gone: $(( ($(date +%s%N) - t0) / 1000000 )) ms"
  save_logcat kill
  check "8c restart replays and starts" "${l##*LogosDemo: }" grep -q 'start() returned' <<< "$l"
  check "8d no child survives am force-stop of a running node" "before: $(grep -c . <<< "$kids" || true) children of pid $pid; after: ${left:-none}" \
    eval '[ -n "$kids" ] && [ -z "$left" ]'
  step_done m5-kill "pid=$pid"
}

# ======================================================================== test
phase_test() {
  step_begin "M5 instrumented test (BlockchainAcceptanceTest)"
  fresh
  local t0 rc=0 res
  t0=$(date +%s)
  sh_ am instrument -w -r -e blockchain 1 -e class com.fryorcraken.logoslib.demo.BlockchainAcceptanceTest \
    "$PKG.test/androidx.test.runner.AndroidJUnitRunner" | tr -d '\r' > "$OUT/instrument.txt" || rc=$?
  timing "am instrument BlockchainAcceptanceTest: $(( $(date +%s) - t0 )) s (rc=$rc)"
  save_logcat test
  res=$(grep -E '^(OK \(|FAILURES!!!|Tests run:)' "$OUT/instrument.txt" | tr '\n' ' ' || true)
  grep -E 'INSTRUMENTATION_STATUS: test=' "$OUT/instrument.txt" | sort -u | sed 's/^/   /' | while read -r x; do say "   $x"; done || true
  grep -oE 'LogosM5Test: (TIMING .*|module host children after .*)' "$OUT/logcat-test.txt" | sed 's/^LogosM5Test: /test: /' \
    | while IFS= read -r t; do timing "${t:0:300}"; done || true
  check "instrumented test" "BlockchainAcceptanceTest: ${res:-no result line} (see instrument.txt)" grep -q '^OK (10 tests)' "$OUT/instrument.txt"
  step_done m5-test "rc=$rc"
}

for p in install demo kill test; do
  if has_phase "$p"; then "phase_$p"; fi
done

{
  echo "# M5/M6 on $SERIAL ($ABI), $(date -Is)"
  printf '%s\n' "${RESULTS[@]}"
  echo
  echo "# timings"
  cat "$OUT/timings.txt"
} > "$OUT/summary.txt"
say "-- summary: ${OUT#"$REPO_ROOT"/}/summary.txt; screenshots in ${SHOTS#"$REPO_ROOT"/}"
if [ "$FAILED" = 0 ]; then
  say "run-m5: OK (${#RESULTS[@]} checks passed)"
else
  say "run-m5: FAILED ($(printf '%s\n' "${RESULTS[@]}" | grep -c '^FAIL') of ${#RESULTS[@]} checks failed)"
  exit 1
fi
