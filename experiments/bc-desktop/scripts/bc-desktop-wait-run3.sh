#!/usr/bin/env bash
# bc-desktop: block until run3 logs its end marker (max ~25 min).
set -u
F=${REPO_ROOT}/.work/experiments/bc-desktop/logs/run3/run.log
for i in $(seq 1 1500); do
  if grep -q '== run3 end ' "$F" 2>/dev/null; then echo "run3 finished"; exit 0; fi
  sleep 1
done
echo "timeout; tail:"; tail -n 5 "$F"
