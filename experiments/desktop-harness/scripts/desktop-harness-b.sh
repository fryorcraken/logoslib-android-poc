#!/usr/bin/env bash
# desktop-harness (b): first-call race. 20 fresh processes per variant:
#   probe-worker : load lez_probe (pulls lez_core) from a non-Qt thread, then IMMEDIATELY
#                  lp_invoke(lez_probe, lez_version) -- lez_probe -> lez_core needs capability_module
#   core-worker  : load lez_core from a non-Qt thread, then immediately lp_invoke(lez_core, version)
#   probe-qt     : as probe-worker but the load runs ON the Qt thread (registration inline)
# No warm-up; on a bad answer the harness retries every 20 ms and records time-to-first-good.
set -u
W=${REPO_ROOT}/.work
E=$W/experiments/desktop-harness
LIBLOGOS=/nix/store/7jcna50jgjmzx28nk6a14x5y6f5dwlrb-logos-liblogos
RAW=$E/logs/b-raw
mkdir -p "$E/logs" "$RAW" "$E/persist/b"
exec > >(tee "$E/logs/b-race.log") 2>&1
unset LD_LIBRARY_PATH
export LOGOS_HOST_PATH=$LIBLOGOS/bin/logos_host
N=20
run_variant() {
  local name=$1 target=$2 method=$3 expected=$4 loader=$5
  : > "$E/logs/b-$name.results"
  for i in $(seq -w 1 $N); do
    export TMPDIR=$W/dh/b$i
    rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
    timeout 90 "$E/build/dh" "$E/modules" "$E/persist/b" race "$target" "$method" "$expected" "$loader" \
      > "$RAW/$name-$i.log" 2>&1
    local rc=$?
    local line
    line=$(grep '^RESULT' "$RAW/$name-$i.log")
    echo "run $i exit=$rc $line" | tee -a "$E/logs/b-$name.results" | cut -c1-330
    local left
    left=$(pgrep -f "$E/modules" | wc -l)
    [ "$left" = "0" ] || echo "   WARNING: $left leftover logos_host processes"
  done
}
echo "== variant probe-worker =="
run_variant probe-worker lez_probe lez_version '"0.3.0"' worker
echo "== variant core-worker =="
run_variant core-worker lez_core version '"0.3.0"' worker
echo "== variant probe-qt =="
run_variant probe-qt lez_probe lez_version '"0.3.0"' qt

echo "== aggregate =="
python3 - "$E/logs" <<'PY'
import re, sys, statistics
d = sys.argv[1]
for name in ["probe-worker", "core-worker", "probe-qt"]:
    rows = []
    for line in open(f"{d}/b-{name}.results"):
        kv = dict(re.findall(r'(\w+)=(\S+)', line))
        rows.append(kv)
    n = len(rows)
    bad_first = [r for r in rows if r.get("first_result") != '"0.3.0"']
    good = [r for r in rows if r.get("good") == "1"]
    ttg = [int(r["good_after_load_ms"]) for r in good]
    loads = [int(r["load_ms"]) for r in rows if "load_ms" in r]
    firsts = [int(r["first_ms"]) for r in rows if "first_ms" in r]
    kinds = {}
    for r in bad_first:
        kinds[r.get("first_result")] = kinds.get(r.get("first_result"), 0) + 1
    print(f"{name}: runs={n} first-call-bad={len(bad_first)} {kinds} eventually-good={len(good)}")
    if loads: print(f"   load_ms min/med/max = {min(loads)}/{statistics.median(loads)}/{max(loads)}")
    if firsts: print(f"   first-call latency ms min/med/max = {min(firsts)}/{statistics.median(firsts)}/{max(firsts)}")
    if ttg: print(f"   time from load-return to first good answer ms min/med/max = {min(ttg)}/{statistics.median(ttg)}/{max(ttg)}")
    att = [int(r["attempts"]) for r in rows if "attempts" in r]
    if att: print(f"   attempts min/med/max = {min(att)}/{statistics.median(att)}/{max(att)}")
PY
