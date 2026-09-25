#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# desktop-probe: dry-run then build the tiny lez_probe module (.lgx) that calls lez_core via modules().
set -u
P=${REPO_ROOT}/.work/probe
F="path:$P/src/lez_probe"
LOG="$P/logs"
nix build --dry-run "$F#lgx" > "$LOG/lezprobe-dryrun.txt" 2>&1
echo "dry-run exit=$?"
grep -n 'will be built\|will be fetched\|error' "$LOG/lezprobe-dryrun.txt" | head
awk '/will be built/{f=1;next} /will be fetched/{f=0} f' "$LOG/lezprobe-dryrun.txt" | sed 's#.*/[a-z0-9]\{32\}-##'
echo "== build =="
T0=$(date +%s)
nix build -L "$F#lgx" -o "$P/lezprobe-lgx" > "$LOG/lezprobe-build.txt" 2>&1
RC=$?
echo "build exit=$RC in $(( $(date +%s) - T0 )) s"
grep -n -i 'error\|warning: unused\|lez_core\|modules()' "$LOG/lezprobe-build.txt" | head -60
tail -n 25 "$LOG/lezprobe-build.txt"
ls -laL "$P/lezprobe-lgx" 2>&1
