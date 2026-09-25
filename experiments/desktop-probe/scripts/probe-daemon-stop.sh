#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# desktop-probe: stop the probe daemon cleanly and confirm hosts + sockets are gone.
set -u
P=${REPO_ROOT}/.work/probe
L="$P/logos/bin/logoscore"
CFG="$P/cfg"
LOG="$P/logs/run"
DPID=$(cat "$LOG/daemon.pid" 2>/dev/null)
"$L" --config-dir "$CFG" stop --json; echo " rc=$?"
for i in $(seq 1 50); do
  kill -0 "$DPID" 2>/dev/null || break
  sleep 0.2
done
kill -0 "$DPID" 2>/dev/null && echo "daemon $DPID STILL RUNNING" || echo "daemon $DPID exited"
echo "== leftover logos processes =="
ps -eo pid,ppid,args | grep -E 'logos_host|logoscore' | grep -v grep | cut -c1-160
echo "== leftover logos unix sockets (listening) =="
ss -xlpn 2>/dev/null | grep -c -E 'logos_'
"$L" --config-dir "$CFG" status --json; echo " rc=$?"
echo "== files under cfg =="
find "$CFG" -type f | sort
