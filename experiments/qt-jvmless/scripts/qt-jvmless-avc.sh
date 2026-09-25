#!/usr/bin/env bash
# qt-jvmless: show SELinux denials on emulator-5570 (logcat + dmesg), plus a raw
# unix-socket bind test in /data/local/tmp from the shell domain.
set -u
EXP=${REPO_ROOT}/.work/experiments/qt-jvmless
exec > >(tee "$EXP/logs/avc.log") 2>&1
ADB="/usr/bin/adb -s emulator-5570"
echo "== logcat avc denied =="
$ADB logcat -d | grep -E 'avc: *denied' | tail -30
echo "== dmesg via root? =="
$ADB root
sleep 3
$ADB wait-for-device
$ADB shell dmesg | grep -E 'avc: *denied' | tail -30
$ADB unroot
sleep 3
$ADB wait-for-device
echo "== shell domain: toybox nc -L unix socket bind test in /data/local/tmp/q =="
$ADB shell 'id -Z; ls -laZ /data/local/tmp/q | head -3'
$ADB shell 'cd /data/local/tmp/q && (timeout 2 toybox nc -U -L /data/local/tmp/q/nc_t true 2>&1; echo nc_rc=$?) ; ls -laZ /data/local/tmp/q/nc_t 2>&1'
$ADB logcat -d | grep -E 'avc: *denied' | tail -10
