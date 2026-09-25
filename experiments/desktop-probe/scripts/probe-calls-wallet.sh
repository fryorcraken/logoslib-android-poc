#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# desktop-probe: "real work" through lez_core: create a throwaway wallet (files under the module's
# persistence dir), derive a public account locally, then ONE read-only network call.
# No transaction is submitted. The mnemonic is not printed (only its word count).
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
WDIR=$(lc call lez_core wallet_dir --json | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
echo "wallet_dir (module persistence path) = $WDIR"
ls -la "$WDIR"

T0=$(date +%s%N)
OUT=$(lc call lez_core create_new "$WDIR/wallet_config.json" "$WDIR/storage.json" "$WDIR/statistics.json" 'str:probe-password' --json 2>&1); RC=$?
T1=$(date +%s%N)
MN=$(printf '%s' "$OUT" | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
echo "\$ logoscore call lez_core create_new <wdir>/wallet_config.json <wdir>/storage.json <wdir>/statistics.json str:*** -> rc=$RC ($(( (T1 - T0) / 1000000 )) ms)"
echo "  status: $(printf '%s' "$OUT" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')  mnemonic words: $(printf '%s' "$MN" | wc -w)"
echo "  (raw output with mnemonic redacted): $(printf '%s' "$OUT" | sed 's/"result":"[^"]*"/"result":"<redacted>"/')"

echo "== files written by create_new =="
ls -la "$WDIR"
echo "== wallet_config.json as written =="
cat "$WDIR/wallet_config.json" 2>/dev/null; echo

timed call lez_core get_sequencer_addr
timed call lez_core create_account_public
timed call lez_core create_account_public
timed call lez_core list_accounts
ACC=$(lc call lez_core list_accounts --json | grep -o '[0-9a-f]\{64\}' | head -1)
echo "first account id hex: $ACC"
if [ -n "$ACC" ]; then
  timed call lez_core account_id_to_base58 "$ACC"
  timed call lez_core get_public_account_key "$ACC"
fi
timed call lez_core save
echo "== files after save =="
ls -la "$WDIR"
echo "== ONE read-only network call: get_current_block_height (sequencer from config) =="
timed call lez_core get_current_block_height
timed call lez_core get_last_synced_block
echo "== daemon log tail =="
tail -n 40 "$LOG/daemon.log" | sed 's/[a-z]\+\( [a-z]\+\)\{11,23\}/<redacted-words>/g'
