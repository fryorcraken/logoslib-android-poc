#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# desktop-probe: the "app restart" path. Unload + reload lez_core, check whether its persistence
# dir survives, then open() the existing wallet with calibration_limit lowered (100 -> 5) so the
# open does not exceed the 20 s core_service call deadline.
set -u
P=${REPO_ROOT}/.work/probe
L="$P/logos/bin/logoscore"
CFG="$P/cfg"
LOG="$P/logs/run"
export QT_QPA_PLATFORM=offscreen
lc() { "$L" --config-dir "$CFG" "$@"; }
timed() {
  local t0 t1 out rc
  t0=$(date +%s%N)
  out=$(lc "$@" --json 2>&1); rc=$?
  t1=$(date +%s%N)
  echo "\$ logoscore $* -> rc=$rc ($(( (t1 - t0) / 1000000 )) ms)"
  echo "  $out" | head -c 1200; echo
}
OLD=$(lc call lez_core wallet_dir --json | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
echo "wallet_dir before reload: $OLD"
timed unload-module lez_core
timed load-module lez_core
NEW=$(lc call lez_core wallet_dir --json | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
echo "wallet_dir after reload:  $NEW"
ls -la "$NEW"
echo "== persist tree =="
find "$P/persist" -maxdepth 3 | sort
timed call lez_core list_accounts
# Lower calibration so open() fits inside the 20 s RPC deadline.
sed -i 's/"calibration_limit": 100/"calibration_limit": 5/' "$NEW/wallet_config.json"
grep -n calibration_limit "$NEW/wallet_config.json"
timed call lez_core open "$NEW/wallet_config.json" "$NEW/storage.json" "$NEW/statistics.json"
timed call lez_core list_accounts
timed call lez_core get_sequencer_addr
echo "== processes =="
ps -eo pid,ppid,rss,etime,args | grep -E 'logos_host|logoscore' | grep -v grep | cut -c1-200
echo "== daemon log tail =="
tail -n 15 "$LOG/daemon.log"
