#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# desktop-probe: call lez_core's offline methods through the running logoscore daemon, with timings.
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
  echo "  $out" | head -c 1500; echo
}
echo "== module-info tail (methods list continues) =="
python3 - "$LOG/module-info.json" <<'EOF' 2>/dev/null || tail -c 3000 "$LOG/module-info.json"
import json,sys
d=json.load(open(sys.argv[1]))
print("method count:", len(d.get("methods",[])))
for m in d["methods"]:
    print("  ", m["signature"], "->", m.get("returnType"))
print("events:", d.get("events"))
EOF
echo
timed call lez_core name
timed call lez_core version
timed call lez_core wallet_dir
HEX=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
timed call lez_core account_id_to_base58 "$HEX"
B58=$(lc call lez_core account_id_to_base58 "$HEX" --json | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
echo "base58=$B58"
timed call lez_core account_id_from_base58 "$B58"
timed call lez_core account_id_from_base58 '!!!not-base58!!!'
timed call lez_core get_sequencer_addr
timed call lez_core list_accounts
echo "== plain (non-json) output of one call =="
lc call lez_core version
echo "== logoscore stats =="
lc stats --json; echo
echo "== daemon log tail =="
tail -n 30 "$LOG/daemon.log"
