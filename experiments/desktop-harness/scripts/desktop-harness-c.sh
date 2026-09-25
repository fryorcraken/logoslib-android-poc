#!/usr/bin/env bash
# desktop-harness (c): single-threaded blocking.
#  block create: L = lez_core.create_new (testnet, pre-written config with a small calibration_limit),
#                B = lez_core.version (same module), D = lez_probe.lez_version (-> busy lez_core),
#                C = ev_probe.ping (other module), E = tight-loop sync pinger on ev_probe.ping
#  block sleep : L = ev_probe.sleep_ms(6000) (deterministic, no network), B = ev_probe.ping,
#                C = lez_core.version, D = lez_probe.lez_version (-> idle lez_core), E = pinger on lez_core.version
#  each in "sync" (every call a blocking lp_invoke on its own thread) and "async" (lp_invoke_async) style.
#  qtbusy: the Qt thread blocked / running logos_core_load_module (host start delayed 3 s by a wrapper).
set -u
W=${REPO_ROOT}/.work
E=$W/experiments/desktop-harness
LIBLOGOS=/nix/store/7jcna50jgjmzx28nk6a14x5y6f5dwlrb-logos-liblogos
RAW=$E/logs/c-raw
mkdir -p "$E/logs" "$RAW" "$E/persist/c" "$E/wallets"
exec > >(tee "$E/logs/c-block.log") 2>&1
unset LD_LIBRARY_PATH
export LOGOS_HOST_PATH=$LIBLOGOS/bin/logos_host

mkwallet() {  # dir calibration_limit
  rm -rf "$1"; mkdir -p "$1"
  cat > "$1/wallet_config.json" <<EOF
{
  "sequencers": [ { "sequencer_addr": "https://testnet.lez.logos.co/" } ],
  "seq_poll_timeout": "12s",
  "seq_tx_poll_max_blocks": 5,
  "seq_poll_max_retries": 5,
  "seq_block_poll_max_amount": 100,
  "multi_sequencer_client_config": { "distribution_limit": 1, "calibration_limit": $2 }
}
EOF
}

run() {  # name args...
  local name=$1; shift
  export TMPDIR=$W/dh/c${name:0:2}
  rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
  echo "================ $name ($*) TMPDIR=$TMPDIR"
  local t0=$(date +%s%N)
  timeout 200 "$E/build/dh" "$E/modules" "$E/persist/c" "$@" > "$RAW/$name.log" 2>&1
  echo "exit=$? wall=$(( ($(date +%s%N) - t0) / 1000000 )) ms"
  grep -E '^\[ *[0-9]+ ms\]\[(main|qt|L|B|C|D|pinger|other)\]' "$RAW/$name.log" \
    | grep -v -E 'warmup: ' | cut -c1-330 | head -80
  grep -E 'wallet|FFI|error' "$RAW/$name.log" | grep -v '^\[ *[0-9]* ms\]' | head -8
  local left; left=$(pgrep -f "$E/modules" | wc -l)
  [ "$left" = "0" ] || echo "   WARNING: $left leftover logos_host processes"
}

mkwallet "$E/wallets/c1" 3
run 01-create-cal3-sync block create sync pinger "$E/wallets/c1"
mkwallet "$E/wallets/c2" 3
run 02-create-cal3-async block create async pinger "$E/wallets/c2"
mkwallet "$E/wallets/c3" 20
run 03-create-cal20-sync block create sync pinger "$E/wallets/c3"
mkwallet "$E/wallets/c4" 20
run 04-create-cal20-async block create async pinger "$E/wallets/c4"
run 05-sleep-sync block sleep sync pinger
run 06-sleep-async block sleep async pinger
run 07-sleep-sync-nopinger block sleep sync nopinger

export DH_SLOW_HOST_S=3
export LOGOS_HOST_PATH=$E/bin/slow_host.sh
run 08-qtbusy qtbusy
