#!/usr/bin/env bash
# qt-jvmless X2: install both APK variants on emulator-5570 and run the test matrix.
# Full output -> logs/x2-run.log ; per-run logcat -> logs/x2-<run>.logcat
set -u
EXP=${REPO_ROOT}/.work/experiments/qt-jvmless
LOG="$EXP/logs/x2-run.log"
exec 3>&1 > "$LOG" 2>&1
trap 'grep -E "^(====|----)|RESULT|LOADLIBRARY|HELPER|READY seen|socket exists|posix_spawn|child> .*(PLUGIN|setRegistryUrl|FAIL|libart)|Fatal signal|>>> |LEFTOVER|untrusted_app:s0:[c0-9,]+ +(libqro_server.so|org.logos.qrotest)|AVC_SUMMARY|u:object_r:.*qro_t|Success|Failure" "$LOG" | grep -v "avc:" >&3' EXIT
ADB="/usr/bin/adb -s emulator-5570"
APP="$EXP/app/app/build/outputs/apk"
date -Is
echo "==== install"
$ADB install -r "$APP/withjar/debug/app-withjar-debug.apk"
$ADB install -r "$APP/nojar/debug/app-nojar-debug.apk"

run() {
  local name="$1" pkg="$2"; shift 2
  echo
  echo "==== $name: $pkg $*"
  $ADB shell am force-stop "$pkg"
  sleep 1
  $ADB logcat -c
  $ADB logcat -b crash -c
  $ADB shell am start -W -n "$pkg/org.logos.qrotest.MainActivity" "$@" | grep -E 'Status|Activity'
  for i in $(seq 1 30); do
    if $ADB logcat -d -s qrotest:I | grep -q -E 'RESULT'; then break; fi
    if $ADB logcat -d -b crash | grep -q -E "Cmdline: $pkg"; then break; fi
    sleep 1
  done
  sleep 1
  $ADB logcat -d > "$EXP/logs/x2-$name.logcat"
  $ADB logcat -d -b crash > "$EXP/logs/x2-$name.crash"
  echo "---- app log (tag qrotest)"
  $ADB logcat -d -s qrotest:I | grep -v '^---------'
  echo "---- jni/child/QtCore/AndroidRuntime"
  grep -E ' (qrotest_jni|qrotest-child|qro_server|QtCore|AndroidRuntime)' "$EXP/logs/x2-$name.logcat" | grep -v -E 'It is recommended|qrotest-child' | head -40
  echo "---- avc"
  grep -E 'avc: *denied' "$EXP/logs/x2-$name.logcat" | grep -E 'qrotest|qro_server|untrusted_app' | head -10
  echo "AVC_SUMMARY app-domain denials: total=$(grep -E 'avc: *denied' "$EXP/logs/x2-$name.logcat" | grep -c 'untrusted_app') other-than-linker-tests-dir-search=$(grep -E 'avc: *denied' "$EXP/logs/x2-$name.logcat" | grep 'untrusted_app' | grep -v -c 'name="tests"')"
  echo "---- crash buffer"
  grep -E 'Cmdline|signal|Abort|#0[0-9] ' "$EXP/logs/x2-$name.crash" | head -20
  echo "---- processes (ps -A)"
  $ADB shell "ps -A -o PID,PPID,USER,LABEL,NAME" | grep -E 'qro|PID'
  echo "---- cache dir"
  $ADB shell "run-as $pkg ls -laZ cache" 2>&1 | head -10
  $ADB shell am force-stop "$pkg"
  sleep 1
  echo "---- after force-stop: LEFTOVER helper processes:"
  $ADB shell "ps -A -o PID,PPID,USER,NAME" | grep -E 'qro_server' || echo "(none)"
}

A=org.logos.qrotest.a
B=org.logos.qrotest.b
run R1-A-default      $A
run R2-B-realvm       $B
run R3-B-none         $B --es jvmMode none
run R4-B-noonload     $B --es jvmMode none --es jniLib qrotest_jni_noonload
run R5-A-abstract     $A --es url localabstract:qro_t
run R6-A-childnoshim  $A --es serverJvmMode none
run R7-B-shim         $B --es jvmMode shim
run R8-A-nativespawn  $A --es spawn native
run R9-B-nativespawn  $B --es spawn native
date -Is
