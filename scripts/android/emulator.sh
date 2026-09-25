#!/usr/bin/env bash
# scripts/android/emulator.sh -- start, stop or query the x86_64 API 34 test emulator.
#
# Runs a private, read-only instance of an existing AVD on a fixed console port, so it can
# neither modify the AVD nor collide with an emulator another session started on the
# default port. Only one emulator may run on this host at a time: `start` refuses if a
# qemu-system process for another port is already running.
#
# Why -qt-hide-window and not -no-window: on this host `emulator -no-window` (with or
# without -gpu swiftshader_indirect) SIGSEGVs during cold boot, right after "Failed to load
# snapshot default_boot" (docs/research/exp-qt-jvmless.md, "Emulator"). The windowed qemu
# binary with its Qt window hidden boots fine (~30-60 s) and `adb exec-out screencap`
# still works, because screenshots come from the guest's SurfaceFlinger.
#
# Command line used (started detached with setsid nohup):
#   $ANDROID_SDK_ROOT/emulator/emulator -avd $EMU_AVD -read-only -port $EMU_PORT \
#     -no-audio -no-boot-anim -no-snapshot-save -qt-hide-window
#
# Inputs (environment, all optional):
#   EMU_AVD        AVD name                  (default delivery-demo: x86_64, API 34 Google APIs)
#   EMU_PORT       console port; the adb serial is emulator-<port>  (default 5570)
#   EMU_BOOT_TIMEOUT  seconds to wait for sys.boot_completed        (default 300)
#   ADB            adb binary                (default $ANDROID_SDK_ROOT/platform-tools/adb)
#   plus everything env.sh reads (ANDROID_SDK_ROOT, ...).
# Outputs
#   build/logs/emulator-console.log   the emulator's own stdout/stderr
#   build/logs/emulator-<abi>.log     this script's log
# Pinned versions: none of its own (the AVD's system image is whatever the SDK has); the
#   M4 acceptance ran on delivery-demo = system-images;android-34;google_apis;x86_64.
#
# Usage
#   bash scripts/android/emulator.sh start    # boot (no-op if already booted); prints the serial
#   bash scripts/android/emulator.sh status   # adb state, boot_completed, API level, ABI
#   bash scripts/android/emulator.sh stop     # adb emu kill, then wait for qemu to exit
# Re-runnable: `start` on a running instance and `stop` on a stopped one do nothing.
set -Eeuo pipefail

ACTION="${1:-status}"
case "$ACTION" in
  start|stop|status) ;;
  -h|--help) sed -n '2,/^set -Eeuo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 0 ;;
  *) echo "emulator.sh: unknown action '$ACTION' (start|stop|status; see --help)" >&2; exit 2 ;;
esac
export ABI="${ABI:-x86_64}"
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
log_setup emulator
trap 'on_error emulator' ERR

EMU_AVD="${EMU_AVD:-delivery-demo}"
EMU_PORT="${EMU_PORT:-5570}"
EMU_BOOT_TIMEOUT="${EMU_BOOT_TIMEOUT:-300}"
SERIAL="emulator-$EMU_PORT"
ADB="${ADB:-$ANDROID_SDK_ROOT/platform-tools/adb}"
[ -x "$ADB" ] || ADB=$(command -v adb) || die "adb not found (set ADB or install platform-tools)"
EMULATOR="$ANDROID_SDK_ROOT/emulator/emulator"
CONSOLE_LOG="$LOG_DIR/emulator-console.log"
export ANDROID_HOME="$ANDROID_SDK_ROOT"

is_listed() { "$ADB" devices | grep -q "^$SERIAL[[:space:]]"; }
booted() { [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; }
# qemu processes are found by process name (not by a command-line pattern, which would also
# match any shell whose command line mentions it), then told apart by their -port argument.
qemu_cmdline() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || true; }
our_qemu() {
  local p c
  for p in $(pgrep qemu-system || true); do
    c=$(qemu_cmdline "$p")
    if grep -qE -- "-port $EMU_PORT( |$)" <<< "$c"; then echo "$p"; fi
  done
}
other_qemu() {
  local p c
  for p in $(pgrep qemu-system || true); do
    c=$(qemu_cmdline "$p")
    if ! grep -qE -- "-port $EMU_PORT( |$)" <<< "$c"; then echo "$p ${c:0:160}"; fi
  done
}

describe() {
  say "-- $SERIAL: API $("$ADB" -s "$SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')," \
      "ABIs $("$ADB" -s "$SERIAL" shell getprop ro.product.cpu.abilist | tr -d '\r')," \
      "page size $("$ADB" -s "$SERIAL" shell getconf PAGE_SIZE | tr -d '\r')," \
      "SELinux $("$ADB" -s "$SERIAL" shell getenforce | tr -d '\r')"
}

case "$ACTION" in
  status)
    if is_listed; then
      say "-- $SERIAL listed by adb; boot_completed=$(booted && echo 1 || echo 0)"
      booted && describe
    else
      say "-- $SERIAL not running (qemu pids for port $EMU_PORT: $(our_qemu | tr '\n' ' '))"
    fi
    ;;

  start)
    if is_listed && booted; then
      say "-- $SERIAL already booted"
      describe
      say "emulator: OK ($SERIAL)"
      exit 0
    fi
    if [ -z "$(our_qemu)" ]; then
      others=$(other_qemu)
      [ -z "$others" ] || die "another emulator is running (only one may run on this host): $others"
      [ -x "$EMULATOR" ] || die "emulator not found at $EMULATOR"
      "$ANDROID_SDK_ROOT/emulator/emulator" -list-avds | grep -qx "$EMU_AVD" || die "AVD '$EMU_AVD' does not exist"
      args=(-avd "$EMU_AVD" -read-only -port "$EMU_PORT" -no-audio -no-boot-anim -no-snapshot-save -qt-hide-window)
      say "-- starting: $EMULATOR ${args[*]}  (console log: $CONSOLE_LOG)"
      echo "==== $(date -Is) ${args[*]}" >> "$CONSOLE_LOG"
      setsid nohup "$EMULATOR" "${args[@]}" >> "$CONSOLE_LOG" 2>&1 < /dev/null &
      disown || true
    else
      say "-- qemu for port $EMU_PORT already running; waiting for boot"
    fi
    t0=$(date +%s)
    timeout 180 "$ADB" -s "$SERIAL" wait-for-device || die "$SERIAL did not appear within 180 s (see $CONSOLE_LOG)"
    until booted; do
      [ $(( $(date +%s) - t0 )) -lt "$EMU_BOOT_TIMEOUT" ] || die "$SERIAL not booted after ${EMU_BOOT_TIMEOUT}s (see $CONSOLE_LOG)"
      [ -n "$(our_qemu)" ] || die "the emulator exited during boot (see $CONSOLE_LOG): $(tail -5 "$CONSOLE_LOG")"
      sleep 2
    done
    say "-- $SERIAL booted in $(( $(date +%s) - t0 )) s"
    # Keep the screen on and unlocked so activities resume and screenshots show the app.
    "$ADB" -s "$SERIAL" shell svc power stayon true || true
    "$ADB" -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP || true
    "$ADB" -s "$SERIAL" shell wm dismiss-keyguard || true
    describe
    say "emulator: OK ($SERIAL)"
    ;;

  stop)
    if is_listed; then
      say "-- adb -s $SERIAL emu kill"
      "$ADB" -s "$SERIAL" emu kill || true
    fi
    for _ in $(seq 1 30); do
      [ -z "$(our_qemu)" ] && break
      sleep 1
    done
    if [ -n "$(our_qemu)" ]; then
      say "-- qemu still running after 30 s; sending SIGTERM"
      our_qemu | xargs -r kill || true
      sleep 3
    fi
    [ -z "$(our_qemu)" ] || die "qemu for port $EMU_PORT is still running: $(our_qemu | tr '\n' ' ')"
    say "emulator: stopped ($SERIAL; no qemu process left for port $EMU_PORT)"
    ;;
esac
