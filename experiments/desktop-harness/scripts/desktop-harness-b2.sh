#!/usr/bin/env bash
# desktop-harness (b, part 2): does a blocking no-op round trip through the Qt thread ("barrier") after a
# worker-thread load close the first-call race? 20 fresh processes, lez_probe.lez_version, no retry warm-up.
set -u
W=${REPO_ROOT}/.work
E=$W/experiments/desktop-harness
LIBLOGOS=/nix/store/7jcna50jgjmzx28nk6a14x5y6f5dwlrb-logos-liblogos
RAW=$E/logs/b-raw
mkdir -p "$E/logs" "$RAW" "$E/persist/b"
exec > >(tee "$E/logs/b2-race-barrier.log") 2>&1
nix develop --no-write-lock-file "path:${HOME}/src/logos-co/logos-liblogos" -c bash "$E/build/build.sh" 2>&1 | tail -2
unset LD_LIBRARY_PATH
export LOGOS_HOST_PATH=$LIBLOGOS/bin/logos_host
: > "$E/logs/b-probe-barrier.results"
for i in $(seq -w 1 20); do
  export TMPDIR=$W/dh/b$i
  rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
  timeout 90 "$E/build/dh" "$E/modules" "$E/persist/b" race lez_probe lez_version '"0.3.0"' barrier \
    > "$RAW/probe-barrier-$i.log" 2>&1
  rc=$?
  b=$(grep -o 'barrier took [0-9]* ms' "$RAW/probe-barrier-$i.log")
  line=$(grep '^RESULT' "$RAW/probe-barrier-$i.log")
  echo "run $i exit=$rc [$b] $line" | tee -a "$E/logs/b-probe-barrier.results" | cut -c1-300
done
echo "== aggregate =="
echo "first-call bad (empty string): $(grep -c 'first_result=""' "$E/logs/b-probe-barrier.results") / 20"
echo "first-call good: $(grep -c 'first_result="0.3.0"' "$E/logs/b-probe-barrier.results") / 20"
