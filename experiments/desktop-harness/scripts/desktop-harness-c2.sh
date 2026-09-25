#!/usr/bin/env bash
# desktop-harness (c, part 2): rebuild the harness, then measure lp_invoke / lp_invoke_async timeouts
# against a busy MODULE (ev_probe.sleep_ms), short timeouts under nested-loop inversion, and the
# default (timeout_ms <= 0) deadline.
set -u
W=${REPO_ROOT}/.work
E=$W/experiments/desktop-harness
LIBLOGOS=/nix/store/7jcna50jgjmzx28nk6a14x5y6f5dwlrb-logos-liblogos
mkdir -p "$E/logs" "$E/logs/c-raw" "$E/persist/c"
exec > >(tee "$E/logs/c2-timeouts.log") 2>&1
nix develop --no-write-lock-file "path:${HOME}/src/logos-co/logos-liblogos" -c bash "$E/build/build.sh" 2>&1 | tail -3
unset LD_LIBRARY_PATH
export LOGOS_HOST_PATH=$LIBLOGOS/bin/logos_host
export TMPDIR=$W/dh/c09
rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
timeout 150 "$E/build/dh" "$E/modules" "$E/persist/c" timeouts > "$E/logs/c-raw/09-timeouts.log" 2>&1
echo "exit=$?"
grep -E '^\[ *[0-9]+ ms\]' "$E/logs/c-raw/09-timeouts.log" | cut -c1-330
echo "== protocol warnings =="
grep -i -E 'timed out|timeout|Warning' "$E/logs/c-raw/09-timeouts.log" | grep -v '^\[ *[0-9]* ms\]' | cut -c1-250 | head -20
left=$(pgrep -f "$E/modules" | wc -l)
echo "leftover logos_host processes: $left"
