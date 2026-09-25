#!/usr/bin/env bash
# desktop-harness (d): lp_subscribe from the in-process host to ev_probe's typed event "pinged":
# subscribe-before-load, arm latency, delivery latency + callback thread, a 200-event burst, a second
# subscription from a worker thread, an unknown event name, provider unload/reload, unsubscribe.
set -u
W=${REPO_ROOT}/.work
E=$W/experiments/desktop-harness
LIBLOGOS=/nix/store/7jcna50jgjmzx28nk6a14x5y6f5dwlrb-logos-liblogos
mkdir -p "$E/logs" "$E/persist/d"
exec > >(tee "$E/logs/d-events.log") 2>&1
unset LD_LIBRARY_PATH
export LOGOS_HOST_PATH=$LIBLOGOS/bin/logos_host
export TMPDIR=$W/dh/d1
rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
timeout 120 "$E/build/dh" "$E/modules" "$E/persist/d" events > "$E/logs/d-events-raw.log" 2>&1
echo "exit=$?"
grep -E '^\[ *[0-9]+ ms\]' "$E/logs/d-events-raw.log" | cut -c1-300
echo "== liblogos/protocol warnings mentioning subscriptions/events =="
grep -i -E 'subscri|event|arm|pending' "$E/logs/d-events-raw.log" | grep -v '^\[ *[0-9]* ms\]' | head -30
left=$(pgrep -f "$E/modules" | wc -l)
echo "leftover logos_host processes: $left"
