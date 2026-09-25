#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# desktop-probe: fresh daemon; load ONLY lez_probe (lez_core must come up first as its declared
# dependency), then trigger lez_probe -> lez_core calls over the liblogos transport.
set -u
P=${REPO_ROOT}/.work/probe
L="$P/logos/bin/logoscore"
CFG="$P/cfg"
PERSIST="$P/persist"
LOG="$P/logs/run2"
mkdir -p "$LOG"
export QT_QPA_PLATFORM=offscreen
lc() { "$L" --config-dir "$CFG" "$@"; }
timed() {
  local t0 t1 out rc
  t0=$(date +%s%N)
  out=$(lc "$@" --json 2>&1); rc=$?
  t1=$(date +%s%N)
  echo "\$ logoscore $* -> rc=$rc ($(( (t1 - t0) / 1000000 )) ms)"
  echo "  $out" | head -c 1500; echo
}
T0=$(date +%s%N)
setsid nohup "$L" --config-dir "$CFG" -D -m "$P/modules" --persistence-path "$PERSIST" > "$LOG/daemon.log" 2>&1 < /dev/null &
DPID=$!
echo "$DPID" > "$LOG/daemon.pid"
echo "$DPID" > "$P/logs/run/daemon.pid"
for i in $(seq 1 150); do lc status --json > /dev/null 2>&1 && break; sleep 0.2; done
echo "daemon up after $(( ($(date +%s%N) - T0) / 1000000 )) ms"
timed list-modules
timed load-module lez_probe
echo "cold start -> lez_probe (+lez_core) loaded: $(( ($(date +%s%N) - T0) / 1000000 )) ms"
timed status
timed module-info lez_probe
timed call lez_probe ping
timed call lez_probe lez_version
timed call lez_probe to_base58_via_lez aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
timed call lez_probe roundtrip_via_lez afd35f1465ac42d705d8a80b0be9c8f285f3bc72c1a47d528c0ba3b1c205b98b
echo "== 20 sequential cross-module round trips (40 lez_core calls) timing =="
t0=$(date +%s%N)
for i in $(seq 1 20); do lc call lez_probe roundtrip_via_lez afd35f1465ac42d705d8a80b0be9c8f285f3bc72c1a47d528c0ba3b1c205b98b > /dev/null 2>&1; done
echo "20 CLI calls took $(( ($(date +%s%N) - t0) / 1000000 )) ms total (includes CLI process spawn each time)"
echo "== processes =="
ps -eo pid,ppid,rss,args | grep -E 'logos_host|logoscore' | grep -v grep | cut -c1-170
echo "== listening sockets =="
ss -xlpn 2>/dev/null | grep -E 'logos' | awk '{print $5, $NF}'
echo "== unix stream connections held by the lez_probe host =="
PPID_PROBE=$(pgrep -f -- '--name lez_probe' | head -1)
echo "lez_probe host pid: $PPID_PROBE"
ss -xpn 2>/dev/null | grep "pid=$PPID_PROBE," | awk '{print $5, $6, $7, $8, $NF}'
sleep 1
echo "== daemon log =="
cat "$LOG/daemon.log"
