#!/usr/bin/env bash
# qt-jvmless X1 T2 (re-run): SIGTERM -> self-pipe QSocketNotifier -> quit, JVM-less.
set -u
EXP=${REPO_ROOT}/.work/experiments/qt-jvmless
exec > >(tee "$EXP/logs/x1-t2.log") 2>&1
ADB="/usr/bin/adb -s emulator-5570"
D=/data/local/tmp/q
RUN="cd $D && export TMPDIR=$D LD_LIBRARY_PATH=$D"
$ADB shell "$RUN && (./qro_server --jvm-mode=shim --url=localabstract:qro_t > $D/server2.out 2>&1 &) ; sleep 2; QJL_JVM_MODE=shim ./qro_client localabstract:qro_t 5000 | grep RESULT; echo CLIENT_RC=\$?; pidof qro_server; pkill -TERM -x qro_server; sleep 1; echo after-kill pidof=\$(pidof qro_server); tail -3 $D/server2.out"
