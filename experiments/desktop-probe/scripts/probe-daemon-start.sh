#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# desktop-probe: start a logoscore daemon (headless) against .work/probe/modules with ALL state
# kept under .work/probe (config dir + persistence path), then load lez_core and introspect it.
# The daemon is left running (detached) for the follow-up call scripts; stop it with probe-daemon-stop.sh.
set -u
P=${REPO_ROOT}/.work/probe
L="$P/logos/bin/logoscore"
CFG="$P/cfg"
PERSIST="$P/persist"
LOG="$P/logs/run"
mkdir -p "$CFG" "$PERSIST" "$LOG"

echo "== df / before =="; df -h / | tail -1

# Seed the built-in modules exactly as the LEZ doctest does (cp -RL ./logos/modules/. ./modules/).
cp -RL "$P/logos/modules/." "$P/modules/"
chmod -R u+w "$P/modules"
echo "== modules dir =="; ls -1 "$P/modules"

export QT_QPA_PLATFORM=offscreen
lc() { "$L" --config-dir "$CFG" "$@"; }

T0=$(date +%s%N)
setsid nohup "$L" --config-dir "$CFG" -D -m "$P/modules" --persistence-path "$PERSIST" > "$LOG/daemon.log" 2>&1 < /dev/null &
DPID=$!
echo "$DPID" > "$LOG/daemon.pid"
echo "daemon pid $DPID"
for i in $(seq 1 150); do
  if lc status --json > "$LOG/status0.json" 2>&1; then break; fi
  sleep 0.2
done
T1=$(date +%s%N)
echo "daemon status OK after $(( (T1 - T0) / 1000000 )) ms"
echo "== status (before load) =="; cat "$LOG/status0.json"; echo
echo "== list-modules =="; lc list-modules --json; echo
echo "== processes before load =="
ps -eo pid,ppid,rss,args | grep -E 'logos_host|logoscore' | grep -v grep

T2=$(date +%s%N)
lc load-module lez_core --json > "$LOG/load.json" 2>&1
RC=$?
T3=$(date +%s%N)
echo "== load-module lez_core rc=$RC took $(( (T3 - T2) / 1000000 )) ms =="
cat "$LOG/load.json"; echo
echo "== status (after load) =="; lc status --json; echo
echo "== processes after load =="
ps -eo pid,ppid,rss,args | grep -E 'logos_host|logoscore' | grep -v grep
echo "== unix sockets owned by logos processes =="
ss -xlpn 2>/dev/null | grep -E 'logos' | awk '{print $5, $NF}'
echo "== module-info lez_core =="
lc module-info lez_core --json > "$LOG/module-info.json" 2>&1
echo "rc=$?"; head -c 6000 "$LOG/module-info.json"; echo
echo "== daemon log so far =="
cat "$LOG/daemon.log"
