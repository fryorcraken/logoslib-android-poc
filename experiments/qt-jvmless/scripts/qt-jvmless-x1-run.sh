#!/usr/bin/env bash
# qt-jvmless X1.3: push qro_server/qro_client/plugin + Qt libs to /data/local/tmp/q on
# emulator-5570 and run them as plain native executables (adb shell, no JavaVM).
# Full output -> logs/x1-run.log ; crash buffer -> logs/x1-crash.log
set -u
EXP=${REPO_ROOT}/.work/experiments/qt-jvmless
mkdir -p "$EXP/logs"
LOG="$EXP/logs/x1-run.log"
exec 3>&1 > "$LOG" 2>&1
trap 'grep -E "^(====|----)|RC=|RESULT|PLUGIN|setRegistryUrl|enableRemoting|READY|jvm-mode|probe .*:|tempPath|Segmentation|exec\(\)|SIGTERM|avc|srw|context=" "$LOG" >&3' EXIT
ADB="/usr/bin/adb -s emulator-5570"
QT=${REPO_ROOT}/.work/probe/qt/6.11.1/android_x86_64
NDK=${HOME}/android-ndk/android-ndk-r27c
B="$EXP/build/x86_64"
D=/data/local/tmp/q
RUN="cd $D && export TMPDIR=$D LD_LIBRARY_PATH=$D"
date -Is
$ADB shell "rm -rf $D; mkdir -p $D"
for f in "$B/qro_server" "$B/qro_client" "$B/libechoplugin.so" \
         "$QT/lib/libQt6Core_x86_64.so" "$QT/lib/libQt6Network_x86_64.so" "$QT/lib/libQt6RemoteObjects_x86_64.so" \
         "$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android/libc++_shared.so"; do
  $ADB push "$f" "$D/" | tail -1
done
$ADB shell "chmod 755 $D/qro_server $D/qro_client; ls -laZ $D"
$ADB logcat -c
$ADB logcat -b crash -c

echo
echo "================ T0a: server --jvm-mode=none (stock QtCore, no JavaVM)"
$ADB shell "$RUN && ./qro_server --jvm-mode=none --exit-after-ms=500; echo SERVER_RC=\$?"
echo "================ T0b: server --jvm-mode=appversion (setApplicationVersion before QCoreApplication)"
$ADB shell "$RUN && ./qro_server --jvm-mode=appversion --exit-after-ms=500; echo SERVER_RC=\$?"

echo
echo "================ T1: shell domain, --jvm-mode=shim, url=localabstract:qro_t"
$ADB shell "$RUN && (./qro_server --jvm-mode=shim --url=localabstract:qro_t --exit-after-ms=10000 > $D/server.out 2>&1 &) ; sleep 2; QJL_JVM_MODE=shim ./qro_client localabstract:qro_t 8000; echo CLIENT_RC=\$?; echo '---- second client (new process, same server)'; QJL_JVM_MODE=shim ./qro_client localabstract:qro_t 8000; echo CLIENT2_RC=\$?"
sleep 9
echo "---- server output"
$ADB shell "cat $D/server.out"

echo
echo "================ T1r: root (su), --jvm-mode=shim, url=local:qro_t (filesystem socket in TMPDIR=$D)"
$ADB shell "su 0 sh -c 'id; $RUN && (./qro_server --jvm-mode=shim --url=local:qro_t --exit-after-ms=8000 > $D/server_r.out 2>&1 &) ; sleep 2; ls -laZ $D/qro_t; QJL_JVM_MODE=shim ./qro_client local:qro_t 6000; echo CLIENT_RC=\$?'"
sleep 7
echo "---- server output"
$ADB shell "cat $D/server_r.out; ls -la $D/qro_t 2>&1"

echo
echo "================ T2: SIGTERM shutdown (self-pipe QSocketNotifier, as logos_host_qt)"
$ADB shell "$RUN && (./qro_server --jvm-mode=shim --url=localabstract:qro_t > $D/server2.out 2>&1 &) ; sleep 2; QJL_JVM_MODE=shim ./qro_client localabstract:qro_t 5000 > /dev/null; echo CLIENT_RC=\$?; pkill -TERM -x qro_server; sleep 1; tail -3 $D/server2.out"

echo
echo "================ T3: root, TMPDIR unset, url=local:qro_t (QDir::tempPath fallback)"
$ADB shell "su 0 sh -c 'cd $D && env -u TMPDIR LD_LIBRARY_PATH=$D ./qro_server --jvm-mode=shim --exit-after-ms=500 2>&1' | grep -E 'tempPath|setRegistryUrl|Listen|QTRO|READY|exec'"

echo
echo "================ T4: JNI-backed Qt Core APIs under the shim (each its own process)"
for p in androidctx stdpaths timezone locale sysinfo; do
  echo "---- probe $p (shim)"
  $ADB shell "$RUN && ./qro_server --jvm-mode=shim --probe=$p > $D/probe.out 2>&1; echo PROBE_RC=\$?; grep -E 'probe' $D/probe.out"
done

echo
echo "================ logcat: crash buffer (saved to x1-crash.log)"
$ADB logcat -d -b crash > "$EXP/logs/x1-crash.log"
grep -E 'Cmdline' "$EXP/logs/x1-crash.log"
echo "================ logcat: avc denials"
$ADB logcat -d | grep -E 'avc: *denied' | tail -20
date -Is
