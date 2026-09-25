#!/usr/bin/env bash
# bc-desktop: block until a marker line appears in a log (default: the lgx build summary end), max ~28 min.
set -u
F=${REPO_ROOT}/.work/experiments/bc-desktop/logs/build-summary.txt
for i in $(seq 1 1680); do
  if grep -q '== end ' "$F" 2>/dev/null; then echo "marker found"; tail -n 40 "$F"; exit 0; fi
  sleep 1
done
echo "timeout waiting; last build lines:"
tail -n 5 ${REPO_ROOT}/.work/experiments/bc-desktop/logs/lgx-build.txt
