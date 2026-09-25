#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# desktop-probe run3: (a) relocate the per-module unix sockets by pointing TMPDIR (what
# QDir::tempPath() honours on Unix) at a dir under .work, (b) NO QT_QPA_PLATFORM set, to see whether
# a headless platform plugin is needed at all, (c) --access-policy enforce, to show the declared
# lez_probe -> lez_core edge is still allowed under deny-by-default.
set -u
P=${REPO_ROOT}/.work/probe
L="$P/logos/bin/logoscore"
CFG="$P/cfg3"
PERSIST="$P/persist"
LOG="$P/logs/run3b"
# run3 used $P/sock: capability_module's path hit 108 bytes > sun_path and it crashed. Shorter dir:
SOCK="$P/s"
mkdir -p "$LOG" "$CFG" "$SOCK"
unset QT_QPA_PLATFORM
unset DISPLAY WAYLAND_DISPLAY
export TMPDIR="$SOCK"
lc() { "$L" --config-dir "$CFG" "$@"; }
timed() {
  local t0 t1 out rc
  t0=$(date +%s%N)
  out=$(lc "$@" --json 2>&1); rc=$?
  t1=$(date +%s%N)
  echo "\$ logoscore $* -> rc=$rc ($(( (t1 - t0) / 1000000 )) ms)"
  echo "  $out" | head -c 800; echo
}
setsid nohup "$L" --config-dir "$CFG" -D -m "$P/modules" --persistence-path "$PERSIST" --access-policy enforce > "$LOG/daemon.log" 2>&1 < /dev/null &
DPID=$!
echo "$DPID" > "$LOG/daemon.pid"
for i in $(seq 1 150); do lc status --json > /dev/null 2>&1 && break; sleep 0.2; done
timed load-module lez_probe
timed call lez_probe roundtrip_via_lez afd35f1465ac42d705d8a80b0be9c8f285f3bc72c1a47d528c0ba3b1c205b98b
timed call lez_core account_id_to_base58 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
echo "== listening sockets (should be under $SOCK) =="
ss -xlpn 2>/dev/null | grep -E 'logos' | awk '{print $5, $NF}'
ls -la "$SOCK"
echo "== env of lez_core host (selected vars) =="
HP=$(pgrep -f -- '--name lez_core' | head -1)
tr '\0' '\n' < /proc/$HP/environ | grep -E '^(TMPDIR|LOGOS_|QT_|LD_LIBRARY_PATH|NIXPKGS_QT6)' | sed 's/=\(.\{120\}\).*/=\1.../'
echo "== fds of lez_core host that are files (what it has open) =="
ls -l /proc/$HP/fd 2>/dev/null | awk '{print $NF}' | grep -v -E '^(socket|pipe|anon_inode)' | sort -u
lc stop --json; echo
for i in $(seq 1 50); do kill -0 "$DPID" 2>/dev/null || break; sleep 0.2; done
echo "after stop, sock dir:"; ls -la "$SOCK"
echo "== daemon log =="
cat "$LOG/daemon.log"
