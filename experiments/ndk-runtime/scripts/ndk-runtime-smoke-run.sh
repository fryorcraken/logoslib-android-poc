#!/usr/bin/env bash
# ndk-runtime: run the container smoke test on the x86_64 API 34 emulator
# (adb shell context). Starts a private read-only instance of AVD delivery-demo
# on port 5584 (so it cannot collide with another session's emulator-5554),
# and kills it afterwards if this script started it.
set -u
W=${REPO_ROOT}/.work/experiments/ndk-runtime
SDK=${HOME}/android-sdk
ADB=/usr/bin/adb
PORT=5584
SERIAL=emulator-$PORT
LOG=$W/logs/smoke-run.log
export TMPDIR=$W/tmp
mkdir -p "$W/logs" "$TMPDIR"
exec 3>&1 >"$LOG" 2>&1
trap 'grep -E "^(PASS|FAIL|SUMMARY|RUN|ORPHAN|DEVICE|INFO (launch|missing|pthread_atfork|=>|parent fds)|APPLOG (PASS|FAIL|SUMMARY|APP|LINGER|INFO (launch|pthread|=>|parent fds))|APPLOG .*PROBE (pid|fds)|FDENUM (SUMMARY|FAIL|EXIT|INFO parent fds|.*PROBE fds))" "$LOG" >&3' EXIT
date -Is

STARTED=0
if ! $ADB devices | grep -q "^$SERIAL"; then
  echo "starting emulator on $PORT"
  # -no-window cold boot SIGSEGVs qemu-system-x86_64-headless on this host
  # (wallet-android-emu-start.sh); the windowed binary under setsid boots in ~25s.
  export ANDROID_SDK_ROOT=$SDK ANDROID_HOME=$SDK
  nohup setsid "$SDK/emulator/emulator" -avd delivery-demo -read-only -no-audio \
    -no-boot-anim -no-snapshot-save -port $PORT \
    > "$W/logs/emulator-$PORT.log" 2>&1 < /dev/null &
  STARTED=1
fi
timeout 180 $ADB -s $SERIAL wait-for-device || { echo "RUN no device"; exit 1; }
for i in $(seq 1 150); do
  [ "$($ADB -s $SERIAL shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 2
done
echo "DEVICE sdk=$($ADB -s $SERIAL shell getprop ro.build.version.sdk | tr -d '\r') abi=$($ADB -s $SERIAL shell getprop ro.product.cpu.abi | tr -d '\r') kernel=$($ADB -s $SERIAL shell uname -r | tr -d '\r') page=$($ADB -s $SERIAL shell getconf PAGE_SIZE | tr -d '\r')"

D=/data/local/tmp/ndk-runtime
$ADB -s $SERIAL shell "rm -rf $D; mkdir -p $D/modules $D/persist"
for f in ndk_smoke ndk_smoke_fdenum liblogos_host_probe.so liblogos_host_qt.so libspdlog.so libfmt.so libc++_shared.so libndkrt_activity.so; do
  $ADB -s $SERIAL push "$W/out/x86_64/$f" "$D/$f" >/dev/null || echo "push $f failed"
done
$ADB -s $SERIAL shell "chmod 755 $D/ndk_smoke $D/ndk_smoke_fdenum $D/liblogos_host_probe.so $D/liblogos_host_qt.so; echo placeholder > $D/fake_plugin.so; ls -la $D"

echo "================ RUN fdenum (container with POSIX_SPAWN_CLOEXEC_DEFAULT hidden -> /proc/self/fd fallback)"
$ADB -s $SERIAL shell "cd $D && LD_LIBRARY_PATH=$D ./ndk_smoke_fdenum $D/liblogos_host_probe.so; echo EXIT=\$?" | sed 's/^/FDENUM /'

echo "================ RUN main"
$ADB -s $SERIAL shell "cd $D && LD_LIBRARY_PATH=$D TMPDIR=$D ./ndk_smoke $D/liblogos_host_probe.so; echo EXIT=\$?"
echo "RUN main done"

echo "================ RUN orphan (parent dies without terminate)"
OUT=$($ADB -s $SERIAL shell "cd $D && LD_LIBRARY_PATH=$D ./ndk_smoke $D/liblogos_host_probe.so orphan; echo EXIT=\$?")
echo "$OUT"
CPID=$(echo "$OUT" | sed -n 's/^ORPHAN_CHILD_PID=\([0-9]*\).*/\1/p')
sleep 2
if [ -n "$CPID" ]; then
  if $ADB -s $SERIAL shell "test -d /proc/$CPID && cat /proc/$CPID/cmdline" | grep -q liblogos_host_probe; then
    echo "ORPHAN child $CPID STILL ALIVE after parent death -> FAIL"
    $ADB -s $SERIAL shell "kill -9 $CPID"
  else
    echo "ORPHAN child $CPID gone after parent death (PR_SET_PDEATHSIG/watchdog) -> PASS"
  fi
else
  echo "ORPHAN no child pid captured"
fi

echo "================ RUN app context (NativeActivity APK, untrusted_app)"
PKG=dev.ndkruntime.smoke
APK=$W/apk/ndkrt-smoke.apk
if [ -f "$APK" ]; then
  $ADB -s $SERIAL logcat -c
  $ADB -s $SERIAL uninstall $PKG >/dev/null 2>&1
  $ADB -s $SERIAL install -r "$APK" && echo "RUN app installed"
  $ADB -s $SERIAL shell "dumpsys package $PKG | grep -E 'legacyNativeLibraryDir|nativeLibraryDir|primaryCpuAbi|targetSdk|flags=' | head"
  $ADB -s $SERIAL shell "ls -la \$(dirname \$(pm path $PKG | sed 's/package://'))/lib/x86_64"
  $ADB -s $SERIAL shell am start -W -n $PKG/android.app.NativeActivity
  for i in $(seq 1 30); do
    $ADB -s $SERIAL logcat -d -s ndkrt:I | grep -q 'smoke_main rc=' && break
    sleep 1
  done
  echo "--- app smoke.log"
  $ADB -s $SERIAL shell "run-as $PKG cat files/smoke.log" | sed 's/^/APPLOG /'
  APPPID=$($ADB -s $SERIAL shell pidof $PKG | tr -d '\r')
  LPID=$($ADB -s $SERIAL shell "run-as $PKG cat files/smoke.log" | sed -n 's/^LINGER_CHILD_PID=\([0-9]*\).*/\1/p' | tr -d '\r')
  echo "RUN app pid=$APPPID linger host pid=$LPID"
  $ADB -s $SERIAL shell "ps -A -Z -o LABEL,USER,PID,PPID,PGID,SID,NAME | grep -E 'ndkruntime|liblogos_host|LABEL'" | sed 's/^/RUN ps: /'
  if [ -n "$LPID" ] && [ -n "$APPPID" ]; then
    $ADB -s $SERIAL shell "run-as $PKG kill -9 $APPPID"
    sleep 2
    if $ADB -s $SERIAL shell "test -d /proc/$LPID && cat /proc/$LPID/cmdline" 2>/dev/null | grep -q liblogos_host; then
      echo "RUN app ORPHAN: host $LPID STILL ALIVE after app process SIGKILL -> FAIL"
    else
      echo "RUN app ORPHAN: host $LPID gone after app process SIGKILL -> PASS"
    fi
  fi
  echo "--- logcat (avc / ndkrt / crash)"
  $ADB -s $SERIAL logcat -d | grep -i -E 'avc:|ndkrt|liblogos_host|seccomp|SIGSYS' | tail -60
else
  echo "RUN app skipped: no $APK"
fi

if [ $STARTED = 1 ]; then
  $ADB -s $SERIAL emu kill
  echo "emulator $SERIAL stopped"
fi
date -Is
